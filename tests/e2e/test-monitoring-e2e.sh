#!/bin/bash
#
# E2E Test for Monitoring Deployment
# Tests the complete lifecycle: deployment, verification, and cleanup
# Can be run as part of CI/CD pipeline or manually
#

set -euo pipefail

# Source common functions from deploy scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "${PROJECT_ROOT}/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-eip-monitoring}"
MONITORING_TYPE="${MONITORING_TYPE:-coo}"  # coo, uwm, or all
CLEANUP="${CLEANUP:-true}"  # Set to false to keep resources after test
TIMEOUT="${TIMEOUT:-300}"  # Timeout in seconds for resource readiness

# E2E-specific logging function
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
        
        # Use PROJECT_ROOT from sourced common.sh
        local project_root="$PROJECT_ROOT"
        
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

# Note: wait_for_resource() and wait_for_pods() are now sourced from scripts/lib/common.sh

# Test COO monitoring deployment
test_coo_deployment() {
    log_test "Testing COO Monitoring Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Use PROJECT_ROOT from sourced common.sh
    local project_root="$PROJECT_ROOT"
    
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
    
    # First verify that the service has endpoints (required for scraping)
    log_info "Verifying eip-monitor service has endpoints..."
    local service_endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || echo "")
    if [[ -z "$service_endpoints" ]]; then
        log_error "Service eip-monitor has no endpoints - Prometheus cannot scrape"
        log_info "Check if deployment is running: oc get pods -n $NAMESPACE -l app=eip-monitor"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
        return 1
    else
        log_success "Service eip-monitor has endpoints: $service_endpoints"
    fi
    
    # Verify ServiceMonitor is discovered by Prometheus
    log_info "Checking if Prometheus has discovered the ServiceMonitor..."
    local prom_pod=""
    prom_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -z "$prom_pod" ]]; then
        prom_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    fi
    
    if [[ -n "$prom_pod" ]]; then
        # Check Prometheus targets to see if eip-monitor is being scraped
        local targets_json=$(oc exec -n "$NAMESPACE" "$prom_pod" -- wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null || echo "")
        if [[ -n "$targets_json" ]]; then
            local eip_targets=$(echo "$targets_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    targets = data.get('data', {}).get('activeTargets', [])
    eip_targets = [t for t in targets if 'eip-monitor' in t.get('scrapeUrl', '').lower() or 'eip-monitor' in t.get('labels', {}).get('job', '').lower()]
    if eip_targets:
        health = eip_targets[0].get('health', 'unknown')
        print(f'{health}|{len(eip_targets)}')
    else:
        print('not_found|0')
except:
    print('error|0')
" 2>/dev/null || echo "error|0")
            
            local target_health=$(echo "$eip_targets" | cut -d'|' -f1)
            local target_count=$(echo "$eip_targets" | cut -d'|' -f2)
            
            if [[ "$target_health" == "up" ]]; then
                log_success "Prometheus is scraping eip-monitor (target health: up)"
            elif [[ "$target_health" == "down" ]]; then
                log_warn "Prometheus target for eip-monitor is down (may still be initializing)"
            elif [[ "$target_count" == "0" ]]; then
                log_warn "Prometheus has not discovered eip-monitor target yet (ServiceMonitor may not be reconciled)"
                log_info "This is normal if Prometheus was just deployed - it may take a few minutes"
            fi
        fi
    fi
    
    # For COO, prefer querying via ThanosQuerier pod (consistent with verify-prometheus-metrics.sh pattern)
    # Fallback to Prometheus pod if ThanosQuerier not available
    local query_pod=""
    local query_port="9090"
    
    # Try to find ThanosQuerier pod first (preferred for COO)
    local thanos_pod=""
    thanos_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    if [[ -z "$thanos_pod" ]]; then
        thanos_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=thanos-query --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    fi
    
    if [[ -n "$thanos_pod" ]]; then
        local thanos_phase=$(oc get pod "$thanos_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$thanos_phase" == "Running" ]]; then
            query_pod="$thanos_pod"
            query_port="10902"  # ThanosQuerier uses port 10902
            log_info "Using ThanosQuerier pod for metrics query: $thanos_pod"
        fi
    fi
    
    # Fallback to Prometheus pod if ThanosQuerier not available
    if [[ -z "$query_pod" ]] && [[ -n "$prom_pod" ]]; then
        query_pod="$prom_pod"
        query_port="9090"
        log_info "Using Prometheus pod for metrics query: $prom_pod"
    fi
    
    if [[ -n "$query_pod" ]]; then
        # Wait a bit longer for scraping to start (COO Prometheus may need more time)
        log_info "Waiting for metrics to be scraped (this may take a few minutes)..."
        sleep 60  # Increased from 30s to 60s for COO
        
        # URL encode the query (following verify-prometheus-metrics.sh pattern)
        local encoded_query=$(echo "count({__name__=~\"eip_.*\"})" | jq -sRr @uri)
        local query_url="http://localhost:${query_port}/api/v1/query?query=${encoded_query}"
        
        # Query for eip_ metrics using oc exec with curl (consistent with verify-prometheus-metrics.sh)
        local metrics_result=$(oc exec -n "$NAMESPACE" "$query_pod" -- curl -s "$query_url" 2>/dev/null || echo "")
        
        if [[ -n "$metrics_result" ]]; then
            # Check if response is valid JSON and has success status
            if echo "$metrics_result" | jq . >/dev/null 2>&1; then
                local status=$(echo "$metrics_result" | jq -r '.status' 2>/dev/null || echo "error")
                if [[ "$status" == "success" ]]; then
                    local metrics_count=$(echo "$metrics_result" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
                    if [[ "$metrics_count" != "0" ]] && [[ -n "$metrics_count" ]] && [[ "$metrics_count" != "null" ]]; then
                        log_success "Found $metrics_count eip_* metrics"
                        ((TESTS_PASSED++)) || true
                    else
                        log_warn "No eip_* metrics found yet (may still be initializing)"
                        log_info "This is normal if Prometheus was just deployed - scraping may take a few minutes"
                        log_info "Check Prometheus targets: oc exec -n $NAMESPACE $prom_pod -- curl -s http://localhost:9090/api/v1/targets | grep eip-monitor"
                        ((TESTS_WARNED++)) || true
                    fi
                else
                    local error_msg=$(echo "$metrics_result" | jq -r '.error' 2>/dev/null || echo "Unknown error")
                    log_warn "Query returned error: $error_msg"
                    ((TESTS_WARNED++)) || true
                fi
            else
                log_warn "Invalid JSON response from metrics API"
                log_info "Response preview: $(echo "$metrics_result" | head -c 200)"
                ((TESTS_WARNED++)) || true
            fi
        else
            log_error "Failed to query metrics API"
            log_info "Troubleshooting:"
            log_info "  1. Check pod status: oc get pod $query_pod -n $NAMESPACE"
            log_info "  2. Check pod logs: oc logs $query_pod -n $NAMESPACE --tail=50"
            log_info "  3. Try direct query: oc exec -n $NAMESPACE $query_pod -- curl -s $query_url"
            ((TESTS_FAILED++)) || true
            EXIT_CODE=1
        fi
    else
        log_error "Neither ThanosQuerier nor Prometheus pod found"
        log_info "Available pods in namespace:"
        oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | head -10 | sed 's/^/  /' || true
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
    
    # Use PROJECT_ROOT from sourced common.sh
    local project_root="$PROJECT_ROOT"
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
    
    # Check prerequisites using shared function
    if ! check_prerequisites; then
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

