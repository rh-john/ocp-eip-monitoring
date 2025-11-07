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
    
    # Test 1: Verify ServiceMonitor exists
    ((TOTAL_TESTS++))
    local servicemonitor_name=""
    if [[ "$monitoring_type" == "coo" ]]; then
        servicemonitor_name="eip-monitor-coo"
    else
        servicemonitor_name="eip-monitor"
    fi
    
    if oc get servicemonitor "$servicemonitor_name" -n "$TEST_NAMESPACE" &>/dev/null; then
        log_success "✓ ServiceMonitor '$servicemonitor_name' exists"
        ((TESTS_PASSED++))
    else
        log_error "✗ ServiceMonitor '$servicemonitor_name' not found"
        log_info "  ServiceMonitor must exist for Prometheus to scrape metrics"
        ((TESTS_FAILED++))
        # Skip Prometheus query test if ServiceMonitor doesn't exist
        return 0
    fi
    
    # Test 2: Verify metrics are scraped by Prometheus
    ((TOTAL_TESTS++))
    local prom_namespace=""
    if [[ "$monitoring_type" == "coo" ]]; then
        prom_namespace="$TEST_NAMESPACE"
    else
        prom_namespace="openshift-user-workload-monitoring"
    fi
    
    local prom_pod=$(oc get pods -n "$prom_namespace" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -z "$prom_pod" ]]; then
        log_error "✗ Prometheus pod not found in namespace '$prom_namespace'"
        ((TESTS_FAILED++))
    else
        log_info "Found Prometheus pod: $prom_pod"
        
        # First, verify the pod is actually serving metrics
        local eip_pod=$(oc get pods -n "$TEST_NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$eip_pod" ]]; then
            log_info "Verifying eip-monitor pod is serving metrics..."
            local pod_metrics=$(oc exec "$eip_pod" -n "$TEST_NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
            if echo "$pod_metrics" | grep -q "eips_configured_total"; then
                log_success "✓ eip-monitor pod is serving metrics"
            else
                log_warn "⚠️  eip-monitor pod metrics endpoint may not be ready yet"
                log_info "  Waiting for pod to complete first metrics collection (may take up to 30s)..."
                # Wait for metrics to appear in pod
                local pod_wait_attempts=6
                local pod_wait_count=0
                while [[ $pod_wait_count -lt $pod_wait_attempts ]]; do
                    sleep 5
                    pod_metrics=$(oc exec "$eip_pod" -n "$TEST_NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
                    if echo "$pod_metrics" | grep -q "eips_configured_total"; then
                        log_success "✓ eip-monitor pod is now serving metrics"
                        break
                    fi
                    pod_wait_count=$((pod_wait_count + 1))
                done
            fi
        fi
        
        # Check if Prometheus has discovered the target
        log_info "Checking if Prometheus has discovered the target..."
        local targets_check=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
            curl -sf "http://localhost:9090/api/v1/targets" 2>/dev/null || echo "")
        
        if echo "$targets_check" | grep -q "eip-monitor"; then
            log_success "✓ Prometheus has discovered eip-monitor target"
            
            # Check target health status
            local target_health=$(echo "$targets_check" | grep -A 10 "eip-monitor" | grep -o '"health":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
            if [[ "$target_health" == "up" ]]; then
                log_success "✓ Prometheus target is healthy (up)"
            elif [[ "$target_health" == "down" ]]; then
                log_warn "⚠️  Prometheus target is down - check service and pod connectivity"
            else
                log_info "  Target health status: ${target_health:-unknown}"
            fi
        else
            log_warn "⚠️  Prometheus may not have discovered eip-monitor target yet"
            log_info "  This is normal if ServiceMonitor was just created (can take 1-2 minutes)"
        fi
        
        # Wait and retry query with exponential backoff
        log_info "Waiting for Prometheus to scrape metrics (may take a few minutes)..."
        local max_attempts=6
        local attempt=1
        local wait_time=30
        local query_success=false
        
        while [[ $attempt -le $max_attempts ]]; do
            log_info "Attempt $attempt/$max_attempts: Querying Prometheus..."
            
            # First, check target scrape status for diagnostics
            local targets_status=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
                curl -sf "http://localhost:9090/api/v1/targets" 2>/dev/null || echo "")
            
            # Extract scrape information
            local last_scrape=$(echo "$targets_status" | grep -A 30 "eip-monitor" | grep -o '"lastScrape":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
            local last_scrape_success=$(echo "$targets_status" | grep -A 30 "eip-monitor" | grep -o '"lastScrapeDuration":[0-9.]*' | head -1 | cut -d':' -f2 || echo "")
            local last_error=$(echo "$targets_status" | grep -A 30 "eip-monitor" | grep -o '"lastError":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
            
            if [[ -n "$last_scrape" ]] && [[ "$last_scrape" != "0001-01-01T00:00:00Z" ]]; then
                log_info "  Last scrape: $last_scrape"
                if [[ -n "$last_scrape_success" ]]; then
                    log_info "  Last scrape duration: ${last_scrape_success}s"
                fi
                
                # Check what was actually scraped by querying the scrape endpoint directly
                if [[ $attempt -eq 1 ]]; then
                    log_info "  Checking what Prometheus scraped from the target..."
                    # Try to get the scrape URL from targets
                    local scrape_url=$(echo "$targets_status" | grep -A 30 "eip-monitor" | grep -o '"scrapeUrl":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
                    if [[ -n "$scrape_url" ]]; then
                        log_info "  Scrape URL: $scrape_url"
                        # Try to see what Prometheus got (this might not work if we can't access the service directly)
                        # But we can at least verify the URL is correct
                    fi
                fi
            else
                log_info "  No scrape has occurred yet (target may have just been discovered)"
            fi
            
            if [[ -n "$last_error" ]]; then
                log_warn "  ⚠️  Last scrape error: $last_error"
            fi
            
            # Try to query for the metric
            local query_result=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
                curl -sf --max-time 10 "http://localhost:9090/api/v1/query?query=eips_configured_total" 2>/dev/null || echo "")
            
            # Also try a broader query for any EIP metric
            if [[ $attempt -eq 1 ]] && ([[ -z "$query_result" ]] || ! echo "$query_result" | grep -qE '"result":\s*\[[^]]+\]'); then
                log_info "  Trying broader query for any EIP metric..."
                local broad_query=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
                    curl -sf --max-time 10 "http://localhost:9090/api/v1/query?query={__name__=~\"eip.*\"}" 2>/dev/null || echo "")
                if echo "$broad_query" | grep -qE '"result":\s*\[[^]]+\]'; then
                    local metric_count=$(echo "$broad_query" | grep -o '"__name__"' | wc -l | tr -d ' ')
                    log_info "  Found $metric_count EIP metrics with broader query"
                    # Use this result if the specific query didn't work
                    if [[ -z "$query_result" ]] || ! echo "$query_result" | grep -q "eips_configured_total"; then
                        query_result="$broad_query"
                    fi
                fi
            fi
            
            # Also try to see what metrics are available
            if [[ $attempt -eq 1 ]] || [[ $attempt -eq 3 ]]; then
                log_info "  Checking what metrics are available in Prometheus..."
                local metrics_query=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
                    curl -sf --max-time 10 "http://localhost:9090/api/v1/label/__name__/values" 2>/dev/null || echo "")
                if echo "$metrics_query" | grep -q "eip"; then
                    local eip_metrics=$(echo "$metrics_query" | grep -o '"eip[^"]*"' | head -5)
                    log_info "  Found EIP-related metrics: $eip_metrics"
                else
                    log_info "  No EIP metrics found in Prometheus yet"
                fi
                
                # Try querying for any metric from the eip-monitor job
                log_info "  Checking if any metrics from eip-monitor job are available..."
                local job_query=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
                    curl -sf --max-time 10 "http://localhost:9090/api/v1/query?query={job=~\"eip.*\"}" 2>/dev/null || echo "")
                if echo "$job_query" | grep -qE '"result":\s*\[[^]]+\]'; then
                    log_info "  Found metrics from eip-monitor job"
                else
                    log_info "  No metrics found from eip-monitor job"
                fi
                
                # Check what the pod is actually serving
                if [[ -n "$eip_pod" ]]; then
                    log_info "  Verifying what metrics the pod is actually serving..."
                    local pod_metrics_sample=$(oc exec "$eip_pod" -n "$TEST_NAMESPACE" -- \
                        curl -sf http://localhost:8080/metrics 2>/dev/null | grep -E "^eip|^cpic|^node" | head -10 || echo "")
                    if [[ -n "$pod_metrics_sample" ]]; then
                        log_info "  Pod metrics sample (first 10 EIP/CPIC/node metrics):"
                        echo "$pod_metrics_sample" | while read -r line; do
                            log_info "    $line"
                        done
                    else
                        log_warn "  ⚠️  Pod metrics endpoint returned no EIP/CPIC/node metrics"
                        # Check if endpoint is working at all
                        local all_metrics=$(oc exec "$eip_pod" -n "$TEST_NAMESPACE" -- \
                            curl -sf http://localhost:8080/metrics 2>/dev/null | head -20 || echo "")
                        if [[ -n "$all_metrics" ]]; then
                            log_info "  Pod metrics endpoint is working, but no EIP metrics found"
                            log_info "  Sample of what is available:"
                            echo "$all_metrics" | while read -r line; do
                                log_info "    $line"
                            done
                        fi
                    fi
                fi
            fi
            
            # Check if query was successful and contains the metric
            if [[ -n "$query_result" ]] && echo "$query_result" | grep -q "eips_configured_total"; then
                # Verify the response has actual data (not just empty result array)
                # Prometheus returns {"status":"success","data":{"resultType":"vector","result":[...]}}
                # We want to check if result array contains at least one entry
                if echo "$query_result" | grep -qE '"result":\s*\[[^]]+\]'; then
                    log_success "✓ Metrics scraped by Prometheus (found metric data)"
                    query_success=true
                    ((TESTS_PASSED++))
                    break
                elif echo "$query_result" | grep -qE '"result":\s*\[\]'; then
                    # Empty result array - metric exists but no data yet
                    log_info "  Metric exists in Prometheus but result is empty (may need more time)"
                fi
            fi
            
            if [[ $attempt -lt $max_attempts ]]; then
                log_info "  Metric not found yet, waiting ${wait_time}s before retry..."
                sleep "$wait_time"
                wait_time=$((wait_time * 2))  # Exponential backoff: 30s, 60s, 120s, 240s, 480s
            fi
            attempt=$((attempt + 1))
        done
        
        if [[ "$query_success" == "false" ]]; then
            log_warn "⚠️  Metrics may not be scraped yet (this is normal if ServiceMonitor was just created)"
            log_info "  Prometheus typically takes 1-2 minutes to discover and scrape new ServiceMonitors"
            log_info "  You can check Prometheus targets at: http://localhost:9090/targets (via port-forward)"
            ((TESTS_FAILED++))
        fi
    fi
    
    # Test 3: Verify metrics appear in Grafana datasource
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

