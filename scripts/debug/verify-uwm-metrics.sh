#!/bin/bash
#
# Verify UWM Metrics Collection
# Checks that UWM Prometheus is discovering and scraping eip-monitor metrics
#

set -eo pipefail  # Remove -u to allow unset variables (we check them explicitly)

NAMESPACE="${NAMESPACE:-eip-monitoring}"
UWM_NAMESPACE="openshift-user-workload-monitoring"
EXIT_CODE=0
prom_pod=""  # Initialize prom_pod variable
eip_targets=""
metric_count=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "UWM Metrics Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Check UWM Prometheus pods
log_info "1. Checking UWM Prometheus pods..."
prom_pods=$(oc get pods -n "$UWM_NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l | tr -d ' \n' || echo "0")
prom_pods=${prom_pods:-0}  # Ensure it's a number
if [[ "$prom_pods" -gt 0 ]] && [[ "$prom_pods" =~ ^[0-9]+$ ]]; then
    log_success "Found $prom_pods UWM Prometheus pod(s)"
    prom_pod=$(oc get pods -n "$UWM_NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$prom_pod" ]]; then
        log_info "  Pod: $prom_pod"
        pod_status=$(oc get pod "$prom_pod" -n "$UWM_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$pod_status" == "Running" ]]; then
            log_success "  Status: Running"
        else
            log_warn "  Status: $pod_status"
        fi
    fi
else
    log_error "No UWM Prometheus pods found!"
    log_info "UWM may not be enabled. Check with:"
    log_info "  oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload"
    EXIT_CODE=1
fi
echo ""

# 2. Check ServiceMonitor exists
log_info "2. Checking ServiceMonitor..."
if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
    log_success "ServiceMonitor 'eip-monitor-uwm' exists"
else
    log_error "ServiceMonitor 'eip-monitor-uwm' not found!"
    log_info "Deploy it with:"
    log_info "  oc apply -f k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml"
    EXIT_CODE=1
fi
echo ""

# 3. Check ServiceMonitor in Prometheus config
log_info "3. Checking if ServiceMonitor is discovered by Prometheus..."
if [[ -n "$prom_pod" ]]; then
    # Check Prometheus config for eip-monitor job
    config_check=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- cat /etc/prometheus/config_out/prometheus.env.yaml 2>/dev/null | grep -i "eip-monitor" || echo "")
    if [[ -n "$config_check" ]]; then
        log_success "ServiceMonitor found in Prometheus configuration"
        log_info "  Job configuration found"
    else
        log_warn "ServiceMonitor not found in Prometheus configuration"
        log_info "Prometheus may need to be restarted to discover the ServiceMonitor"
    fi
else
    log_warn "Cannot check Prometheus config - pod not found"
fi
echo ""

# 4. Check Prometheus targets
log_info "4. Checking Prometheus targets..."
if [[ -n "$prom_pod" ]]; then
    log_info "Querying Prometheus targets API..."
    targets_json=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
    
    if [[ -n "$targets_json" ]]; then
        # Find eip-monitor targets
        eip_targets=$(echo "$targets_json" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | {job: .labels.job, health: .health, lastError: .lastError, lastScrape: .lastScrape}' 2>/dev/null || echo "")
        
        if [[ -n "$eip_targets" ]]; then
            log_success "Found eip-monitor targets in Prometheus:"
            echo "$eip_targets" | jq '.'
            echo ""
            
            # Check target health
            unhealthy_count=$(echo "$eip_targets" | jq -r 'select(.health != "up")' 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            if [[ "$unhealthy_count" -gt 0 ]]; then
                log_warn "Some targets are not healthy:"
                echo "$eip_targets" | jq 'select(.health != "up")'
                echo ""
            fi
            
            # Check for errors
            error_targets=$(echo "$eip_targets" | jq -r 'select(.lastError != "")' 2>/dev/null || echo "")
            if [[ -n "$error_targets" ]]; then
                log_error "Targets with errors:"
                echo "$error_targets" | jq '.'
                echo ""
            fi
        else
            log_error "No eip-monitor targets found in Prometheus!"
            log_info "This indicates ServiceMonitor is not being scraped"
            echo ""
            log_info "Available targets:"
            echo "$targets_json" | jq -r '.data.activeTargets[].labels.job' 2>/dev/null | head -10 || echo "  (Unable to parse targets)"
            echo ""
        fi
    else
        log_error "Failed to query Prometheus targets API"
        log_info "Prometheus pod may not be ready or API is not accessible"
    fi
else
    log_warn "Cannot check targets - Prometheus pod not found"
fi
echo ""

# 5. Query for eip metrics
log_info "5. Querying Prometheus for eip metrics..."
if [[ -n "$prom_pod" ]]; then
    # Query for any eip_* metrics using proper PromQL
    metrics_query="{__name__=~\"eip_.*\"}"
    log_info "Querying: $metrics_query"
    
    # Use Prometheus API to query for metrics
    metrics_result=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- wget -qO- "http://localhost:9090/api/v1/query?query=$(echo "$metrics_query" | sed 's/ /%20/g')" 2>/dev/null || echo "")
    
    if [[ -n "$metrics_result" ]]; then
        metric_count=$(echo "$metrics_result" | jq -r '.data.result | length' 2>/dev/null || echo "0")
        
        if [[ "$metric_count" -gt 0 ]]; then
            log_success "Found $metric_count eip metric(s) in Prometheus!"
            echo ""
            log_info "Sample metrics (first 10):"
            echo "$metrics_result" | jq -r '.data.result[0:10][] | "  \(.metric.__name__) = \(.value[1])"' 2>/dev/null || echo "$metrics_result" | jq '.data.result[0:10]' 2>/dev/null
            echo ""
            
            # List all unique metric names
            log_info "All eip metric names:"
            echo "$metrics_result" | jq -r '.data.result[].metric.__name__' 2>/dev/null | sort -u | head -20
            echo ""
        else
            log_error "No eip metrics found in Prometheus!"
            log_info "This indicates metrics are not being scraped or exposed"
            echo ""
            log_info "Checking if eip-monitor service is accessible..."
            # Check if we can reach the metrics endpoint
            service_endpoint=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}:{.spec.ports[?(@.name=="metrics")].port}' 2>/dev/null || echo "")
            if [[ -n "$service_endpoint" ]]; then
                log_info "Service endpoint: $service_endpoint"
                log_info "Try accessing metrics from within cluster:"
                log_info "  oc run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://$service_endpoint/metrics"
            fi
        fi
    else
        log_error "Failed to query Prometheus API"
        log_info "Prometheus may still be initializing. Try again in a few minutes."
    fi
else
    log_warn "Cannot query metrics - Prometheus pod not found"
fi
echo ""

# 6. Check specific important metrics
log_info "6. Checking for specific eip metrics..."
if [[ -n "$prom_pod" ]]; then
    important_metrics=(
        "eip_total"
        "eip_assigned"
        "eip_capacity"
        "eip_last_scrape_timestamp_seconds"
    )
    
    found_metrics=0
    for metric in "${important_metrics[@]}"; do
        metric_result=$(oc exec -n "$UWM_NAMESPACE" "$prom_pod" -- wget -qO- "http://localhost:9090/api/v1/query?query=${metric}" 2>/dev/null || echo "")
        if [[ -n "$metric_result" ]]; then
            metric_exists=$(echo "$metric_result" | jq -r '.data.result | length' 2>/dev/null || echo "0")
            if [[ "$metric_exists" -gt 0 ]]; then
                log_success "  ✓ $metric"
                found_metrics=$((found_metrics + 1))
            else
                log_warn "  ✗ $metric (not found)"
            fi
        fi
    done
    
    if [[ $found_metrics -eq ${#important_metrics[@]} ]]; then
        log_success "All important metrics are present!"
    elif [[ $found_metrics -gt 0 ]]; then
        log_warn "Some metrics are missing ($found_metrics/${#important_metrics[@]} found)"
    else
        log_error "No important metrics found!"
    fi
else
    log_warn "Cannot check specific metrics - Prometheus pod not found"
fi
echo ""

# 7. Check service and endpoints
log_info "7. Checking eip-monitor service and endpoints..."
if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
    log_success "Service 'eip-monitor' exists"
    
    endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || echo "")
    if [[ -n "$endpoints" ]]; then
        log_success "Service has endpoints: $endpoints"
    else
        log_error "Service has no endpoints!"
        log_info "Check if pods are running:"
        log_info "  oc get pods -n $NAMESPACE -l app=eip-monitor"
    fi
    
    # Check service port
    metrics_port=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.ports[?(@.name=="metrics")].port}' 2>/dev/null || echo "")
    if [[ -n "$metrics_port" ]]; then
        log_success "Metrics port configured: $metrics_port"
    else
        log_warn "Metrics port not found in service spec"
    fi
else
    log_error "Service 'eip-monitor' not found!"
fi
echo ""

# 8. Check NetworkPolicy
log_info "8. Checking NetworkPolicy..."
if oc get networkpolicy eip-monitor-uwm -n "$NAMESPACE" &>/dev/null || oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
    log_success "NetworkPolicy exists"
    log_info "NetworkPolicy should allow traffic from $UWM_NAMESPACE namespace"
else
    log_warn "No NetworkPolicy found - UWM Prometheus may be blocked"
    log_info "Apply NetworkPolicy:"
    log_info "  oc apply -f k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml"
fi
echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ -n "$prom_pod" ]] && [[ -n "$eip_targets" ]] && [[ "$metric_count" -gt 0 ]]; then
    log_success "✓ UWM Prometheus is running"
    log_success "✓ ServiceMonitor is discovered"
    log_success "✓ Targets are configured"
    log_success "✓ Metrics are being collected"
    echo ""
    log_info "UWM monitoring is working correctly!"
    log_info ""
    log_info "To query metrics directly from Prometheus:"
    log_info "  oc port-forward -n $UWM_NAMESPACE svc/prometheus-user-workload 9090:9090"
    log_info "  Then visit: http://localhost:9090"
else
    log_error "UWM monitoring has issues!"
    echo ""
    log_info "Troubleshooting steps:"
    log_info "1. Verify namespace is labeled:"
    log_info "   oc get namespace $NAMESPACE -o jsonpath='{.metadata.labels.openshift\.io/user-monitoring}'"
    log_info "   oc label namespace $NAMESPACE openshift.io/user-monitoring=true --overwrite"
    echo ""
    log_info "2. Verify ServiceMonitor exists:"
    log_info "   oc get servicemonitor eip-monitor-uwm -n $NAMESPACE"
    echo ""
    log_info "3. Verify service labels match ServiceMonitor selector:"
    log_info "   oc get service eip-monitor -n $NAMESPACE -o jsonpath='{.metadata.labels}'"
    echo ""
    log_info "4. Restart UWM Prometheus to force ServiceMonitor discovery:"
    log_info "   oc delete pod -n $UWM_NAMESPACE -l app.kubernetes.io/name=prometheus"
    echo ""
    log_info "5. Check Prometheus logs:"
    log_info "   oc logs -n $UWM_NAMESPACE -l app.kubernetes.io/name=prometheus --tail=100"
    echo ""
fi

exit $EXIT_CODE

