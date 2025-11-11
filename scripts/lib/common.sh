#!/bin/bash
#
# Common functions for deployment scripts and e2e tests
# This library provides reusable wait, verification, and logging functions
#

# Set PROJECT_ROOT if not already set
# This allows the library to be sourced from different locations
if [[ -z "${PROJECT_ROOT:-}" ]]; then
    # Try to detect project root from common.sh location
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
    else
        # Fallback: assume we're in scripts/lib/ and go up two levels
        PROJECT_ROOT="$(cd "$(dirname "${0}")/../.." && pwd)"
    fi
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'  # Light blue (cyan)
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

# Wait for resource to be ready
# Usage: wait_for_resource <resource_type> <resource_name> <namespace> [timeout]
wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local timeout=${4:-300}
    local elapsed=0
    
    log_info "Waiting for $resource_type/$resource_name to be ready (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        if oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
            # Check if resource is ready (if it has a status field)
            local status=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [[ -z "$status" ]] || [[ "$status" == "True" ]]; then
                log_success "$resource_type/$resource_name is ready"
                return 0
            fi
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -lt $timeout ]]; then
            log_info "Still waiting for $resource_type/$resource_name... (${elapsed}s)"
        fi
    done
    
    log_error "$resource_type/$resource_name failed to become ready within ${timeout}s"
    return 1
}

# Wait for pods to be running
# Usage: wait_for_pods <namespace> <selector> [expected_count] [timeout]
wait_for_pods() {
    local namespace=$1
    local selector=$2
    local expected_count=${3:-1}
    local timeout=${4:-300}
    local elapsed=0
    
    log_info "Waiting for pods with selector '$selector' to be running (expected: $expected_count, timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local running_count=$(oc get pods -n "$namespace" -l "$selector" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
        # Ensure running_count is a number
        running_count=${running_count:-0}
        if [[ "$running_count" =~ ^[0-9]+$ ]] && [[ "$running_count" -ge "$expected_count" ]]; then
            log_success "Found $running_count running pod(s) with selector '$selector'"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -lt $timeout ]]; then
            log_info "Still waiting for pods... (${elapsed}s, found: ${running_count}/${expected_count})"
        fi
    done
    
    log_error "Pods with selector '$selector' failed to become running within ${timeout}s"
    return 1
}

# Check prerequisites
# Usage: check_prerequisites
check_prerequisites() {
    local missing_tools=()
    
    if ! command -v oc &>/dev/null; then
        missing_tools+=("oc")
    fi
    
    if ! command -v jq &>/dev/null; then
        missing_tools+=("jq")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install the missing tools and try again"
        return 1
    fi
    
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        return 1
    fi
    
    return 0
}

# Find ThanosQuerier pod in a namespace
# Tries multiple selectors in order: COO-specific labels, standard Thanos labels, name pattern
# Usage: find_thanosquerier_pod <namespace>
# Returns: pod name or empty string if not found
find_thanosquerier_pod() {
    local namespace=$1
    local thanos_pod=""
    
    if [[ -z "$namespace" ]]; then
        log_error "find_thanosquerier_pod: namespace argument required"
        return 1
    fi
    
    # First try: COO-specific labels (most reliable for COO ThanosQuerier)
    # COO uses: app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier
    thanos_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    
    # Fallback: standard Thanos label
    if [[ -z "$thanos_pod" ]]; then
        thanos_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/name=thanos-query --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    fi
    
    # Fallback: try by name pattern (for cases where labels aren't set correctly)
    if [[ -z "$thanos_pod" ]]; then
        thanos_pod=$(oc get pods -n "$namespace" --no-headers 2>/dev/null | grep -E "thanos.*querier|querier.*thanos" | awk '{print $1}' | head -1)
    fi
    
    # Return pod name (empty string if not found)
    echo "$thanos_pod"
}

# Find Prometheus pod in a namespace
# Tries standard labels first, with optional COO-specific fallback
# Usage: find_prometheus_pod <namespace> [prefer_coo]
#   prefer_coo: if "true", tries COO-specific labels first (default: false)
# Returns: pod name or empty string if not found
find_prometheus_pod() {
    local namespace=$1
    local prefer_coo=${2:-false}
    local prom_pod=""
    
    if [[ -z "$namespace" ]]; then
        log_error "find_prometheus_pod: namespace argument required"
        return 1
    fi
    
    if [[ "$prefer_coo" == "true" ]]; then
        # Try COO-specific labels first
        # COO uses: app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/name=prometheus
        prom_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        
        # Fallback: standard Prometheus label
        if [[ -z "$prom_pod" ]]; then
            prom_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        fi
    else
        # Try standard Prometheus label first (works for both COO and UWM)
        prom_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        
        # Fallback: COO-specific labels (if standard didn't work)
        if [[ -z "$prom_pod" ]]; then
            prom_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | awk '{print $1}' | head -1)
        fi
    fi
    
    # Return pod name (empty string if not found)
    echo "$prom_pod"
}

# Find query pod (ThanosQuerier or Prometheus) for metrics queries
# Prefers ThanosQuerier for COO (better for HA setups), falls back to Prometheus
# Usage: find_query_pod <namespace> [prefer_thanos]
#   prefer_thanos: if "true", prefers ThanosQuerier (default: true)
# Returns: "pod_name|port" or empty string if not found
#   Port: 10902 for ThanosQuerier, 9090 for Prometheus
find_query_pod() {
    local namespace=$1
    local prefer_thanos=${2:-true}
    local query_pod=""
    local query_port=""
    
    if [[ -z "$namespace" ]]; then
        log_error "find_query_pod: namespace argument required"
        return 1
    fi
    
    if [[ "$prefer_thanos" == "true" ]]; then
        # Try ThanosQuerier first (preferred for COO - aggregates multiple Prometheus instances)
        local thanos_pod=$(find_thanosquerier_pod "$namespace")
        if [[ -n "$thanos_pod" ]]; then
            # Check if pod is running
            local thanos_phase=$(oc get pod "$thanos_pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$thanos_phase" == "Running" ]]; then
                query_pod="$thanos_pod"
                query_port="10902"  # ThanosQuerier uses port 10902
            fi
        fi
        
        # Fallback to Prometheus if ThanosQuerier not available or not running
        if [[ -z "$query_pod" ]]; then
            local prom_pod=$(find_prometheus_pod "$namespace" "true")
            if [[ -n "$prom_pod" ]]; then
                local prom_phase=$(oc get pod "$prom_pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [[ "$prom_phase" == "Running" ]]; then
                    query_pod="$prom_pod"
                    query_port="9090"  # Prometheus uses port 9090
                fi
            fi
        fi
    else
        # Try Prometheus first
        local prom_pod=$(find_prometheus_pod "$namespace" "false")
        if [[ -n "$prom_pod" ]]; then
            local prom_phase=$(oc get pod "$prom_pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$prom_phase" == "Running" ]]; then
                query_pod="$prom_pod"
                query_port="9090"
            fi
        fi
        
        # Fallback to ThanosQuerier if Prometheus not available
        if [[ -z "$query_pod" ]]; then
            local thanos_pod=$(find_thanosquerier_pod "$namespace")
            if [[ -n "$thanos_pod" ]]; then
                local thanos_phase=$(oc get pod "$thanos_pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [[ "$thanos_phase" == "Running" ]]; then
                    query_pod="$thanos_pod"
                    query_port="10902"
                fi
            fi
        fi
    fi
    
    # Return "pod_name|port" or empty string
    if [[ -n "$query_pod" ]] && [[ -n "$query_port" ]]; then
        echo "${query_pod}|${query_port}"
    else
        echo ""
    fi
}

# Helper function to run oc commands with optional verbose output
# Usage: oc_cmd <oc-args...>
#   If VERBOSE environment variable is "true", shows full output
#   Otherwise, suppresses stderr
oc_cmd() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        oc "$@"
    else
        oc "$@" 2>/dev/null
    fi
}

# Helper function for oc commands that need to suppress all output in non-verbose mode
# Usage: oc_cmd_silent <oc-args...>
#   If VERBOSE environment variable is "true", shows full output
#   Otherwise, suppresses both stdout and stderr
oc_cmd_silent() {
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        oc "$@"
    else
        oc "$@" &>/dev/null
    fi
}

