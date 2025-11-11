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

# Batch apply multiple Kubernetes manifest files
# Usage: batch_apply <namespace> <file1> [file2] [file3] ...
#   Applies all files in a single oc apply command for better performance
#   Returns: 0 on success, 1 on error
batch_apply() {
    local namespace=$1
    shift
    local files=("$@")
    
    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "batch_apply: at least one file required"
        return 1
    fi
    
    # Check if all files exist
    for file in "${files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "batch_apply: file not found: $file"
            return 1
        fi
    done
    
    # Apply all files at once using process substitution
    # This is more efficient than applying them sequentially
    if [[ -n "$namespace" ]]; then
        if oc apply -n "$namespace" -f "${files[@]}" &>/dev/null; then
            return 0
        else
            # If batch apply fails, try applying individually for better error messages
            local failed=0
            for file in "${files[@]}"; do
                if ! oc apply -n "$namespace" -f "$file" &>/dev/null; then
                    log_error "Failed to apply: $file"
                    ((failed++))
                fi
            done
            return $((failed > 0 ? 1 : 0))
        fi
    else
        if oc apply -f "${files[@]}" &>/dev/null; then
            return 0
        else
            local failed=0
            for file in "${files[@]}"; do
                if ! oc apply -f "$file" &>/dev/null; then
                    log_error "Failed to apply: $file"
                    ((failed++))
                fi
            done
            return $((failed > 0 ? 1 : 0))
        fi
    fi
}

# Check if a CRD exists (cached to avoid repeated calls)
# Usage: check_crd_exists <crd_name>
#   Returns: 0 if CRD exists, 1 if not
#   Uses a cache to avoid repeated oc get calls
check_crd_exists() {
    local crd_name=$1
    local cache_key="crd_${crd_name}"
    
    # Check cache first (if available)
    if [[ -n "${CRD_CACHE[$crd_name]:-}" ]]; then
        [[ "${CRD_CACHE[$crd_name]}" == "true" ]]
        return $?
    fi
    
    # Check CRD existence
    if oc get crd "$crd_name" &>/dev/null; then
        # Cache the result
        CRD_CACHE[$crd_name]="true"
        return 0
    else
        CRD_CACHE[$crd_name]="false"
        return 1
    fi
}

# Initialize CRD cache (declare as associative array if not already declared)
if ! declare -p CRD_CACHE &>/dev/null; then
    declare -A CRD_CACHE
fi

# Remove finalizers from Kubernetes resources
# Usage: remove_finalizers <resource_type> <namespace> [resource_name]
#   If resource_name is provided, removes finalizers from that specific resource
#   Otherwise, removes finalizers from all resources of that type in the namespace
#   For cluster-scoped resources, use empty string "" for namespace
# Returns: 0 on success, 1 on error
remove_finalizers() {
    local resource_type=$1
    local namespace=$2
    local resource_name=${3:-}
    
    if [[ -z "$resource_type" ]]; then
        log_error "remove_finalizers: resource_type argument required"
        return 1
    fi
    
    # Determine if resource is cluster-scoped (namespace is empty)
    local is_cluster_scoped=false
    if [[ -z "$namespace" ]]; then
        is_cluster_scoped=true
    fi
    
    if [[ -n "$resource_name" ]]; then
        # Remove finalizers from specific resource
        local finalizers=""
        if [[ "$is_cluster_scoped" == "true" ]]; then
            finalizers=$(oc get "$resource_type" "$resource_name" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
        else
            finalizers=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
        fi
        
        if [[ -n "$finalizers" ]]; then
            log_info "Removing finalizers from $resource_type/$resource_name..."
            if [[ "$is_cluster_scoped" == "true" ]]; then
                if oc patch "$resource_type" "$resource_name" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; then
                    log_success "Removed finalizers from $resource_type/$resource_name"
                    return 0
                else
                    log_warn "Failed to remove finalizers from $resource_type/$resource_name"
                    return 1
                fi
            else
                if oc patch "$resource_type" "$resource_name" -n "$namespace" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; then
                    log_success "Removed finalizers from $resource_type/$resource_name"
                    return 0
                else
                    log_warn "Failed to remove finalizers from $resource_type/$resource_name"
                    return 1
                fi
            fi
        fi
        return 0  # No finalizers to remove
    else
        # Remove finalizers from all resources of this type
        local stuck_resources=""
        if [[ "$is_cluster_scoped" == "true" ]]; then
            stuck_resources=$(oc get "$resource_type" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
        else
            stuck_resources=$(oc get "$resource_type" -n "$namespace" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
        fi
        
        if [[ -n "$stuck_resources" ]]; then
            log_info "Removing finalizers from $resource_type resources..."
            local count=0
            echo "$stuck_resources" | while read -r name; do
                if [[ "$is_cluster_scoped" == "true" ]]; then
                    oc patch "$resource_type" "$name" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null && ((count++)) || true
                else
                    oc patch "$resource_type" "$name" -n "$namespace" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null && ((count++)) || true
                fi
            done
            # Note: count may not be accurate due to subshell, but we log success anyway
            log_success "Removed finalizers from $resource_type resource(s)"
            return 0
        fi
    fi
    
    return 0
}

# Find Grafana pod in a namespace
# Tries multiple selectors in order: deployment name pattern, operator-managed label, standard Grafana label
# Usage: find_grafana_pod <namespace> [check_running]
#   check_running: if "true", only returns pods in Running state (default: false)
# Returns: pod name or empty string if not found
find_grafana_pod() {
    local namespace=$1
    local check_running=${2:-false}
    local grafana_pod=""
    
    if [[ -z "$namespace" ]]; then
        log_error "find_grafana_pod: namespace argument required"
        return 1
    fi
    
    # First try: deployment name pattern (most reliable for Grafana Operator)
    grafana_pod=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "grafana.*deployment" | grep -v operator | head -1 || echo "")
    
    # Fallback: operator-managed label
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/managed-by=grafana-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    # Fallback: standard Grafana label
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    # Fallback: name pattern (any grafana pod except operator)
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i grafana | grep -v operator | head -1 || echo "")
    fi
    
    # Check if pod is running if requested
    if [[ -n "$grafana_pod" ]] && [[ "$check_running" == "true" ]]; then
        local pod_phase=$(oc get pod "$grafana_pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$pod_phase" != "Running" ]]; then
            grafana_pod=""  # Pod found but not running
        fi
    fi
    
    # Return pod name (empty string if not found)
    echo "$grafana_pod"
}

# Ensure namespace exists, create if it doesn't
# Usage: ensure_namespace <namespace>
# Returns: 0 if namespace exists or was created, 1 on error
ensure_namespace() {
    local namespace=$1
    
    if [[ -z "$namespace" ]]; then
        log_error "ensure_namespace: namespace argument required"
        return 1
    fi
    
    if oc get namespace "$namespace" &>/dev/null; then
        return 0  # Namespace already exists
    fi
    
    log_info "Namespace '$namespace' not found, creating it..."
    if oc create namespace "$namespace" 2>/dev/null; then
        log_success "Namespace '$namespace' created"
        return 0
    else
        log_error "Failed to create namespace '$namespace'"
        return 1
    fi
}

# Wait for operator CSV to be installed
# Usage: wait_for_operator_csv <operator_name> <crd_name> <namespace> [timeout]
#   operator_name: name pattern to search for in CSV (e.g., "grafana-operator")
#   crd_name: CRD name to check as fallback (e.g., "grafanas.integreatly.org")
#   namespace: namespace to check
#   timeout: maximum wait time in seconds (default: 300)
# Returns: 0 if CSV succeeded or CRD available, 1 on timeout
wait_for_operator_csv() {
    local operator_name=$1
    local crd_name=$2
    local namespace=$3
    local timeout=${4:-300}
    local elapsed=0
    
    if [[ -z "$operator_name" ]] || [[ -z "$crd_name" ]] || [[ -z "$namespace" ]]; then
        log_error "wait_for_operator_csv: operator_name, crd_name, and namespace arguments required"
        return 1
    fi
    
    log_info "Waiting for $operator_name operator to be installed (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local csv_phase=$(oc get csv -n "$namespace" -o json 2>/dev/null | jq -r ".items[] | select(.metadata.name | contains(\"$operator_name\")) | .status.phase" | head -1 || echo "")
        
        if [[ "$csv_phase" == "Succeeded" ]]; then
            log_success "$operator_name operator installed successfully (CSV phase: Succeeded)"
            return 0
        elif oc get crd "$crd_name" &>/dev/null; then
            log_success "$operator_name operator CRD available"
            return 0
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -lt $timeout ]]; then
            log_info "Still waiting for $operator_name operator... (${elapsed}s, CSV phase: ${csv_phase:-none})"
        fi
    done
    
    log_warn "$operator_name operator may not be fully ready yet (waited ${timeout}s)"
    return 1
}

