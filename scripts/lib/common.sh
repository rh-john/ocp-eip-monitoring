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
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        return 1
    fi
    
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        return 1
    fi
    
    return 0
}

