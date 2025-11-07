#!/bin/bash
#
# Fix Prometheus ServiceMonitor Discovery
# Restarts Prometheus to force ServiceMonitor discovery
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"
MONITORING_TYPE="${MONITORING_TYPE:-coo}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect monitoring type
detect_monitoring_type() {
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        echo "coo"
        return 0
    fi
    
    local cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    if echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
        echo "uwm"
        return 0
    fi
    
    echo "none"
}

# Get Prometheus pod name
get_prometheus_pod() {
    local monitoring_type="$1"
    local namespace="$2"
    
    if [[ "$monitoring_type" == "coo" ]]; then
        oc get pods -n "$namespace" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
    elif [[ "$monitoring_type" == "uwm" ]]; then
        oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Main function
main() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Fixing Prometheus ServiceMonitor Discovery"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Detect monitoring type
    local detected_type=$(detect_monitoring_type)
    if [[ "$detected_type" != "none" ]]; then
        MONITORING_TYPE="$detected_type"
    fi
    log_info "Detected monitoring type: $MONITORING_TYPE"
    
    # Get Prometheus namespace
    local prom_namespace="$NAMESPACE"
    if [[ "$MONITORING_TYPE" == "uwm" ]]; then
        prom_namespace="openshift-user-workload-monitoring"
    fi
    
    # Get Prometheus pod
    local prom_pod=$(get_prometheus_pod "$MONITORING_TYPE" "$prom_namespace")
    if [[ -z "$prom_pod" ]]; then
        log_error "Prometheus pod not found in namespace '$prom_namespace'"
        exit 1
    fi
    
    log_info "Found Prometheus pod: $prom_pod"
    
    # Check if ServiceMonitor exists
    local sm_name=""
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        sm_name="eip-monitor-coo"
    else
        sm_name="eip-monitor-uwm"
    fi
    
    if ! oc get servicemonitor "$sm_name" -n "$NAMESPACE" &>/dev/null; then
        log_error "ServiceMonitor '$sm_name' not found in namespace '$NAMESPACE'"
        log_info "Please deploy the ServiceMonitor first"
        exit 1
    fi
    
    log_success "ServiceMonitor '$sm_name' exists"
    
    # Check MonitoringStack (for COO)
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        if ! oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
            log_error "MonitoringStack 'eip-monitoring-stack' not found"
            exit 1
        fi
        
        log_info "Checking MonitoringStack resourceSelector..."
        local resource_selector=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.spec.resourceSelector.matchLabels}' 2>/dev/null || echo "{}")
        local app_match=$(echo "$resource_selector" | jq -r '.app' 2>/dev/null || echo "")
        
        if [[ "$app_match" != "eip-monitor" ]]; then
            log_warn "MonitoringStack resourceSelector might not match ServiceMonitor"
            log_info "  Expected: app=eip-monitor"
            log_info "  Found: app=$app_match"
            log_info "  This might be the issue - check MonitoringStack configuration"
        else
            log_success "✓ MonitoringStack resourceSelector matches"
        fi
    fi
    
    # Restart Prometheus
    log_info ""
    log_warn "This will restart Prometheus, causing a brief interruption in metrics collection"
    log_info "Restarting Prometheus pod: $prom_pod"
    
    oc delete pod "$prom_pod" -n "$prom_namespace" || {
        log_error "Failed to delete Prometheus pod"
        exit 1
    }
    
    log_info "Waiting for Prometheus pod to restart..."
    local max_wait=180
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        local new_pod=$(get_prometheus_pod "$MONITORING_TYPE" "$prom_namespace")
        if [[ -n "$new_pod" ]]; then
            local pod_status=$(oc get pod "$new_pod" -n "$prom_namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$pod_status" == "Running" ]]; then
                log_success "✓ Prometheus pod restarted: $new_pod"
                break
            fi
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]]; then
            log_info "Still waiting for Prometheus to restart... (${waited}s)"
        fi
    done
    
    if [[ $waited -ge $max_wait ]]; then
        log_warn "Prometheus pod may not be fully ready yet (waited ${max_wait}s)"
    fi
    
    log_info ""
    log_info "Waiting 60 seconds for Prometheus to initialize and discover ServiceMonitor..."
    sleep 60
    
    log_success "Prometheus restart completed!"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Run the verification script to check if ServiceMonitor is discovered:"
    log_info "     ./scripts/verify-prometheus-metrics.sh"
    log_info "  2. Check Prometheus targets:"
    log_info "     oc port-forward <prometheus-pod> 9090:9090 -n $prom_namespace"
    log_info "     Then visit: http://localhost:9090/targets"
    log_info "  3. Query Prometheus for metrics:"
    log_info "     curl 'http://localhost:9090/api/v1/query?query=eips_configured_total'"
}

# Run main function
main "$@"

