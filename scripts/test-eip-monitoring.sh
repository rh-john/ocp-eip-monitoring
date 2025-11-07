#!/bin/bash
#
# Test EIP monitor integration with monitoring
# Prerequisites: Requires eip-monitor deployment
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

# Test EIP monitor deployment
test_eip_monitor_deployment() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Testing EIP Monitor Deployment"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Test 1: Verify eip-monitor pod is running
    ((TOTAL_TESTS++))
    local pod_name=$(oc get pods -n "$TEST_NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        log_error "✗ eip-monitor pod not found"
        ((TESTS_FAILED++))
    elif verify_pod_running "$pod_name" "$TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 2: Verify Service exists and has endpoints
    ((TOTAL_TESTS++))
    if run_test "Service exists" \
        "oc get service eip-monitor -n $TEST_NAMESPACE"; then
        ((TESTS_PASSED++))
    else
        ((TESTS_FAILED++))
    fi
    
    # Test 3: Verify metrics endpoint is accessible
    ((TOTAL_TESTS++))
    if [[ -n "$pod_name" ]]; then
        if run_test "Metrics endpoint accessible" \
            "oc exec $pod_name -n $TEST_NAMESPACE -- curl -sf http://localhost:8080/metrics | head -1"; then
            ((TESTS_PASSED++))
        else
            ((TESTS_FAILED++))
        fi
    else
        log_error "✗ Cannot test metrics endpoint (pod not found)"
        ((TESTS_FAILED++))
    fi
    
    # Test 4: Verify required metrics are present
    ((TOTAL_TESTS++))
    if [[ -n "$pod_name" ]]; then
        local metrics_output=$(oc exec "$pod_name" -n "$TEST_NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
        if echo "$metrics_output" | grep -q "eips_configured_total"; then
            log_success "✓ Required metric 'eips_configured_total' present"
            ((TESTS_PASSED++))
        else
            log_error "✗ Required metric 'eips_configured_total' missing"
            ((TESTS_FAILED++))
        fi
    else
        log_error "✗ Cannot test metrics (pod not found)"
        ((TESTS_FAILED++))
    fi
    
    # Test 5: Verify additional required metrics
    local required_metrics=("eips_assigned_total" "cpic_success_total" "eip_scrape_errors_total")
    for metric in "${required_metrics[@]}"; do
        ((TOTAL_TESTS++))
        if [[ -n "$pod_name" ]]; then
            local metrics_output=$(oc exec "$pod_name" -n "$TEST_NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
            if echo "$metrics_output" | grep -q "$metric"; then
                log_success "✓ Required metric '$metric' present"
                ((TESTS_PASSED++))
            else
                log_error "✗ Required metric '$metric' missing"
                ((TESTS_FAILED++))
            fi
        else
            log_error "✗ Cannot test metric $metric (pod not found)"
            ((TESTS_FAILED++))
        fi
    done
}

# Test integration with monitoring
test_monitoring_integration() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Testing Monitoring Integration"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Detect monitoring type
    local monitoring_type="none"
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        monitoring_type="coo"
    elif oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -q 'enableUserWorkload: true'; then
        monitoring_type="uwm"
    fi
    
    log_info "Detected monitoring type: $monitoring_type"
    
    if [[ "$monitoring_type" == "none" ]]; then
        log_warn "No monitoring infrastructure detected. Skipping integration tests."
        return 0
    fi
    
    # Test 1: Verify metrics are scraped by Prometheus
    ((TOTAL_TESTS++))
    local prom_namespace=""
    if [[ "$monitoring_type" == "coo" ]]; then
        prom_namespace="$TEST_NAMESPACE"
    else
        prom_namespace="openshift-user-workload-monitoring"
    fi
    
    local prom_pod=$(oc get pods -n "$prom_namespace" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$prom_pod" ]]; then
        log_info "Waiting for Prometheus to scrape metrics (may take a few minutes)..."
        sleep 30  # Give Prometheus time to scrape
        
        if run_test "Metrics scraped by Prometheus" \
            "oc exec $prom_pod -n $prom_namespace -- curl -sf 'http://localhost:9090/api/v1/query?query=eips_configured_total' | grep -q 'eips_configured_total'"; then
            ((TESTS_PASSED++))
        else
            log_warn "Metrics may not be scraped yet (this is normal if ServiceMonitor was just created)"
            ((TESTS_FAILED++))
        fi
    else
        log_error "✗ Prometheus pod not found"
        ((TESTS_FAILED++))
    fi
    
    # Test 2: Verify metrics appear in Grafana datasource
    ((TOTAL_TESTS++))
    if oc get grafanadatasource -n "$TEST_NAMESPACE" &>/dev/null; then
        log_success "✓ Grafana datasource exists"
        ((TESTS_PASSED++))
    else
        log_warn "Grafana datasource not found (Grafana may not be deployed)"
        ((TESTS_FAILED++))
    fi
}

# Test metrics accuracy
test_metrics_accuracy() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Testing Metrics Accuracy"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local pod_name=$(oc get pods -n "$TEST_NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$pod_name" ]]; then
        log_error "Cannot test metrics accuracy (pod not found)"
        return 1
    fi
    
    # Test 1: Verify metric values are numeric
    ((TOTAL_TESTS++))
    local metrics_output=$(oc exec "$pod_name" -n "$TEST_NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
    local configured_count=$(echo "$metrics_output" | grep -v "^#" | grep "^eips_configured_total" | head -1 | awk '{print $NF}' | tr -d '\r' || echo "0")
    
    if [[ "$configured_count" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        log_success "✓ Metrics values are numeric (eips_configured_total: $configured_count)"
        ((TESTS_PASSED++))
    else
        log_error "✗ Metrics values may be invalid (got: '$configured_count')"
        ((TESTS_FAILED++))
    fi
    
    # Test 2: Verify metric labels are correct (if present)
    ((TOTAL_TESTS++))
    if echo "$metrics_output" | grep -qE "^[a-zA-Z_][a-zA-Z0-9_]*\{.*\}"; then
        log_success "✓ Metrics have proper label format"
        ((TESTS_PASSED++))
    else
        log_warn "Metrics may not have labels (this is acceptable)"
        ((TESTS_PASSED++))  # Not a failure, just informational
    fi
    
    # Test 3: Verify metric timestamps are current (check last scrape)
    ((TOTAL_TESTS++))
    local last_scrape=$(echo "$metrics_output" | grep "^eip_last_scrape_timestamp_seconds" | head -1 | awk '{print $NF}' | tr -d '\r' || echo "0")
    local current_time=$(date +%s)
    local time_diff=$((current_time - ${last_scrape%.*}))
    
    if [[ $time_diff -lt 300 ]]; then  # Less than 5 minutes old
        log_success "✓ Metrics are current (last scrape: ${time_diff}s ago)"
        ((TESTS_PASSED++))
    else
        log_warn "Metrics may be stale (last scrape: ${time_diff}s ago)"
        ((TESTS_FAILED++))
    fi
}

# Main test execution
main() {
    log_info "Starting EIP monitor integration tests..."
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
    
    # Check if eip-monitor is deployed
    if ! oc get deployment eip-monitor -n "$TEST_NAMESPACE" &>/dev/null; then
        log_error "eip-monitor deployment not found. Please deploy it first:"
        log_info "  ./scripts/build-and-deploy.sh deploy"
        exit 1
    fi
    
    # Run tests
    test_eip_monitor_deployment
    test_monitoring_integration
    test_metrics_accuracy
    
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

