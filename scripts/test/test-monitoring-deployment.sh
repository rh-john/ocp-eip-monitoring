#!/bin/bash
#
# Test Monitoring Deployment
# Comprehensive test script to verify that UWM and/or COO monitoring is installed and operational
# Tests all manifests, Prometheus, ServiceMonitors, scraping, and metrics
#

set -e

# Source common functions (pod finding, prerequisites)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "${PROJECT_ROOT}/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-eip-monitoring}"
UWM_NAMESPACE="openshift-user-workload-monitoring"
EXIT_CODE=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNED=0
TEST_ALL="${TEST_ALL:-false}"
FORCE_TYPES="${FORCE_TYPES:-}"  # Comma-separated list: coo,uwm,all

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; ((TESTS_PASSED++)) || true; }
log_warn() { echo -e "${YELLOW}[⚠]${NC} $1"; ((TESTS_WARNED++)) || true; }
log_error() { echo -e "${RED}[✗]${NC} $1"; ((TESTS_FAILED++)) || true; EXIT_CODE=1; }
log_test() { echo -e "\n${BLUE}[TEST]${NC} $1"; }

# Detect installed monitoring types
detect_monitoring_types() {
    local types=""
    
    # Check for COO - need actual resources, not just operator
    # COO uses monitoring.rhobs API group
    if (oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null) || \
       (oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null) || \
       (oc get prometheusrule.monitoring.rhobs eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null) || \
       (oc get prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null) || \
       (oc get monitoringstack -n "$NAMESPACE" &>/dev/null 2>/dev/null | grep -q .); then
        types="${types}coo "
    fi
    
    # Check for UWM - need actual resources
    # UWM uses monitoring.coreos.com API group
    if (oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null) || \
       (oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null); then
        types="${types}uwm "
    fi
    
    echo "$types" | tr -d ' '
}

# Test COO deployment
test_coo() {
    log_test "Testing COO Monitoring Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 0. Check required CRDs for COO
    log_test "0. Checking required CRDs for COO..."
    local missing_crds=""
    
    # Check COO-specific CRDs (monitoring.rhobs)
    if ! oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
        missing_crds="${missing_crds}monitoringstacks.monitoring.rhobs "
    fi
    if ! oc get crd thanosqueriers.monitoring.rhobs &>/dev/null; then
        missing_crds="${missing_crds}thanosqueriers.monitoring.rhobs "
    fi
    if ! oc get crd alertmanagerconfigs.monitoring.rhobs &>/dev/null; then
        missing_crds="${missing_crds}alertmanagerconfigs.monitoring.rhobs "
    fi
    if ! oc get crd scrapeconfigs.monitoring.rhobs &>/dev/null; then
        missing_crds="${missing_crds}scrapeconfigs.monitoring.rhobs "
    fi
    
    # Check standard Prometheus Operator CRDs (used by COO)
    if ! oc get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        missing_crds="${missing_crds}servicemonitors.monitoring.coreos.com "
    fi
    if ! oc get crd prometheusrules.monitoring.coreos.com &>/dev/null; then
        missing_crds="${missing_crds}prometheusrules.monitoring.coreos.com "
    fi
    
    if [[ -n "$missing_crds" ]]; then
        log_error "Missing required CRDs for COO:"
        for crd in $missing_crds; do
            log_error "  - $crd"
        done
        log_info "Install the Cluster Observability Operator to provide these CRDs"
    else
        log_success "All required CRDs for COO are present"
    fi
    
    # 1. Check COO Operator
    log_test "1. Checking COO Operator..."
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        # Check subscription details
        installed_csv=$(oc get subscription cluster-observability-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
        sub_state=$(oc get subscription cluster-observability-operator -n openshift-operators -o jsonpath='{.status.state}' 2>/dev/null || echo "")
        
        if [[ -z "$installed_csv" ]] || [[ -z "$sub_state" ]]; then
            log_warn "COO Operator subscription exists but may not be properly linked"
            log_warn "  installedCSV: ${installed_csv:-null}"
            log_warn "  state: ${sub_state:-null}"
            
            # Check for orphaned CSV
            csv_name=$(oc get csv -n openshift-operators -l operators.coreos.com/cluster-observability-operator.openshift-operators= -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [[ -n "$csv_name" ]]; then
                csv_owner=$(oc get csv "$csv_name" -n openshift-operators -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "")
                if [[ "$csv_owner" != "Subscription" ]]; then
                    log_error "CSV $csv_name exists but is not owned by a subscription"
                    log_info "This indicates an orphaned CSV. You may need to:"
                    log_info "  1. Delete the orphaned CSV: oc delete csv $csv_name -n openshift-operators"
                    log_info "  2. Recreate the subscription or let it reconcile"
                fi
            fi
        else
            csv_phase=$(oc get csv -n openshift-operators -l operators.coreos.com/cluster-observability-operator.openshift-operators= -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
            if [[ "$csv_phase" == "Succeeded" ]]; then
                log_success "COO Operator is installed and ready"
                log_info "  Subscription state: $sub_state"
                log_info "  Installed CSV: $installed_csv"
            else
                log_warn "COO Operator CSV phase: $csv_phase"
                log_info "  Subscription state: $sub_state"
                log_info "  Installed CSV: $installed_csv"
            fi
        fi
    else
        log_error "COO Operator subscription not found"
    fi
    
    # 2. Check MonitoringStack
    log_test "2. Checking MonitoringStack..."
    if oc get monitoringstack -n "$NAMESPACE" &>/dev/null; then
        stack_name=$(oc get monitoringstack -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$stack_name" ]]; then
            log_success "MonitoringStack '$stack_name' exists"
            
            # Get all status conditions
            stack_conditions=$(oc get monitoringstack "$stack_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[*]}' 2>/dev/null || echo "")
            if [[ -n "$stack_conditions" ]]; then
                # Parse and display conditions
                ready_status=$(oc get monitoringstack "$stack_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
                ready_reason=$(oc get monitoringstack "$stack_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
                ready_message=$(oc get monitoringstack "$stack_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
                
                if [[ "$ready_status" == "True" ]]; then
                    log_success "MonitoringStack is Ready"
                elif [[ -n "$ready_status" ]]; then
                    log_warn "MonitoringStack Ready status: $ready_status"
                    if [[ -n "$ready_reason" ]]; then
                        log_info "  Reason: $ready_reason"
                    fi
                    if [[ -n "$ready_message" ]]; then
                        log_info "  Message: $ready_message"
                    fi
                else
                    # Show all conditions if Ready not found
                    all_conditions=$(oc get monitoringstack "$stack_name" -n "$NAMESPACE" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason} {.message}{"\n"}{end}' 2>/dev/null || echo "")
                    if [[ -n "$all_conditions" ]]; then
                        log_info "MonitoringStack status conditions:"
                        echo "$all_conditions" | sed 's/^/  /'
                    else
                        log_warn "MonitoringStack exists but has no status conditions yet (may still be initializing)"
                    fi
                fi
            else
                log_warn "MonitoringStack exists but has no status field yet (may still be initializing)"
            fi
        fi
    else
        log_error "MonitoringStack not found in namespace $NAMESPACE"
    fi
    
    # 3. Check Prometheus pods
    log_test "3. Checking COO Prometheus pods..."
    prom_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    if [[ "$prom_pods" -gt 0 ]]; then
        log_success "Found $prom_pods COO Prometheus pod(s)"
        # Use common function to find Prometheus pod (prefer COO labels for COO deployments)
        prom_pod=$(find_prometheus_pod "$NAMESPACE" "true")
        if [[ -n "$prom_pod" ]]; then
            pod_status=$(oc get pod "$prom_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$pod_status" == "Running" ]]; then
                log_success "Prometheus pod '$prom_pod' is Running"
            else
                log_error "Prometheus pod '$prom_pod' status: $pod_status"
            fi
        fi
    else
        log_error "No COO Prometheus pods found"
    fi
    
    # 4. Check Alertmanager pods
    log_test "4. Checking COO Alertmanager pods..."
    am_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    if [[ "$am_pods" -gt 0 ]]; then
        log_success "Found $am_pods COO Alertmanager pod(s)"
    else
        log_warn "No COO Alertmanager pods found (may be optional)"
    fi
    
    # 5. Check ServiceMonitor
    log_test "5. Checking ServiceMonitor..."
    # COO uses monitoring.rhobs API group, not monitoring.coreos.com
    if oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
       oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
        log_success "ServiceMonitor 'eip-monitor-coo' exists"
        # Check labels
        sm_labels=$(oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || \
                    oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "")
        if echo "$sm_labels" | grep -q "app.*eip-monitor"; then
            log_success "ServiceMonitor has correct labels"
        else
            log_warn "ServiceMonitor labels may be incorrect"
        fi
    else
        log_error "ServiceMonitor 'eip-monitor-coo' not found"
    fi
    
    # 6. Check PrometheusRule
    log_test "6. Checking PrometheusRule..."
    # COO uses monitoring.rhobs API group, not monitoring.coreos.com
    if oc get prometheusrule.monitoring.rhobs eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null || \
       oc get prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null; then
        log_success "PrometheusRule 'eip-monitor-alerts-coo' exists"
    else
        log_error "PrometheusRule 'eip-monitor-alerts-coo' not found"
    fi
    
    # 7. Check NetworkPolicy
    log_test "7. Checking NetworkPolicy..."
    # Always use combined NetworkPolicy (supports both COO and UWM)
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        log_success "Combined NetworkPolicy 'eip-monitor-combined' exists (supports both COO and UWM)"
    else
        log_error "Combined NetworkPolicy 'eip-monitor-combined' not found"
        log_info "The combined NetworkPolicy should always be used (works for both COO and UWM)"
    fi
    
    # 8. Check ThanosQuerier
    log_test "8. Checking ThanosQuerier..."
    tq_count=$(oc get thanosquerier -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    if [[ "$tq_count" -gt 0 ]]; then
        log_success "ThanosQuerier exists"
        # COO uses app.kubernetes.io/managed-by=observability-operator label for ThanosQuerier pods
        # Also check for app.kubernetes.io/part-of=ThanosQuerier
        tq_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
        if [[ "$tq_pods" -gt 0 ]]; then
            log_success "Found $tq_pods ThanosQuerier pod(s)"
            # Check pod status
            tq_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            if [[ -n "$tq_pod" ]]; then
                pod_status=$(oc get pod "$tq_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [[ "$pod_status" == "Running" ]]; then
                    log_success "ThanosQuerier pod '$tq_pod' is Running"
                else
                    log_warn "ThanosQuerier pod '$tq_pod' status: $pod_status"
                fi
            fi
        else
            log_warn "ThanosQuerier pods not found (may still be initializing)"
        fi
    else
        log_warn "ThanosQuerier not found (may be optional)"
    fi
    
    # 9. Check AlertmanagerConfig
    log_test "9. Checking AlertmanagerConfig..."
    # COO uses monitoring.rhobs API group for AlertmanagerConfig
    amc_count=$(oc get alertmanagerconfig.monitoring.rhobs -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    if [[ "$amc_count" -gt 0 ]]; then
        log_success "AlertmanagerConfig exists"
    else
        # Also check standard API group as fallback
        amc_count_std=$(oc get alertmanagerconfig -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
        if [[ "$amc_count_std" -gt 0 ]]; then
            log_success "AlertmanagerConfig exists (standard API group)"
        else
            log_warn "AlertmanagerConfig not found (may be optional)"
            log_info "AlertmanagerConfig is optional - alerts will still work without it"
        fi
    fi
    
    # 10. Check ServiceMonitor discovery in Prometheus
    # This is a critical check - ServiceMonitor must be discovered for scraping to work
    # Known issue: COO Prometheus sometimes doesn't discover ServiceMonitors immediately
    # See docs/COO_SERVICEMONITOR_DISCOVERY_ISSUE.md for details
    log_test "10. Checking ServiceMonitor discovery in Prometheus..."
    if [[ -n "$prom_pod" ]]; then
        # Check 1: ServiceMonitor in Prometheus configuration file
        config_check=$(oc exec -n "$NAMESPACE" "$prom_pod" -- cat /etc/prometheus/config_out/prometheus.env.yaml 2>/dev/null | grep -i "eip-monitor" || echo "")
        if [[ -n "$config_check" ]]; then
            log_success "ServiceMonitor found in Prometheus configuration"
            
            # Check 2: Verify MonitoringStack resourceSelector matches ServiceMonitor labels
            # This is critical - if resourceSelector doesn't match, ServiceMonitor won't be discovered
            if oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
                local resource_selector=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.spec.resourceSelector.matchLabels}' 2>/dev/null || echo "{}")
                local app_match=$(echo "$resource_selector" | jq -r '.app' 2>/dev/null || echo "")
                
                if [[ "$app_match" == "eip-monitor" ]]; then
                    log_success "MonitoringStack resourceSelector matches ServiceMonitor labels (app=eip-monitor)"
                else
                    log_warn "MonitoringStack resourceSelector may not match ServiceMonitor"
                    log_info "  Expected: app=eip-monitor"
                    log_info "  Found: app=$app_match"
                    log_info "  This can prevent ServiceMonitor discovery"
                    log_info "  Fix: Update MonitoringStack resourceSelector to match ServiceMonitor labels"
                fi
            fi
            
            # Check 3: Verify ServiceMonitor labels match what Prometheus expects
            # Try COO API version first (monitoring.rhobs/v1), then fallback to standard
            local sm_app=""
            if oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
                # Try COO API version first
                sm_app=$(oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
            fi
            # Fallback to standard API if needed
            if [[ -z "$sm_app" ]]; then
                sm_app=$(oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
            fi
            
            if [[ "$sm_app" == "eip-monitor" ]]; then
                log_success "ServiceMonitor has correct labels (app=eip-monitor)"
            else
                # Only warn if we actually got a value (empty means we couldn't check)
                if [[ -n "$sm_app" ]]; then
                    log_warn "ServiceMonitor labels may not match Prometheus selector"
                    log_info "  ServiceMonitor label 'app': $sm_app"
                    log_info "  Prometheus expects: app=eip-monitor"
                else
                    log_info "Could not verify ServiceMonitor labels (checking targets instead)"
                fi
            fi
            
            # Check 4: Verify targets exist (more reliable than parsing scrape configs)
            # If targets exist and are healthy, ServiceMonitor discovery is working
            local targets_json=$(oc exec -n "$NAMESPACE" "$prom_pod" -- curl -s http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
            if [[ -n "$targets_json" ]]; then
                local eip_targets=$(echo "$targets_json" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | .health' 2>/dev/null | head -1 || echo "")
                if [[ "$eip_targets" == "up" ]]; then
                    log_success "eip-monitor scrape targets exist and are healthy (ServiceMonitor discovery confirmed)"
                elif [[ -n "$eip_targets" ]]; then
                    log_info "eip-monitor targets exist but health is: $eip_targets (may still be initializing)"
                else
                    log_warn "No eip-monitor targets found yet (ServiceMonitor may not be fully reconciled)"
                    log_info "This is normal if Prometheus was just deployed - targets appear within 30-60 seconds"
                fi
            else
                log_info "Could not query Prometheus targets API (checking config file instead)"
                # Fallback: check scrape configs in config file
                local prom_config=$(oc exec -n "$NAMESPACE" "$prom_pod" -- curl -s "http://localhost:9090/api/v1/status/config" 2>/dev/null | jq -r '.data.yaml' 2>/dev/null || echo "")
                if [[ -n "$prom_config" ]]; then
                    # COO creates jobs with pattern: serviceMonitor/namespace/name/0
                    local eip_jobs=$(echo "$prom_config" | grep -E "^\s+- job_name:" | grep -iE "eip|serviceMonitor.*eip" || echo "")
                    if [[ -n "$eip_jobs" ]]; then
                        log_success "eip-monitor scrape job found in Prometheus config"
                    else
                        log_info "ServiceMonitor in config but scrape job not yet visible (targets check preferred)"
                    fi
                fi
            fi
        else
            log_error "ServiceMonitor not found in Prometheus configuration"
            log_info "This means Prometheus hasn't discovered the ServiceMonitor yet"
            log_info ""
            log_info "Known issue: COO Prometheus sometimes doesn't discover ServiceMonitors immediately"
            log_info "See docs/COO_SERVICEMONITOR_DISCOVERY_ISSUE.md for details"
            log_info ""
            log_info "Possible causes:"
            log_info "  1. MonitoringStack resourceSelector doesn't match ServiceMonitor labels"
            log_info "  2. Prometheus was started before ServiceMonitor was created"
            log_info "  3. COO operator hasn't reconciled yet"
            log_info ""
            log_info "Troubleshooting:"
            log_info "  1. Check MonitoringStack resourceSelector:"
            log_info "     oc get monitoringstack eip-monitoring-stack -n $NAMESPACE -o jsonpath='{.spec.resourceSelector}'"
            log_info "  2. Check ServiceMonitor labels:"
            log_info "     oc get servicemonitor eip-monitor-coo -n $NAMESPACE -o jsonpath='{.metadata.labels}'"
            log_info "  3. Restart Prometheus to force discovery:"
            log_info "     ./scripts/debug/fix-prometheus-discovery.sh"
            log_info "  4. Check Prometheus logs:"
            log_info "     oc logs $prom_pod -n $NAMESPACE --tail=100 | grep -i servicemonitor"
        fi
    else
        log_warn "Cannot check Prometheus config - pod not found"
    fi
    
    # 11. Check Prometheus targets
    # NOTE: /api/v1/targets is Prometheus-specific - ThanosQuerier doesn't expose this endpoint
    # We must query Prometheus directly for targets, not ThanosQuerier
    # This verifies that ServiceMonitor discovery resulted in actual scrape targets
    # Following pattern from verify-prometheus-metrics.sh: use oc exec with curl/wget
    log_test "11. Checking Prometheus targets..."
    
    local targets_json=""
    if [[ -n "$prom_pod" ]]; then
        # Use oc exec with curl (consistent with verify-prometheus-metrics.sh pattern)
        targets_json=$(oc exec -n "$NAMESPACE" "$prom_pod" -- curl -s http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
        if [[ -z "$targets_json" ]]; then
            log_warn "Pod exec query failed. Checking pod status..."
            local pod_status=$(oc get pod "$prom_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            log_info "  Prometheus pod status: $pod_status"
        fi
    fi
    
    if [[ -n "$targets_json" ]]; then
        eip_targets=$(echo "$targets_json" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | {job: .labels.job, health: .health, lastError: .lastError}' 2>/dev/null || echo "")
        if [[ -n "$eip_targets" ]]; then
            health=$(echo "$eip_targets" | jq -r '.health' 2>/dev/null | head -1)
            if [[ "$health" == "up" ]]; then
                log_success "eip-monitor target is healthy (ServiceMonitor discovery working)"
            else
                log_error "eip-monitor target health: $health"
                error_msg=$(echo "$eip_targets" | jq -r '.lastError' 2>/dev/null | head -1)
                if [[ -n "$error_msg" ]] && [[ "$error_msg" != "null" ]]; then
                    log_info "  Error: $error_msg"
                fi
            fi
        else
            log_error "No eip-monitor targets found in Prometheus"
            log_info "This indicates ServiceMonitor discovery failed or targets not created yet"
            log_info "Even if ServiceMonitor is in config, targets may not exist if:"
            log_info "  1. Service has no endpoints"
            log_info "  2. Prometheus hasn't evaluated the ServiceMonitor yet"
            log_info "  3. ServiceMonitor selector doesn't match service labels"
            log_info ""
            log_info "Check service endpoints:"
            log_info "  oc get endpoints eip-monitor -n $NAMESPACE"
            log_info "Check service labels match ServiceMonitor selector:"
            log_info "  oc get service eip-monitor -n $NAMESPACE -o jsonpath='{.metadata.labels}'"
        fi
    else
        if [[ -z "$prom_pod" ]]; then
            log_warn "Cannot check targets - Prometheus pod not found"
        else
            log_error "Failed to query Prometheus targets API"
            log_info "Troubleshooting:"
            log_info "  1. Check Prometheus pod: oc get pod $prom_pod -n $NAMESPACE"
            log_info "  2. Check pod logs: oc logs $prom_pod -n $NAMESPACE --tail=50"
            log_info "  3. Try direct query: oc exec -n $NAMESPACE $prom_pod -- wget -qO- http://localhost:9090/api/v1/targets"
        fi
    fi
    
    # 12. Check metrics (for COO, use ThanosQuerier - aggregates multiple Prometheus replicas)
    # NOTE: For metrics queries, use ThanosQuerier when available (better for HA setups)
    # ThanosQuerier aggregates and deduplicates data from all Prometheus instances
    # 
    # API Compatibility:
    # - ThanosQuerier implements Prometheus HTTP v1 API for query endpoints
    # - /api/v1/query endpoint is COMPATIBLE between ThanosQuerier and Prometheus
    # - Same request/response format, same PromQL syntax
    # - Only difference: port (10902 for ThanosQuerier, 9090 for Prometheus)
    # - Fallback works seamlessly because API is identical
    # 
    # Endpoints NOT available in ThanosQuerier:
    # - /api/v1/targets (Prometheus-specific, shows scrape targets)
    # - Other Prometheus-specific endpoints
    # 
    # Following pattern from verify-prometheus-metrics.sh: use oc exec with curl/wget
    log_test "12. Checking metrics..."
    
    # For COO, prefer ThanosQuerier pod for metrics queries (consistent with existing scripts)
    # Use common function to find query pod (prefers ThanosQuerier for COO)
    local query_result=$(find_query_pod "$NAMESPACE" "true")
    local query_pod=""
    local query_port="9090"
    local query_url=""
    
    if [[ -n "$query_result" ]]; then
        query_pod=$(echo "$query_result" | cut -d'|' -f1)
        query_port=$(echo "$query_result" | cut -d'|' -f2)
        if [[ "$query_port" == "10902" ]]; then
            log_info "Using ThanosQuerier pod for metrics: $query_pod (port 10902)"
        else
            log_info "Using Prometheus pod for metrics: $query_pod (port 9090)"
        fi
    fi
    
    if [[ -n "$query_pod" ]]; then
        # URL encode the query (following verify-prometheus-metrics.sh pattern)
        local encoded_query=$(echo "count({__name__=~\"eip_.*\"})" | jq -sRr @uri)
        query_url="http://localhost:${query_port}/api/v1/query?query=${encoded_query}"
        
        # Use oc exec with curl (consistent with verify-prometheus-metrics.sh)
        metrics_result=$(oc exec -n "$NAMESPACE" "$query_pod" -- curl -s "$query_url" 2>/dev/null || echo "")
        
        if [[ -n "$metrics_result" ]]; then
            # Check if response is valid JSON
            if echo "$metrics_result" | jq . >/dev/null 2>&1; then
                local status=$(echo "$metrics_result" | jq -r '.status' 2>/dev/null || echo "error")
                if [[ "$status" == "success" ]]; then
                    metric_count=$(echo "$metrics_result" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "0")
                    if [[ "$metric_count" != "0" ]] && [[ -n "$metric_count" ]] && [[ "$metric_count" != "null" ]]; then
                        log_success "Found $metric_count eip metric(s)"
                    else
                        log_error "No eip metrics found"
                    fi
                else
                    local error_msg=$(echo "$metrics_result" | jq -r '.error' 2>/dev/null || echo "Unknown error")
                    log_error "Query failed: $error_msg"
                fi
            else
                log_error "Invalid JSON response from metrics API"
                log_info "Response preview: $(echo "$metrics_result" | head -c 200)"
            fi
        else
            log_error "Failed to query metrics API"
            log_info "Troubleshooting:"
            log_info "  1. Check pod status: oc get pod $query_pod -n $NAMESPACE"
            log_info "  2. Check pod logs: oc logs $query_pod -n $NAMESPACE --tail=50"
            log_info "  3. Try direct query: oc exec -n $NAMESPACE $query_pod -- curl -s $query_url"
        fi
    else
        log_warn "Cannot check metrics - neither ThanosQuerier nor Prometheus pod found"
    fi
    
    # 13. Check service and endpoints
    log_test "13. Checking eip-monitor service and endpoints..."
    if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
        log_success "Service 'eip-monitor' exists"
        endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
        if [[ -n "$endpoints" ]]; then
            log_success "Service has endpoints: $endpoints"
        else
            log_error "Service has no endpoints"
        fi
    else
        log_error "Service 'eip-monitor' not found"
    fi
    
    echo ""
}

# Test UWM deployment
test_uwm() {
    log_test "Testing UWM Monitoring Deployment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # 0. Check required CRDs for UWM
    log_test "0. Checking required CRDs for UWM..."
    local missing_crds=""
    
    # UWM uses standard Prometheus Operator CRDs (monitoring.coreos.com)
    if ! oc get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        missing_crds="${missing_crds}servicemonitors.monitoring.coreos.com "
    fi
    if ! oc get crd prometheusrules.monitoring.coreos.com &>/dev/null; then
        missing_crds="${missing_crds}prometheusrules.monitoring.coreos.com "
    fi
    if ! oc get crd alertmanagerconfigs.monitoring.coreos.com &>/dev/null; then
        missing_crds="${missing_crds}alertmanagerconfigs.monitoring.coreos.com "
    fi
    
    if [[ -n "$missing_crds" ]]; then
        log_error "Missing required CRDs for UWM:"
        for crd in $missing_crds; do
            log_error "  - $crd"
        done
        log_info "These CRDs are provided by the Prometheus Operator (part of OpenShift)"
        log_info "Ensure User Workload Monitoring is enabled in cluster-monitoring-config"
    else
        log_success "All required CRDs for UWM are present"
    fi
    
    # 1. Check UWM is enabled
    log_test "1. Checking UWM is enabled..."
    cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    if echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
        log_success "User Workload Monitoring is enabled"
    else
        log_error "User Workload Monitoring is not enabled"
    fi
    
    # 2. Check namespace labels
    log_test "2. Checking namespace labels..."
    namespace_label=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.openshift\.io/user-monitoring}' 2>/dev/null || echo "")
    cluster_monitoring_label=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null || echo "")
    
    if [[ "$cluster_monitoring_label" == "true" ]]; then
        log_error "Namespace has openshift.io/cluster-monitoring=true (excludes from UWM)"
    else
        log_success "Namespace does not have cluster-monitoring=true"
    fi
    
    if [[ "$namespace_label" == "true" ]] || [[ -z "$namespace_label" ]]; then
        log_success "Namespace is properly labeled for UWM"
    elif [[ "$namespace_label" == "false" ]]; then
        log_error "Namespace has openshift.io/user-monitoring=false"
    else
        log_warn "Namespace label value: $namespace_label"
    fi
    
    # 3. Check UWM Prometheus pods
    log_test "3. Checking UWM Prometheus pods..."
    prom_pods=$(oc get pods -n "$UWM_NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
    if [[ "$prom_pods" -gt 0 ]]; then
        log_success "Found $prom_pods UWM Prometheus pod(s)"
        prom_pod=$(oc get pods -n "$UWM_NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$prom_pod" ]]; then
            pod_status=$(oc get pod "$prom_pod" -n "$UWM_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$pod_status" == "Running" ]]; then
                log_success "Prometheus pod '$prom_pod' is Running"
            else
                log_error "Prometheus pod '$prom_pod' status: $pod_status"
            fi
        fi
    else
        log_error "No UWM Prometheus pods found"
    fi
    
    # 4. Check ServiceMonitor
    log_test "4. Checking ServiceMonitor..."
    if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
        log_success "ServiceMonitor 'eip-monitor-uwm' exists"
        # Check for required label
        sm_labels=$(oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" -o jsonpath='{.metadata.labels.openshift\.io/user-monitoring}' 2>/dev/null || echo "")
        if [[ "$sm_labels" == "true" ]] || [[ -z "$sm_labels" ]]; then
            log_success "ServiceMonitor has correct labels"
        else
            log_warn "ServiceMonitor may be missing openshift.io/user-monitoring label"
        fi
    else
        log_error "ServiceMonitor 'eip-monitor-uwm' not found"
    fi
    
    # 5. Check PrometheusRule
    log_test "5. Checking PrometheusRule..."
    if oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null; then
        log_success "PrometheusRule 'eip-monitor-alerts-uwm' exists"
    else
        log_error "PrometheusRule 'eip-monitor-alerts-uwm' not found"
    fi
    
    # 6. Check NetworkPolicy
    log_test "6. Checking NetworkPolicy..."
    # Always use combined NetworkPolicy (supports both COO and UWM)
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        log_success "Combined NetworkPolicy 'eip-monitor-combined' exists (supports both COO and UWM)"
    else
        log_error "Combined NetworkPolicy 'eip-monitor-combined' not found"
        log_info "The combined NetworkPolicy should always be used (works for both COO and UWM)"
    fi
    
    # 7. Check ServiceMonitor discovery in Prometheus
    log_test "7. Checking ServiceMonitor discovery in Prometheus..."
    if [[ -n "$prom_pod" ]]; then
        config_check=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- cat /etc/prometheus/config_out/prometheus.env.yaml 2>/dev/null | grep -i "eip-monitor" || echo "")
        if [[ -n "$config_check" ]]; then
            log_success "ServiceMonitor discovered by Prometheus"
        else
            log_error "ServiceMonitor not found in Prometheus configuration"
        fi
    else
        log_warn "Cannot check Prometheus config - pod not found"
    fi
    
    # 8. Check Prometheus targets
    log_test "8. Checking Prometheus targets..."
    if [[ -n "$prom_pod" ]]; then
        targets_json=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
        if [[ -n "$targets_json" ]]; then
            eip_targets=$(echo "$targets_json" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | {job: .labels.job, health: .health, lastError: .lastError}' 2>/dev/null || echo "")
            if [[ -n "$eip_targets" ]]; then
                health=$(echo "$eip_targets" | jq -r '.health' 2>/dev/null | head -1)
                if [[ "$health" == "up" ]]; then
                    log_success "eip-monitor target is healthy"
                else
                    log_error "eip-monitor target health: $health"
                fi
            else
                log_error "No eip-monitor targets found in Prometheus"
            fi
        else
            log_error "Failed to query Prometheus targets API"
        fi
    else
        log_warn "Cannot check targets - Prometheus pod not found"
    fi
    
    # 9. Check metrics in Prometheus
    log_test "9. Checking metrics in Prometheus..."
    if [[ -n "$prom_pod" ]]; then
        metrics_result=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- wget -qO- "http://localhost:9090/api/v1/query?query={__name__=~\"eip_.*\"}" 2>/dev/null || echo "")
        if [[ -n "$metrics_result" ]]; then
            metric_count=$(echo "$metrics_result" | jq -r '.data.result | length' 2>/dev/null || echo "0")
            if [[ "$metric_count" -gt 0 ]]; then
                log_success "Found $metric_count eip metric(s) in Prometheus"
            else
                log_error "No eip metrics found in Prometheus"
            fi
        else
            log_error "Failed to query Prometheus for metrics"
        fi
    else
        log_warn "Cannot check metrics - Prometheus pod not found"
    fi
    
    # 10. Check service and endpoints
    log_test "10. Checking eip-monitor service and endpoints..."
    if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
        log_success "Service 'eip-monitor' exists"
        endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
        if [[ -n "$endpoints" ]]; then
            log_success "Service has endpoints: $endpoints"
        else
            log_error "Service has no endpoints"
        fi
    else
        log_error "Service 'eip-monitor' not found"
    fi
    
    echo ""
}

# Show usage
show_usage() {
    cat << EOF
Test Monitoring Deployment

Usage: $0 [options]

Options:
  -n, --namespace NS        Kubernetes namespace (default: eip-monitoring)
  --monitoring-type TYPE    Force test specific type: coo, uwm, or all
  --all                     Test all installed monitoring types (same as --monitoring-type all)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
  FORCE_TYPES               Comma-separated list of types to test: coo,uwm,all

Examples:
  $0                                    # Auto-detect and test installed types
  $0 --monitoring-type coo             # Test COO only
  $0 --monitoring-type uwm             # Test UWM only
  $0 --monitoring-type all             # Test both COO and UWM
  $0 --all                              # Test all installed types
  $0 -n my-namespace --monitoring-type coo

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                if [[ $# -lt 2 ]]; then
                    log_error "Option $1 requires a value"
                    show_usage
                    exit 1
                fi
                NAMESPACE="$2"
                shift 2
                ;;
            --monitoring-type)
                if [[ $# -lt 2 ]]; then
                    log_error "Option $1 requires a value (coo, uwm, or all)"
                    show_usage
                    exit 1
                fi
                if [[ "$2" == "all" ]]; then
                    FORCE_TYPES="coo,uwm"
                else
                    FORCE_TYPES="$2"
                fi
                shift 2
                ;;
            --all)
                FORCE_TYPES="coo,uwm"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    parse_args "$@"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Monitoring Deployment Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check prerequisites
    if ! command -v oc &>/dev/null; then
        log_error "oc command not found"
        exit 1
    fi
    
    if ! command -v jq &>/dev/null; then
        log_error "jq command not found"
        exit 1
    fi
    
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    log_info "Namespace: $NAMESPACE"
    log_info "Connected as: $(oc whoami)"
    echo ""
    
    # Detect monitoring types or use forced types
    local types=""
    
    if [[ -n "$FORCE_TYPES" ]]; then
        # User specified types to test
        types="$FORCE_TYPES"
        log_info "Testing specified monitoring types: $types"
        echo ""
        
        # Convert comma-separated to space-separated
        types=$(echo "$types" | tr ',' ' ')
    else
        # Auto-detect
        types=$(detect_monitoring_types)
        
        if [[ -z "$types" ]]; then
            log_warn "No complete monitoring infrastructure detected"
            log_info "Checking for orphaned resources..."
            echo ""
            
            # Check for orphaned COO resources
            local has_coo_resources=false
            if oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
               oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
                has_coo_resources=true
                types="coo"
            fi
            if oc get prometheusrule.monitoring.rhobs eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null || \
               oc get prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null; then
                has_coo_resources=true
                [[ "$types" != *"coo"* ]] && types="${types}coo"
            fi
            local stack_output=$(oc get monitoringstack -n "$NAMESPACE" 2>&1)
            if echo "$stack_output" | grep -qv "No resources found" && [[ -n "$stack_output" ]]; then
                has_coo_resources=true
                [[ "$types" != *"coo"* ]] && types="${types}coo"
            fi
            
            # Check for orphaned UWM resources
            local has_uwm_resources=false
            if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
                has_uwm_resources=true
                types="${types}uwm"
            fi
            if oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null; then
                has_uwm_resources=true
                [[ "$types" != *"uwm"* ]] && types="${types}uwm"
            fi
            
            if [[ -z "$types" ]]; then
                log_info "No monitoring resources found in namespace $NAMESPACE"
                log_info "Deploy monitoring with: ./scripts/deploy-monitoring.sh --monitoring-type <coo|uwm>"
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Test Summary"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "No tests run - no monitoring infrastructure detected"
                exit 0
            else
                log_warn "Found partial/orphaned resources for: $types"
                log_info "Running tests anyway to diagnose issues..."
                echo ""
            fi
        else
            log_info "Detected monitoring types: $types"
            echo ""
        fi
    fi
    
    # Test each type
    if [[ "$types" == *"coo"* ]]; then
        test_coo
    fi
    
    if [[ "$types" == *"uwm"* ]]; then
        test_uwm
    fi
    
    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Test Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_success "Tests passed: $TESTS_PASSED"
    if [[ $TESTS_WARNED -gt 0 ]]; then
        log_warn "Tests warned: $TESTS_WARNED"
    fi
    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_error "Tests failed: $TESTS_FAILED"
    fi
    echo ""
    
    if [[ $EXIT_CODE -eq 0 ]]; then
        log_success "All critical tests passed!"
    else
        log_error "Some tests failed - review output above"
    fi
    
    exit $EXIT_CODE
}

main "$@"

