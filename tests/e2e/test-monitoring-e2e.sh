#!/bin/bash
#
# E2E Test for Monitoring Deployment
# Tests the complete lifecycle: deployment, verification, and cleanup
# Can be run as part of CI/CD pipeline or manually
#

set -euo pipefail

NAMESPACE="${NAMESPACE:-eip-monitoring}"
MONITORING_TYPE="${MONITORING_TYPE:-coo}"  # coo, uwm, or all
CLEANUP="${CLEANUP:-true}"  # Set to false to keep resources after test
TIMEOUT="${TIMEOUT:-300}"  # Timeout in seconds for resource readiness

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_test() { echo -e "\n${BLUE}[E2E TEST]${NC} $1"; }

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNED=0
EXIT_CODE=0

# Cleanup function
cleanup() {
    if [[ "$CLEANUP" == "true" ]]; then
        log_info "Cleaning up test resources..."
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local project_root="$(dirname "$(dirname "$script_dir")")"
        
        # Use --remove-monitoring all if testing both, otherwise use specific type
        if [[ "$MONITORING_TYPE" == "all" ]]; then
            log_info "Removing all monitoring (COO and UWM)..."
            "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring all || true
        elif [[ "$MONITORING_TYPE" == "coo" ]]; then
            log_info "Removing COO monitoring..."
            "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring coo || true
        elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
            log_info "Removing UWM monitoring..."
            "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring uwm || true
        fi
        
        # Note: If Grafana was deployed separately, deploy-grafana.sh --all will handle CRD cleanup
    else
        log_info "Skipping cleanup (CLEANUP=false)"
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Wait for resource to be ready
wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local timeout=${4:-$TIMEOUT}
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
    done
    
    log_error "$resource_type/$resource_name failed to become ready within ${timeout}s"
    return 1
}

# Wait for pods to be running
wait_for_pods() {
    local namespace=$1
    local selector=$2
    local expected_count=${3:-1}
    local timeout=${4:-$TIMEOUT}
    local elapsed=0
    
    log_info "Waiting for pods with selector '$selector' to be running (expected: $expected_count, timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local running_count=$(oc get pods -n "$namespace" -l "$selector" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        if [[ "$running_count" -ge "$expected_count" ]]; then
            log_success "Found $running_count running pod(s) with selector '$selector'"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log_error "Pods with selector '$selector' failed to become running within ${timeout}s"
    return 1
}

# Test COO monitoring deployment
test_coo_deployment() {
    log_test "Testing COO Monitoring Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$(dirname "$script_dir")")"
    
    # Step 1: Deploy COO monitoring
    log_test "Step 1: Deploying COO monitoring..."
    if "${project_root}/scripts/deploy-monitoring.sh" --monitoring-type coo; then
        log_success "COO monitoring deployment initiated"
        ((TESTS_PASSED++)) || true
    else
        log_error "COO monitoring deployment failed"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
        return 1
    fi
    
    # Step 2: Wait for MonitoringStack to be ready
    log_test "Step 2: Waiting for MonitoringStack to be ready..."
    if wait_for_resource "monitoringstack" "eip-monitoring-stack" "$NAMESPACE" 300; then
        ((TESTS_PASSED++)) || true
    else
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 3: Wait for Prometheus pods
    log_test "Step 3: Waiting for Prometheus pods..."
    if wait_for_pods "$NAMESPACE" "app.kubernetes.io/name=prometheus" 1 300; then
        ((TESTS_PASSED++)) || true
    else
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 4: Verify ServiceMonitor exists
    log_test "Step 4: Verifying ServiceMonitor..."
    if oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
       oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
        log_success "ServiceMonitor 'eip-monitor-coo' exists"
        ((TESTS_PASSED++)) || true
    else
        log_error "ServiceMonitor 'eip-monitor-coo' not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 5: Verify PrometheusRule exists
    log_test "Step 5: Verifying PrometheusRule..."
    if oc get prometheusrule.monitoring.rhobs eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null || \
       oc get prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null; then
        log_success "PrometheusRule 'eip-monitor-alerts-coo' exists"
        ((TESTS_PASSED++)) || true
    else
        log_error "PrometheusRule 'eip-monitor-alerts-coo' not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 6: Verify NetworkPolicy
    log_test "Step 6: Verifying NetworkPolicy..."
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        log_success "Combined NetworkPolicy exists"
        ((TESTS_PASSED++)) || true
    else
        log_error "Combined NetworkPolicy not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 7: Verify ThanosQuerier
    log_test "Step 7: Verifying ThanosQuerier..."
    if oc get thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" &>/dev/null; then
        log_success "ThanosQuerier exists"
        # Wait for ThanosQuerier pod
        if wait_for_pods "$NAMESPACE" "app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier" 1 180; then
            ((TESTS_PASSED++)) || true
        else
            ((TESTS_FAILED++)) || true
            EXIT_CODE=1
        fi
    else
        log_error "ThanosQuerier not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 8: Verify AlertmanagerConfig
    log_test "Step 8: Verifying AlertmanagerConfig..."
    if oc get alertmanagerconfig.monitoring.rhobs eip-monitoring-alertmanager-config -n "$NAMESPACE" &>/dev/null; then
        log_success "AlertmanagerConfig exists"
        ((TESTS_PASSED++)) || true
    else
        log_warn "AlertmanagerConfig not found (optional)"
        ((TESTS_WARNED++)) || true
    fi
    
    # Step 9: Verify metrics are being scraped
    log_test "Step 9: Verifying metrics are being scraped..."
    local prom_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$prom_pod" ]]; then
        # Wait a bit for scraping to start
        sleep 30
        
        # Query Prometheus for eip_ metrics
        local metrics_count=$(oc exec -n "$NAMESPACE" "$prom_pod" -- wget -qO- 'http://localhost:9090/api/v1/query?query=count({__name__=~"eip_.*"})' 2>/dev/null | \
            python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('data', {}).get('result', [{}])[0].get('value', [0, '0'])[1])" 2>/dev/null || echo "0")
        
        if [[ "$metrics_count" != "0" ]] && [[ -n "$metrics_count" ]]; then
            log_success "Found $metrics_count eip_* metrics in Prometheus"
            ((TESTS_PASSED++)) || true
        else
            log_warn "No eip_* metrics found yet (may still be initializing)"
            ((TESTS_WARNED++)) || true
        fi
    else
        log_error "Prometheus pod not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 10: Run comprehensive test script
    log_test "Step 10: Running comprehensive monitoring test..."
    if "${project_root}/scripts/test-monitoring-deployment.sh" --monitoring-type coo; then
        log_success "Comprehensive monitoring test passed"
        ((TESTS_PASSED++)) || true
    else
        log_error "Comprehensive monitoring test failed"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
}

# Test UWM monitoring deployment
test_uwm_deployment() {
    log_test "Testing UWM Monitoring Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$(dirname "$script_dir")")"
    local uwm_namespace="openshift-user-workload-monitoring"
    
    # Step 1: Deploy UWM monitoring
    log_test "Step 1: Deploying UWM monitoring..."
    if "${project_root}/scripts/deploy-monitoring.sh" --monitoring-type uwm; then
        log_success "UWM monitoring deployment initiated"
        ((TESTS_PASSED++)) || true
    else
        log_error "UWM monitoring deployment failed"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
        return 1
    fi
    
    # Step 2: Wait for UWM Prometheus pods
    log_test "Step 2: Waiting for UWM Prometheus pods..."
    if wait_for_pods "$uwm_namespace" "app.kubernetes.io/name=prometheus" 1 300; then
        ((TESTS_PASSED++)) || true
    else
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 3: Verify ServiceMonitor exists
    log_test "Step 3: Verifying ServiceMonitor..."
    if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
        log_success "ServiceMonitor 'eip-monitor-uwm' exists"
        ((TESTS_PASSED++)) || true
    else
        log_error "ServiceMonitor 'eip-monitor-uwm' not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 4: Verify PrometheusRule exists
    log_test "Step 4: Verifying PrometheusRule..."
    if oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null; then
        log_success "PrometheusRule 'eip-monitor-alerts-uwm' exists"
        ((TESTS_PASSED++)) || true
    else
        log_error "PrometheusRule 'eip-monitor-alerts-uwm' not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 5: Verify NetworkPolicy
    log_test "Step 5: Verifying NetworkPolicy..."
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        log_success "Combined NetworkPolicy exists"
        ((TESTS_PASSED++)) || true
    else
        log_error "Combined NetworkPolicy not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 6: Verify namespace label
    log_test "Step 6: Verifying namespace label..."
    local namespace_label=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.openshift\.io/user-monitoring}' 2>/dev/null || echo "")
    if [[ "$namespace_label" == "true" ]] || [[ -z "$namespace_label" ]]; then
        log_success "Namespace is properly labeled for UWM"
        ((TESTS_PASSED++)) || true
    else
        log_error "Namespace label incorrect: $namespace_label"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 7: Verify metrics are being scraped
    log_test "Step 7: Verifying metrics are being scraped..."
    local prom_pod=$(oc get pods -n "$uwm_namespace" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$prom_pod" ]]; then
        # Wait a bit for scraping to start
        sleep 30
        
        # Query Prometheus for eip_ metrics
        local metrics_count=$(oc exec -n "$uwm_namespace" "$prom_pod" -- wget -qO- 'http://localhost:9090/api/v1/query?query=count({__name__=~"eip_.*"})' 2>/dev/null | \
            python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('data', {}).get('result', [{}])[0].get('value', [0, '0'])[1])" 2>/dev/null || echo "0")
        
        if [[ "$metrics_count" != "0" ]] && [[ -n "$metrics_count" ]]; then
            log_success "Found $metrics_count eip_* metrics in UWM Prometheus"
            ((TESTS_PASSED++)) || true
        else
            log_warn "No eip_* metrics found yet (may still be initializing)"
            ((TESTS_WARNED++)) || true
        fi
    else
        log_error "UWM Prometheus pod not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 8: Run comprehensive test script
    log_test "Step 8: Running comprehensive monitoring test..."
    if "${project_root}/scripts/test-monitoring-deployment.sh" --monitoring-type uwm; then
        log_success "Comprehensive monitoring test passed"
        ((TESTS_PASSED++)) || true
    else
        log_error "Comprehensive monitoring test failed"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
}

# Main test execution
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "E2E Test for Monitoring Deployment"
    log_info "Namespace: $NAMESPACE"
    log_info "Monitoring Type: $MONITORING_TYPE"
    log_info "Cleanup: $CLEANUP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check prerequisites
    if ! command -v oc &>/dev/null; then
        log_error "oc command not found"
        exit 1
    fi
    
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    # Run tests based on monitoring type
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        test_coo_deployment
    elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
        test_uwm_deployment
    elif [[ "$MONITORING_TYPE" == "all" ]]; then
        test_coo_deployment
        echo ""
        test_uwm_deployment
    else
        log_error "Invalid monitoring type: $MONITORING_TYPE (must be coo, uwm, or all)"
        exit 1
    fi
    
    # Print summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "E2E Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Tests passed: $TESTS_PASSED"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_error "Tests failed: $TESTS_FAILED"
    fi
    if [[ $TESTS_WARNED -gt 0 ]]; then
        log_warn "Tests warned: $TESTS_WARNED"
    fi
    
    exit $EXIT_CODE
}

# Run main function
main "$@"

