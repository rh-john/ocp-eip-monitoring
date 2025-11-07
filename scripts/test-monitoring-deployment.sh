#!/bin/bash
#
# Test monitoring deployment (COO and UWM)
# Prerequisites: None - tests monitoring infrastructure only, does NOT require eip-monitor deployment
#

set -euo pipefail

# Load test configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/tests/config.sh"
source "${PROJECT_ROOT}/tests/helpers.sh"

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Test UWM deployment
test_uwm_deployment() {
    if [[ "$TEST_SKIP_UWM" == "true" ]]; then
        log_info "Skipping UWM tests"
        return 0
    fi
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Testing UWM Deployment"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Test 1: Verify UWM is enabled in cluster-monitoring-config
    ((TOTAL_TESTS++))
    if run_test "UWM enabled in cluster-monitoring-config" \
        "oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' | grep -q 'enableUserWorkload: true'"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 2: Verify user-workload-monitoring-config exists
    ((TOTAL_TESTS++))
    if run_test "user-workload-monitoring-config exists" \
        "oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 3: Verify openshift-user-workload-monitoring namespace exists
    ((TOTAL_TESTS++))
    if run_test "openshift-user-workload-monitoring namespace exists" \
        "oc get namespace openshift-user-workload-monitoring"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 4: Verify Prometheus pods are running
    ((TOTAL_TESTS++))
    if run_test "Prometheus pods running in openshift-user-workload-monitoring" \
        "oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --no-headers | grep -q Running"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 5: Verify ServiceMonitor is created
    ((TOTAL_TESTS++))
    if run_test "ServiceMonitor exists" \
        "oc get servicemonitor eip-monitor -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 6: Verify PrometheusRule is applied
    ((TOTAL_TESTS++))
    if run_test "PrometheusRule exists" \
        "oc get prometheusrule eip-monitor-alerts-uwm -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
}

# Test COO deployment
test_coo_deployment() {
    if [[ "$TEST_SKIP_COO" == "true" ]]; then
        log_info "Skipping COO tests"
        return 0
    fi
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Testing COO Deployment"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Test 1: Verify COO operator is installed
    ((TOTAL_TESTS++))
    if run_test "COO operator subscription exists" \
        "oc get subscription cluster-observability-operator -n openshift-operators"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 2: Verify MonitoringStack CR is created
    ((TOTAL_TESTS++))
    if run_test "MonitoringStack CR exists" \
        "oc get monitoringstack eip-monitoring-stack -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 3: Verify Prometheus pods are running (COO-managed)
    ((TOTAL_TESTS++))
    if run_test "COO Prometheus pods running" \
        "oc get pods -n $TEST_NAMESPACE -l app.kubernetes.io/name=prometheus --no-headers | grep -q Running"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 4: Verify ServiceMonitor is created
    ((TOTAL_TESTS++))
    if run_test "COO ServiceMonitor exists" \
        "oc get servicemonitor eip-monitor-coo -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 5: Verify PrometheusRule is applied
    ((TOTAL_TESTS++))
    if run_test "COO PrometheusRule exists" \
        "oc get prometheusrule eip-monitor-alerts-coo -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
}

# Test Grafana deployment
test_grafana_deployment() {
    if [[ "$TEST_SKIP_GRAFANA" == "true" ]]; then
        log_info "Skipping Grafana tests"
        return 0
    fi
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Testing Grafana Deployment"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Test 1: Verify Grafana operator is installed
    ((TOTAL_TESTS++))
    if run_test "Grafana operator CSV exists" \
        "oc get csv -n $TEST_NAMESPACE | grep -q grafana-operator"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 2: Verify Grafana instance is running
    ((TOTAL_TESTS++))
    if run_test "Grafana instance exists" \
        "oc get grafana eip-monitoring-grafana -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 3: Verify Grafana datasource is configured
    ((TOTAL_TESTS++))
    if run_test "Grafana datasource exists" \
        "oc get grafanadatasource -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 4: Verify Grafana dashboards are deployed
    ((TOTAL_TESTS++))
    local dashboard_count=$(oc get grafanadashboard -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dashboard_count" -gt 0 ]]; then
        log_success "✓ Grafana dashboards deployed ($dashboard_count found)"
        ((TESTS_PASSED++))
    else
        log_error "✗ No Grafana dashboards found"
        ((TESTS_FAILED++))
    fi
    ((TOTAL_TESTS++))
    
    # Test 5: Verify Grafana route is accessible
    if verify_grafana_accessible "$TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    ((TOTAL_TESTS++))
}

# Main test execution
main() {
    log_info "Starting monitoring deployment tests..."
    log_info "Namespace: $TEST_NAMESPACE"
    log_info "Timeout: ${TEST_TIMEOUT}s"
    
    # Check prerequisites
    if ! command -v oc &>/dev/null; then
        log_error "oc command not found. Please install OpenShift CLI."
        exit 1
    fi
    
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        exit 1
    fi
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    
    # Run tests based on what's detected
    local current_type=$(oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null && echo "coo" || \
        (oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -q 'enableUserWorkload: true' && echo "uwm" || echo "none"))
    
    log_info "Detected monitoring type: $current_type"
    
    if [[ "$current_type" == "coo" ]]; then
        test_coo_deployment
    elif [[ "$current_type" == "uwm" ]]; then
        test_uwm_deployment
    else
        log_warn "No monitoring infrastructure detected. Run deployment first."
    fi
    
    test_grafana_deployment
    
    # Print summary
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Test Summary"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Tests Passed: $TESTS_PASSED"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_error "Tests Failed: $TESTS_FAILED"
    else
        log_success "Tests Failed: $TESTS_FAILED"
    fi
    log_info "Total Tests: $TOTAL_TESTS"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All tests passed!"
        exit 0
    else
        log_error "Some tests failed"
        exit 1
    fi
}

# Run main function
main "$@"

