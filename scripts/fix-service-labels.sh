#!/bin/bash
#
# Fix Service Labels for Prometheus Discovery
# Ensures service labels match ServiceMonitor selector requirements
#

set -euo pipefail

NAMESPACE="${NAMESPACE:-eip-monitoring}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'  # Light blue (cyan)
NC='\033[0m' # No Color

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

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Fixing Service Labels for Prometheus Discovery"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if service exists
if ! oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
    log_error "Service 'eip-monitor' not found in namespace '$NAMESPACE'"
    log_info "Please deploy the service first using: oc apply -f k8s/deployment/k8s-manifests.yaml"
    exit 1
fi

# Get current service labels
current_app_label=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
current_service_label=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.service}' 2>/dev/null || echo "")
current_selector=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.selector.app}' 2>/dev/null || echo "")

log_info "Current service labels:"
log_info "  app: ${current_app_label:-<not set>}"
log_info "  service: ${current_service_label:-<not set>}"
log_info "Current service selector:"
log_info "  app: ${current_selector:-<not set>}"

# Check if labels need fixing
needs_fix=false

if [[ "$current_app_label" != "eip-monitor" ]]; then
    log_warn "Service label 'app' is '$current_app_label', expected 'eip-monitor'"
    needs_fix=true
fi

if [[ "$current_service_label" != "eip-monitor" ]]; then
    log_warn "Service label 'service' is '$current_service_label', expected 'eip-monitor'"
    needs_fix=true
fi

if [[ "$current_selector" != "eip-monitor" ]]; then
    log_warn "Service selector 'app' is '$current_selector', expected 'eip-monitor'"
    needs_fix=true
fi

if [[ "$needs_fix" == "false" ]]; then
    log_success "Service labels and selector are correct!"
    exit 0
fi

log_info "Fixing service labels and selector..."

# Patch the service to have correct labels and selector
# Supports both COO and UWM monitoring simultaneously
oc patch service eip-monitor -n "$NAMESPACE" --type='merge' -p '{
  "metadata": {
    "labels": {
      "app": "eip-monitor",
      "service": "eip-monitor",
      "monitoring": "true",
      "monitoring-coo": "true",
      "monitoring-uwm": "true"
    }
  },
  "spec": {
    "selector": {
      "app": "eip-monitor"
    }
  }
}' || {
    log_error "Failed to patch service"
    exit 1
}

log_success "Service patched successfully!"

# Verify the fix
log_info "Verifying service labels..."
new_app_label=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
new_service_label=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.service}' 2>/dev/null || echo "")
new_selector=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.selector.app}' 2>/dev/null || echo "")

log_info "Updated service labels:"
log_info "  app: ${new_app_label:-<not set>}"
log_info "  service: ${new_service_label:-<not set>}"
log_info "Updated service selector:"
log_info "  app: ${new_selector:-<not set>}"

# Check endpoints
log_info "Checking service endpoints..."
endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || echo "")

if [[ -z "$endpoints" ]]; then
    log_warn "Service still has no endpoints"
    log_info "This might mean:"
    log_info "  1. Pods are not running"
    log_info "  2. Pod labels don't match service selector"
    log_info ""
    log_info "Check pod status:"
    log_info "  oc get pods -n $NAMESPACE -l app=eip-monitor"
    log_info ""
    log_info "Check pod labels:"
    log_info "  oc get pods -n $NAMESPACE -l app=eip-monitor -o jsonpath='{.items[*].metadata.labels}'"
else
    log_success "Service has endpoints: $endpoints"
fi

log_info ""
log_info "Service labels have been fixed. The ServiceMonitor should now be able to discover the service."
log_info "Run './scripts/verify-prometheus-metrics.sh' to verify Prometheus discovery."

