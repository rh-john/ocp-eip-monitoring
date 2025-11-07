#!/bin/bash
#
# Test helper functions
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Wait for resource to be ready
wait_for_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="${3:-}"
    local timeout="${4:-300}"
    local condition="${5:-}"
    
    local cmd="oc get $resource_type $resource_name"
    [[ -n "$namespace" ]] && cmd="$cmd -n $namespace"
    
    log_info "Waiting for $resource_type/$resource_name to be ready (timeout: ${timeout}s)..."
    
    local waited=0
    while [[ $waited -lt $timeout ]]; do
        if eval "$cmd" &>/dev/null; then
            if [[ -z "$condition" ]]; then
                log_success "$resource_type/$resource_name exists"
                return 0
            else
                # Check condition
                local status=$(oc get "$resource_type" "$resource_name" ${namespace:+-n "$namespace"} -o jsonpath="$condition" 2>/dev/null || echo "")
                if [[ "$status" == "true" ]] || [[ "$status" == "Ready" ]] || [[ "$status" == "Succeeded" ]]; then
                    log_success "$resource_type/$resource_name is ready"
                    return 0
                fi
            fi
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]]; then
            log_info "Still waiting... (${waited}s elapsed)"
        fi
    done
    
    log_error "$resource_type/$resource_name not ready after ${timeout}s"
    return 1
}

# Verify pod is running
verify_pod_running() {
    local pod_name="$1"
    local namespace="${2:-$TEST_NAMESPACE}"
    
    local phase=$(oc get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    
    if [[ "$phase" == "Running" ]]; then
        log_success "Pod $pod_name is running"
        return 0
    else
        log_error "Pod $pod_name is not running (phase: $phase)"
        return 1
    fi
}

# Verify metrics are available in Prometheus
verify_metrics_available() {
    local metric_name="$1"
    local prometheus_url="${2:-}"
    local namespace="${3:-}"
    
    if [[ -z "$prometheus_url" ]]; then
        # Try to find Prometheus service
        if [[ -n "$namespace" ]]; then
            prometheus_url="http://prometheus.${namespace}.svc.cluster.local:9090"
        else
            log_error "Prometheus URL not provided and namespace not specified"
            return 1
        fi
    fi
    
    log_info "Querying Prometheus for metric: $metric_name"
    
    # Try to query Prometheus (may need port-forward or direct access)
    local result=$(oc exec -n "$namespace" $(oc get pods -n "$namespace" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') -- \
        curl -sf "http://localhost:9090/api/v1/query?query=${metric_name}" 2>/dev/null || echo "")
    
    if echo "$result" | grep -q "$metric_name"; then
        log_success "Metric $metric_name is available in Prometheus"
        return 0
    else
        log_warn "Metric $metric_name not found in Prometheus (may need to wait for scraping)"
        return 1
    fi
}

# Verify Grafana route is accessible
verify_grafana_accessible() {
    local namespace="${1:-$TEST_NAMESPACE}"
    
    log_info "Checking Grafana route accessibility..."
    
    local route=$(oc get route -n "$namespace" -l app=eip-monitor -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
    
    if [[ -z "$route" ]]; then
        log_error "Grafana route not found"
        return 1
    fi
    
    log_info "Grafana route: https://$route"
    
    # Try to access the route (may need authentication)
    local response=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$route" 2>/dev/null || echo "000")
    
    if [[ "$response" == "200" ]] || [[ "$response" == "302" ]] || [[ "$response" == "401" ]]; then
        log_success "Grafana route is accessible (HTTP $response)"
        return 0
    else
        log_warn "Grafana route returned HTTP $response"
        return 1
    fi
}

# Clean up test resources
cleanup_test_resources() {
    local namespace="${1:-$TEST_NAMESPACE}"
    
    log_info "Cleaning up test resources in namespace: $namespace"
    
    # Delete test deployments, services, etc.
    oc delete deployment,service,configmap -n "$namespace" -l test=true 2>/dev/null || true
    
    log_success "Test resources cleaned up"
}

# Run a test and track results
run_test() {
    local test_name="$1"
    local test_command="$2"
    local test_timeout="${3:-60}"
    
    log_info "Running test: $test_name"
    
    # Run test with timeout
    if timeout "$test_timeout" bash -c "$test_command" 2>&1; then
        log_success "✓ $test_name"
        return 0
    else
        log_error "✗ $test_name"
        return 1
    fi
}

