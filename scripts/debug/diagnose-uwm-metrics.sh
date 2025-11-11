#!/bin/bash
#
# Diagnose UWM Metrics Collection Issues
# Checks ServiceMonitor discovery, labels, NetworkPolicy, and Prometheus targets
#

set -euo pipefail

NAMESPACE="${NAMESPACE:-eip-monitoring}"

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
log_info "UWM Metrics Collection Diagnostics"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 0. Check namespace label for UWM monitoring
log_info "0. Checking namespace label for UWM monitoring..."
namespace_label=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.openshift\.io/user-monitoring}' 2>/dev/null || echo "")
if [[ "$namespace_label" == "false" ]]; then
    log_error "Namespace has openshift.io/user-monitoring=false - this excludes it from UWM monitoring!"
    log_info "Fix with:"
    log_info "  oc label namespace $NAMESPACE openshift.io/user-monitoring=true --overwrite"
    echo ""
elif [[ -z "$namespace_label" ]] || [[ "$namespace_label" == "true" ]]; then
    log_success "Namespace is properly labeled for UWM monitoring"
else
    log_warn "Namespace label value: $namespace_label (should be 'true' or unset)"
fi
echo ""

# 1. Check ServiceMonitor exists
log_info "1. Checking ServiceMonitor..."
if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
    log_success "ServiceMonitor 'eip-monitor-uwm' exists"
    echo ""
    log_info "ServiceMonitor configuration:"
    oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" -o yaml | grep -A 15 "spec:"
    echo ""
else
    log_error "ServiceMonitor 'eip-monitor-uwm' not found!"
    exit 1
fi

# 2. Check Service labels match ServiceMonitor selector
log_info "2. Checking Service labels..."
if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
    log_success "Service 'eip-monitor' exists"
    echo ""
    log_info "Service labels:"
    oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' | jq '.' 2>/dev/null || oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels}'
    echo ""
    echo ""
    log_info "ServiceMonitor selector expects:"
    echo "  app: eip-monitor"
    echo "  service: eip-monitor"
    echo ""
    
    local service_app=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
    local service_label=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.service}' 2>/dev/null || echo "")
    
    if [[ "$service_app" == "eip-monitor" ]] && [[ "$service_label" == "eip-monitor" ]]; then
        log_success "Service labels match ServiceMonitor selector"
    else
        log_error "Service labels don't match!"
        log_info "Missing labels:"
        [[ "$service_app" != "eip-monitor" ]] && log_warn "  - app: eip-monitor (current: $service_app)"
        [[ "$service_label" != "eip-monitor" ]] && log_warn "  - service: eip-monitor (current: $service_label)"
        echo ""
        log_info "Fix with:"
        log_info "  oc label service eip-monitor -n $NAMESPACE app=eip-monitor service=eip-monitor --overwrite"
    fi
else
    log_error "Service 'eip-monitor' not found!"
fi
echo ""

# 3. Check Pod labels
log_info "3. Checking Pod labels..."
pod_count=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$pod_count" -gt 0 ]]; then
    log_success "Found $pod_count pod(s) with app=eip-monitor"
    echo ""
    log_info "Pod labels (first pod):"
    first_pod=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$first_pod" ]]; then
        oc get pod "$first_pod" -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' | jq '.' 2>/dev/null || oc get pod "$first_pod" -n "$NAMESPACE" -o jsonpath='{.metadata.labels}'
        echo ""
        echo ""
        pod_app=$(oc get pod "$first_pod" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
        pod_service=$(oc get pod "$first_pod" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.service}' 2>/dev/null || echo "")
        
        if [[ "$pod_app" == "eip-monitor" ]] && [[ "$pod_service" == "eip-monitor" ]]; then
            log_success "Pod labels match ServiceMonitor selector"
        else
            log_warn "Pod labels may not match:"
            [[ "$pod_app" != "eip-monitor" ]] && log_warn "  - app: eip-monitor (current: $pod_app)"
            [[ "$pod_service" != "eip-monitor" ]] && log_warn "  - service: eip-monitor (current: $pod_service)"
        fi
    fi
else
    log_error "No pods found with app=eip-monitor label!"
fi
echo ""

# 4. Check Service endpoints
log_info "4. Checking Service endpoints..."
endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || echo "")
if [[ -n "$endpoints" ]]; then
    log_success "Service has endpoints: $endpoints"
else
    log_error "Service has no endpoints!"
    log_info "Check if pods are running and have correct labels"
fi
echo ""

# 5. Check NetworkPolicy
log_info "5. Checking NetworkPolicy..."
if oc get networkpolicy eip-monitor-uwm -n "$NAMESPACE" &>/dev/null || oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
    log_success "NetworkPolicy exists"
    log_info "NetworkPolicy should allow traffic from openshift-user-workload-monitoring namespace"
else
    log_warn "No NetworkPolicy found - UWM Prometheus may be blocked"
    log_info "Apply NetworkPolicy:"
    log_info "  oc apply -f k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml"
fi
echo ""

# 6. Check UWM Prometheus configuration
log_info "6. Checking UWM Prometheus configuration..."
prom_pod=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$prom_pod" ]]; then
    log_success "UWM Prometheus pod found: $prom_pod"
    echo ""
    log_info "Checking Prometheus configuration..."
    config=$(oc exec -n openshift-user-workload-monitoring "$prom_pod" -- cat /etc/prometheus/config_out/prometheus.env.yaml 2>/dev/null | grep -A 5 "eip-monitor" || echo "")
    if [[ -n "$config" ]]; then
        log_success "ServiceMonitor appears in Prometheus config"
        echo "$config"
    else
        log_warn "ServiceMonitor not found in Prometheus configuration"
        log_info "Prometheus may need to be restarted or ServiceMonitor may not be discovered"
    fi
else
    log_error "UWM Prometheus pod not found!"
fi
echo ""

# 7. Check Prometheus targets
log_info "7. Checking Prometheus targets..."
if [[ -n "$prom_pod" ]]; then
    log_info "Querying Prometheus targets API..."
    targets=$(oc exec -n openshift-user-workload-monitoring "$prom_pod" -- wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | {job: .labels.job, health: .health, lastError: .lastError}' 2>/dev/null || echo "")
    if [[ -n "$targets" ]]; then
        log_success "Found eip-monitor targets:"
        echo "$targets" | jq '.'
    else
        log_warn "No eip-monitor targets found in Prometheus"
        log_info "This indicates ServiceMonitor is not being discovered"
    fi
else
    log_warn "Cannot check targets - Prometheus pod not found"
fi
echo ""

# 8. Recommendations
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Recommendations:"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "1. Ensure namespace is labeled for UWM:"
log_info "   oc label namespace $NAMESPACE openshift.io/user-monitoring=true --overwrite"
echo ""
log_info "2. Ensure Service has correct labels:"
log_info "   oc label service eip-monitor -n $NAMESPACE app=eip-monitor service=eip-monitor --overwrite"
echo ""
log_info "3. Ensure Pods have correct labels:"
log_info "   oc label pods -n $NAMESPACE -l app=eip-monitor service=eip-monitor --overwrite"
echo ""
log_info "4. Apply NetworkPolicy if missing:"
log_info "   oc apply -f k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml"
echo ""
log_info "5. Restart UWM Prometheus to force ServiceMonitor discovery:"
log_info "   oc delete pod -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus"
echo ""
log_info "6. Check UWM Prometheus logs:"
log_info "   oc logs -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --tail=100"
echo ""

