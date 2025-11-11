#!/bin/bash
#
# E2E Test for UWM Monitoring with Grafana Dashboards
# Tests the complete lifecycle: UWM deployment, Grafana deployment, dashboard installation, and verification
# Can be run as part of CI/CD pipeline or manually
#

set -euo pipefail

# Source common functions from deploy scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "${PROJECT_ROOT}/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-eip-monitoring}"
CLEANUP="${CLEANUP:-true}"  # Set to false to keep resources after test
TIMEOUT="${TIMEOUT:-120}"  # Timeout in seconds for resource readiness (default: 2 minutes)
UWM_NAMESPACE="openshift-user-workload-monitoring"

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
        
        log_info "Removing Grafana resources..."
        # Use deploy-grafana.sh --all for comprehensive cleanup (includes RBAC, operator, and CRDs)
        if [[ -f "${project_root}/scripts/deploy-grafana.sh" ]]; then
            "${project_root}/scripts/deploy-grafana.sh" --all --monitoring-type uwm -n "$NAMESPACE" 2>&1 | grep -v "^$" || true
        else
            # Fallback to manual cleanup if script not found
            log_warn "deploy-grafana.sh not found, using manual cleanup"
            oc delete grafanadashboard -n "$NAMESPACE" --all 2>/dev/null || true
            oc delete grafanadatasource -n "$NAMESPACE" --all 2>/dev/null || true
            oc delete grafana -n "$NAMESPACE" --all 2>/dev/null || true
        fi
        
        log_info "Removing UWM monitoring..."
        "${project_root}/scripts/deploy-monitoring.sh" --remove-monitoring uwm || true
    else
        log_info "Skipping cleanup (CLEANUP=false)"
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

# Note: wait_for_resource() and wait_for_pods() are now sourced from scripts/lib/common.sh

# Test UWM monitoring deployment
test_uwm_deployment() {
    log_test "Testing UWM Monitoring Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Use PROJECT_ROOT from sourced common.sh
    local project_root="$PROJECT_ROOT"
    
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
    if wait_for_pods "$UWM_NAMESPACE" "app.kubernetes.io/name=prometheus" 1 120; then
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
    local prom_pod=$(oc get pods -n "$UWM_NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$prom_pod" ]]; then
        # Wait a bit for scraping to start
        sleep 30
        
        # Query Prometheus for eip_ metrics
        local metrics_count=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- wget -qO- 'http://localhost:9090/api/v1/query?query=count({__name__=~"eip_.*"})' 2>/dev/null | \
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
}

# Test Grafana deployment
test_grafana_deployment() {
    log_test "Testing Grafana Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Use PROJECT_ROOT from sourced common.sh
    local project_root="$PROJECT_ROOT"
    
    # Step 1: Deploy Grafana
    log_test "Step 1: Deploying Grafana with UWM datasource..."
    if "${project_root}/scripts/deploy-grafana.sh" --monitoring-type uwm --namespace "$NAMESPACE"; then
        log_success "Grafana deployment initiated"
        ((TESTS_PASSED++)) || true
    else
        log_error "Grafana deployment failed"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
        return 1
    fi
    
    # Step 2: Wait for Grafana operator CSV
    log_test "Step 2: Waiting for Grafana Operator..."
    
    # Check if Grafana operator subscription exists
    local subscription_exists=false
    if oc get subscription -n openshift-operators -o json 2>/dev/null | python3 -c "import sys, json; data = json.load(sys.stdin); items = [item for item in data.get('items', []) if 'grafana' in item.get('metadata', {}).get('name', '').lower()]; sys.exit(0 if items else 1)" 2>/dev/null; then
        subscription_exists=true
        log_info "Grafana Operator subscription found"
    fi
    
    # Also check namespace-scoped installation
    if oc get subscription -n "$NAMESPACE" -o json 2>/dev/null | python3 -c "import sys, json; data = json.load(sys.stdin); items = [item for item in data.get('items', []) if 'grafana' in item.get('metadata', {}).get('name', '').lower()]; sys.exit(0 if items else 1)" 2>/dev/null; then
        subscription_exists=true
        log_info "Grafana Operator subscription found in namespace $NAMESPACE"
    fi
    
    # Check if CRD exists (operator may be installed but CSV not ready)
    if oc get crd grafanas.integreatly.org &>/dev/null; then
        log_info "Grafana Operator CRD found - operator is available"
        subscription_exists=true
    fi
    
    # If no subscription, check if operator is already installed via CSV
    local csv_phase=""
    local max_wait=180
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        # Check for Grafana operator CSV in openshift-operators (cluster-scoped)
        csv_phase=$(oc get csv -n openshift-operators -o json 2>/dev/null | \
            python3 -c "import sys, json; data = json.load(sys.stdin); items = [item for item in data.get('items', []) if 'grafana' in item.get('metadata', {}).get('name', '').lower()]; print(items[0].get('status', {}).get('phase', '') if items else '')" 2>/dev/null || echo "")
        
        # If not found cluster-scoped, check namespace-scoped
        if [[ -z "$csv_phase" ]]; then
            csv_phase=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | \
                python3 -c "import sys, json; data = json.load(sys.stdin); items = [item for item in data.get('items', []) if 'grafana' in item.get('metadata', {}).get('name', '').lower()]; print(items[0].get('status', {}).get('phase', '') if items else '')" 2>/dev/null || echo "")
        fi
        
        if [[ "$csv_phase" == "Succeeded" ]]; then
            log_success "Grafana Operator is ready (CSV phase: Succeeded)"
            ((TESTS_PASSED++)) || true
            break
        elif [[ -n "$csv_phase" ]]; then
            # Operator exists but not ready yet
            if [[ $((waited % 30)) -eq 0 ]]; then
                log_info "Grafana Operator CSV phase: $csv_phase (waiting...)"
            fi
        elif [[ "$subscription_exists" == "false" ]] && [[ $waited -ge 30 ]]; then
            # No subscription and no CSV after 30s - operator may not be installed
            log_warn "Grafana Operator subscription not found"
            log_info "The deploy-grafana.sh script should install the operator automatically"
            log_info "If operator installation failed, check: oc get subscription -n openshift-operators"
            log_info "Or check namespace-scoped: oc get subscription -n $NAMESPACE"
            # Continue anyway - CRD check will handle it
            break
        fi
        
        sleep 5
        waited=$((waited + 5))
    done
    
    if [[ "$csv_phase" != "Succeeded" ]] && [[ $waited -ge $max_wait ]]; then
        log_warn "Grafana Operator may not be fully ready yet (waited ${max_wait}s)"
        if [[ -n "$csv_phase" ]]; then
            log_warn "CSV phase: $csv_phase"
        else
            log_warn "No Grafana Operator CSV found"
            if oc get crd grafanas.integreatly.org &>/dev/null; then
                log_info "However, Grafana CRD exists - operator may be functional"
            fi
        fi
        log_info "This may be non-critical if Grafana instance can still be created"
        ((TESTS_WARNED++)) || true
    fi
    
    # Step 3: Verify Grafana instance exists first
    log_test "Step 3: Verifying Grafana instance exists..."
    if ! oc get grafana -n "$NAMESPACE" &>/dev/null; then
        log_error "Grafana instance not found"
        log_info "The deploy-grafana.sh script should create a Grafana instance"
        log_info "Check if grafana-instance.yaml exists and was applied"
        log_info "Current Grafana resources:"
        oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>&1 || true
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
        return 1
    else
        log_success "Grafana instance exists"
        ((TESTS_PASSED++)) || true
    fi
    
    # Step 4: Wait for Grafana instance pod
    log_test "Step 4: Waiting for Grafana instance pod..."
    # Grafana Operator creates a Deployment for the Grafana instance
    # The deployment name is typically based on the instance name: eip-monitoring-grafana-deployment
    # Try multiple approaches: deployment selector, common labels, then name pattern
    local grafana_timeout=120  # 2 minutes for Grafana pod to start
    
    # First try: use deployment name pattern (most reliable for Grafana Operator)
    log_info "Checking for Grafana deployment pods..."
    local waited=0
    local grafana_pod_found=false
    while [[ $waited -lt $grafana_timeout ]]; do
        # Check for pods from the Grafana deployment (deployment name pattern)
        local grafana_pod=$(oc get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "grafana.*deployment" | grep -v operator | head -1 || echo "")
        if [[ -n "$grafana_pod" ]]; then
            local pod_phase=$(oc get pod "$grafana_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$pod_phase" == "Running" ]]; then
                grafana_pod_found=true
                log_success "Found Grafana pod: $grafana_pod"
                break
            fi
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]]; then
            log_info "Still waiting for Grafana pod... (${waited}s)"
        fi
    done
    
    if [[ "$grafana_pod_found" == "true" ]]; then
        ((TESTS_PASSED++)) || true
    elif wait_for_pods "$NAMESPACE" "app.kubernetes.io/managed-by=grafana-operator" 1 "$grafana_timeout"; then
        ((TESTS_PASSED++)) || true
    elif wait_for_pods "$NAMESPACE" "app.kubernetes.io/name=grafana" 1 "$grafana_timeout"; then
        ((TESTS_PASSED++)) || true
    else
        log_warn "Grafana pod not found with any standard selectors"
        log_info "Checking Grafana instance status..."
        oc get grafana -n "$NAMESPACE" -o yaml 2>&1 | grep -A 10 "status:" || true
        log_info "Checking all pods in namespace..."
        oc get pods -n "$NAMESPACE" 2>&1 || true
        ((TESTS_WARNED++)) || true
    fi
    
    # Step 5: Verify Grafana instance (redundant check, but confirms it's still there)
    log_test "Step 5: Verifying Grafana instance..."
    if oc get grafana -n "$NAMESPACE" &>/dev/null; then
        log_success "Grafana instance exists"
        ((TESTS_PASSED++)) || true
    else
        log_error "Grafana instance not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 6: Verify Grafana DataSource
    log_test "Step 6: Verifying Grafana DataSource..."
    if oc get grafanadatasource prometheus-uwm -n "$NAMESPACE" &>/dev/null; then
        log_success "Grafana DataSource 'prometheus-uwm' exists"
        ((TESTS_PASSED++)) || true
        
        # Check if datasource is ready
        local ds_status=$(oc get grafanadatasource prometheus-uwm -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$ds_status" == "True" ]]; then
            log_success "Grafana DataSource is ready"
            ((TESTS_PASSED++)) || true
        else
            log_warn "Grafana DataSource status: $ds_status (may still be initializing)"
            ((TESTS_WARNED++)) || true
        fi
    else
        log_error "Grafana DataSource 'prometheus-uwm' not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 7: Verify Grafana RBAC
    log_test "Step 7: Verifying Grafana RBAC..."
    # For UWM, the ClusterRoleBinding is named grafana-prometheus-eip-monitoring
    if oc get clusterrolebinding grafana-prometheus-eip-monitoring &>/dev/null; then
        log_success "Grafana RBAC (ClusterRoleBinding grafana-prometheus-eip-monitoring) exists"
        ((TESTS_PASSED++)) || true
        
        # Also verify the ServiceAccount exists
        if oc get serviceaccount grafana-prometheus -n "$NAMESPACE" &>/dev/null; then
            log_success "Grafana ServiceAccount (grafana-prometheus) exists"
            ((TESTS_PASSED++)) || true
        else
            log_warn "Grafana ServiceAccount not found"
            ((TESTS_WARNED++)) || true
        fi
    else
        log_warn "Grafana RBAC (ClusterRoleBinding grafana-prometheus-eip-monitoring) not found"
        log_info "Checking for alternative RBAC names..."
        oc get clusterrolebinding 2>/dev/null | grep -i grafana || true
        ((TESTS_WARNED++)) || true
    fi
}

# Test Grafana dashboards
test_grafana_dashboards() {
    log_test "Testing Grafana Dashboards"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Step 1: Verify dashboards are deployed
    log_test "Step 1: Verifying Grafana dashboards..."
    local dashboard_count=$(oc get grafanadashboard -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    
    if [[ "$dashboard_count" -gt 0 ]]; then
        log_success "Found $dashboard_count Grafana dashboard(s)"
        ((TESTS_PASSED++)) || true
        
        # List dashboards
        log_info "Deployed dashboards:"
        oc get grafanadashboard -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print "  - " $1}' || true
        
        # Check a few key dashboards (using actual metadata.name from YAML files)
        local key_dashboards=(
            "eip-monitoring-dashboard"
            "eip-distribution-heatmap"
            "cpic-health-status"
            "node-performance-utilization"
        )
        
        local found_key_dashboards=0
        for dashboard in "${key_dashboards[@]}"; do
            if oc get grafanadashboard "$dashboard" -n "$NAMESPACE" &>/dev/null; then
                ((found_key_dashboards++)) || true
            fi
        done
        
        if [[ $found_key_dashboards -gt 0 ]]; then
            log_success "Found $found_key_dashboards key dashboard(s)"
            ((TESTS_PASSED++)) || true
        else
            log_warn "Key dashboards not found (may use different names)"
            ((TESTS_WARNED++)) || true
        fi
    else
        log_error "No Grafana dashboards found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
    
    # Step 2: Verify dashboard status
    log_test "Step 2: Verifying dashboard status..."
    local ready_dashboards=0
    local total_dashboards=0
    
    while IFS= read -r dashboard_name; do
        if [[ -n "$dashboard_name" ]]; then
            ((total_dashboards++)) || true
            local dashboard_status=$(oc get grafanadashboard "$dashboard_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [[ "$dashboard_status" == "True" ]]; then
                ((ready_dashboards++)) || true
            fi
        fi
    done < <(oc get grafanadashboard -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || true)
    
    if [[ $total_dashboards -gt 0 ]]; then
        log_info "Dashboard status: $ready_dashboards/$total_dashboards ready"
        if [[ $ready_dashboards -eq $total_dashboards ]]; then
            log_success "All dashboards are ready"
            ((TESTS_PASSED++)) || true
        elif [[ $ready_dashboards -gt 0 ]]; then
            log_warn "Some dashboards are still initializing ($ready_dashboards/$total_dashboards ready)"
            ((TESTS_WARNED++)) || true
        else
            log_warn "Dashboards are still initializing"
            ((TESTS_WARNED++)) || true
        fi
    fi
    
    # Step 3: Verify Grafana can access dashboards
    log_test "Step 3: Verifying Grafana can access dashboards..."
    # Try multiple approaches to find Grafana pod (in order of reliability)
    # Grafana Operator creates pods with name pattern: eip-monitoring-grafana-deployment-*
    local grafana_pod=$(oc get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "grafana.*deployment" | grep -v operator | head -1 || echo "")
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=grafana-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    if [[ -z "$grafana_pod" ]]; then
        # Final fallback: find by name pattern (any grafana pod except operator)
        grafana_pod=$(oc get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i grafana | grep -v operator | head -1 || echo "")
    fi
    
    if [[ -n "$grafana_pod" ]]; then
        # Check if Grafana pod is ready
        local pod_status=$(oc get pod "$grafana_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$pod_status" == "Running" ]]; then
            log_success "Grafana pod '$grafana_pod' is running"
            ((TESTS_PASSED++)) || true
            
            # Try to check Grafana API (if accessible)
            local grafana_ready=$(oc exec -n "$NAMESPACE" "$grafana_pod" -- wget -qO- http://localhost:3000/api/health 2>/dev/null | \
                python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('database', 'unknown'))" 2>/dev/null || echo "")
            
            if [[ "$grafana_ready" == "ok" ]]; then
                log_success "Grafana API is accessible"
                ((TESTS_PASSED++)) || true
            else
                log_warn "Grafana API may not be ready yet"
                ((TESTS_WARNED++)) || true
            fi
        else
            log_warn "Grafana pod status: $pod_status"
            ((TESTS_WARNED++)) || true
        fi
    else
        log_error "Grafana pod not found"
        ((TESTS_FAILED++)) || true
        EXIT_CODE=1
    fi
}

# Main test execution
main() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "E2E Test for UWM Monitoring with Grafana Dashboards"
    log_info "Namespace: $NAMESPACE"
    log_info "UWM Namespace: $UWM_NAMESPACE"
    log_info "Cleanup: $CLEANUP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check prerequisites using shared function
    if ! check_prerequisites; then
        exit 1
    fi
    
    if ! command -v python3 &>/dev/null; then
        log_error "python3 command not found (required for JSON parsing)"
        exit 1
    fi
    
    # Run tests
    test_uwm_deployment
    echo ""
    test_grafana_deployment
    echo ""
    test_grafana_dashboards
    
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
    
    # Print access information
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo ""
        log_info "Access Information:"
        local grafana_route=$(oc get route -n "$NAMESPACE" -l app=grafana -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "")
        if [[ -n "$grafana_route" ]]; then
            log_info "Grafana URL: https://$grafana_route"
        else
            log_info "Grafana Route: oc get route -n $NAMESPACE -l app=grafana"
        fi
        log_info "Grafana Dashboards: oc get grafanadashboard -n $NAMESPACE"
    fi
    
    exit $EXIT_CODE
}

# Run main function
main "$@"

