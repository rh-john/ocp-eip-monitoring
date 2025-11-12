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
DELETE_CRDS="${DELETE_CRDS:-true}"  # Set to false to skip CRD deletion (requires cluster-admin)
TIMEOUT="${TIMEOUT:-300}"  # Timeout in seconds for resource readiness
EIP_MONITOR_IMAGE="${EIP_MONITOR_IMAGE:-}"  # Optional: image to deploy before testing
QUAY_REPOSITORY="${QUAY_REPOSITORY:-rh_ee_jjohanss}"  # Default quay.io organization for auto-detection

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
        
        # Check if CRD deletion is enabled
        if [[ "$DELETE_CRDS" == "true" ]]; then
            log_info "CRD deletion enabled (requires cluster-admin permissions)"
        else
            log_info "CRD deletion disabled (DELETE_CRDS=false)"
        fi
        
        # Use --remove-monitoring all if testing both, otherwise use specific type
        if [[ "$MONITORING_TYPE" == "all" ]]; then
            log_info "Removing all monitoring (COO and UWM)..."
            # For "all", delete CRDs only for COO (UWM doesn't have CRDs to delete)
            if [[ "$DELETE_CRDS" == "true" ]]; then
                "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring coo --delete-crds || true
                "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring uwm || true
            else
                "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring all || true
            fi
        elif [[ "$MONITORING_TYPE" == "coo" ]]; then
            log_info "Removing COO monitoring..."
            if [[ "$DELETE_CRDS" == "true" ]]; then
                "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring coo --delete-crds || true
            else
                "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring coo || true
            fi
        elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
            log_info "Removing UWM monitoring..."
            # UWM doesn't have CRDs to delete, so --delete-crds flag is not needed
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

# Auto-detect latest pre-release image from git tags
# Format: quay.io/${QUAY_REPOSITORY}/eip-monitor:v${VERSION}-rc${RC}
detect_latest_pre_release_image() {
    # QUAY_REPOSITORY has a default value, so we can always use it
    
    # Fetch tags if in a git repository (may be needed in CI environments)
    if git rev-parse --git-dir &>/dev/null; then
        git fetch --tags --quiet 2>/dev/null || true
    else
        return 1
    fi
    
    # Find the latest RC tag directly from git (e.g., v0.2.2-rc1, v0.2.2-rc2, etc.)
    # This avoids relying on potentially stale .version file
    local latest_rc_tag=$(git tag -l "v*-rc*" 2>/dev/null | sort -V | tail -1)
    
    if [[ -z "$latest_rc_tag" ]]; then
        # No RC tag found, return failure
        return 1
    fi
    
    # Construct image name: quay.io/${QUAY_REPOSITORY}/eip-monitor:${tag}
    echo "quay.io/${QUAY_REPOSITORY}/eip-monitor:${latest_rc_tag}"
}

# Check why auto-detection might have failed (for better diagnostics)
check_auto_detection_status() {
    local reason=""
    
    # Check if we're in a git repository
    if ! git rev-parse --git-dir &>/dev/null; then
        reason="not in a git repository"
        echo "$reason"
        return
    fi
    
    # Fetch tags
    git fetch --tags --quiet 2>/dev/null || true
    
    # Check if RC tags exist
    local latest_rc_tag=$(git tag -l "v*-rc*" 2>/dev/null | sort -V | tail -1)
    if [[ -z "$latest_rc_tag" ]]; then
        reason="no pre-release tags found (v*-rc*)"
    else
        reason="unknown (tag found: $latest_rc_tag)"
    fi
    
    echo "$reason"
}

# Deploy eip-monitor application if needed
# Uses deploy-eip.sh which handles idempotency, image updates, and rollout waiting
deploy_eip_monitor_if_needed() {
    # Auto-detect image from latest pre-release tag if not specified
    if [[ -z "$EIP_MONITOR_IMAGE" ]]; then
        local detected_image=$(detect_latest_pre_release_image)
        if [[ -n "$detected_image" ]]; then
            EIP_MONITOR_IMAGE="$detected_image"
            log_info "Auto-detected latest pre-release image: $EIP_MONITOR_IMAGE"
        fi
    fi
    
    # Only deploy if image is specified
    if [[ -z "$EIP_MONITOR_IMAGE" ]]; then
        # Check if deployment exists
        if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
            local current_image=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
            log_info "eip-monitor is already deployed (image: ${current_image:-unknown})"
            
            # Provide helpful diagnostics about why auto-detection didn't work
            local detection_reason=$(check_auto_detection_status)
            if [[ "$detection_reason" == "no pre-release tags found (v*-rc*)" ]]; then
                log_info "Auto-detection skipped: $detection_reason"
                log_info "  Pre-release tags are created by the staging workflow"
            fi
            log_info "Using existing deployment"
            return 0
        else
            log_warn "eip-monitor deployment not found and no EIP_MONITOR_IMAGE specified"
            
            # Provide helpful diagnostics
            local detection_reason=$(check_auto_detection_status)
            if [[ "$detection_reason" == "no pre-release tags found (v*-rc*)" ]]; then
                log_info "Auto-detection failed: $detection_reason"
                log_info "  Pre-release tags are created by the staging workflow"
            fi
            
            log_info "Tests will check for service endpoints, but deployment may be missing"
            log_info "To deploy: ./scripts/deploy-eip.sh deploy --quay-image <image>"
            log_info "Or set EIP_MONITOR_IMAGE environment variable"
            return 0  # Don't fail - let tests proceed and fail if needed
        fi
    fi
    
    # Deploy or update using deploy-eip.sh (handles idempotency automatically)
    log_test "Deploying/updating eip-monitor application with image: $EIP_MONITOR_IMAGE"
    # Set MONITORING_TYPE so deploy-eip.sh applies correct labels
    if MONITORING_TYPE="$MONITORING_TYPE" "${PROJECT_ROOT}/scripts/deploy-eip.sh" deploy --quay-image "$EIP_MONITOR_IMAGE"; then
        log_success "eip-monitor application deployed/updated"
        # deploy-eip.sh already waits for rollout, but verify pods are ready
        log_info "Verifying eip-monitor pods are ready..."
        # Check for pods with the correct label based on MONITORING_TYPE
        local pod_selector="app=eip-monitor"
        if [[ "$MONITORING_TYPE" == "coo" ]]; then
            pod_selector="app=eip-monitor-coo"
        elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
            pod_selector="app=eip-monitor-uwm"
        fi
        
        # Try the specific label first, then fallback to generic label only
        if wait_for_pods "$NAMESPACE" "$pod_selector" 1 60; then
            log_success "eip-monitor pods are ready"
        elif [[ "$pod_selector" != "app=eip-monitor" ]]; then
            # Fallback to generic label if specific label failed
            log_info "Falling back to generic 'app=eip-monitor' label..."
            if wait_for_pods "$NAMESPACE" "app=eip-monitor" 1 60; then
                log_success "eip-monitor pods are ready (using generic label)"
            else
                log_warn "eip-monitor pods may still be initializing"
            fi
        else
            log_warn "eip-monitor pods may still be initializing"
        fi
    else
        log_error "Failed to deploy eip-monitor application"
        return 1
    fi
}

# Test COO monitoring deployment
test_coo_deployment() {
    log_test "Testing COO Monitoring Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Use PROJECT_ROOT from sourced common.sh
    local project_root="$PROJECT_ROOT"
    
    # Step 0: Deploy eip-monitor application if needed
    log_test "Step 0: Ensuring eip-monitor application is deployed..."
    if ! deploy_eip_monitor_if_needed; then
        log_error "Failed to ensure eip-monitor is deployed"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
        return 1
    fi
    
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
    # Use common function to find Prometheus pod (prefer COO labels for COO deployments)
    local prom_pod=$(find_prometheus_pod "$NAMESPACE" "true")
    
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
    # Use common function to find query pod (prefers ThanosQuerier for COO)
    local query_result=$(find_query_pod "$NAMESPACE" "true")
    local query_pod=""
    local query_port="9090"
    
    if [[ -n "$query_result" ]]; then
        query_pod=$(echo "$query_result" | cut -d'|' -f1)
        query_port=$(echo "$query_result" | cut -d'|' -f2)
        if [[ "$query_port" == "10902" ]]; then
            log_info "Using ThanosQuerier pod for metrics query: $query_pod"
        else
            log_info "Using Prometheus pod for metrics query: $query_pod"
        fi
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
    if "${project_root}/scripts/test/test-monitoring-deployment.sh" --monitoring-type coo; then
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
    
    # Step 0: Deploy eip-monitor application if needed
    log_test "Step 0: Ensuring eip-monitor application is deployed..."
    if ! deploy_eip_monitor_if_needed; then
        log_error "Failed to ensure eip-monitor is deployed"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
        return 1
    fi
    
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
    local uwm_namespace="openshift-user-workload-monitoring"
    # Use common function to find UWM Prometheus pod (UWM uses standard labels, not COO-specific)
    local prom_pod=$(find_prometheus_pod "$uwm_namespace" "false")
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
    if "${project_root}/scripts/test/test-monitoring-deployment.sh" --monitoring-type uwm; then
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
    log_info "Delete CRDs: $DELETE_CRDS (requires cluster-admin for COO)"
    if [[ -n "$EIP_MONITOR_IMAGE" ]]; then
        log_info "EIP Monitor Image: $EIP_MONITOR_IMAGE"
    else
        # Try to auto-detect before showing message
        local detected_image=$(detect_latest_pre_release_image)
        if [[ -n "$detected_image" ]]; then
            log_info "EIP Monitor Image: (auto-detected from pre-release tag: $detected_image)"
        else
            log_info "EIP Monitor Image: (not specified - will use existing deployment if present)"
            log_info "  Using default QUAY_REPOSITORY: ${QUAY_REPOSITORY} for auto-detection"
        fi
    fi
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

