#!/bin/bash
#
# Deploy Grafana Operator and Dashboards for EIP Monitoring
# This script is completely independent and can be used standalone
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"

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

# Show usage
show_usage() {
    cat << EOF
Deploy Grafana Operator and Dashboards for EIP Monitoring

Usage: $0 [options]

Options:
  -n, --namespace NS        Kubernetes namespace (default: eip-monitoring)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)

Examples:
  $0
  $0 -n my-namespace

EOF
}

# Check prerequisites
check_prerequisites() {
    local missing_tools=()
    
    if ! command -v oc &> /dev/null; then
        missing_tools+=("oc")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install the missing tools and try again"
        exit 1
    fi
    
    # Check OpenShift connectivity
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        exit 1
    fi
}

# Deploy Grafana resources
deploy_grafana() {
    log_info "Deploying Grafana for EIP monitoring..."
    
    # Ensure namespace exists first
    if ! oc get namespace "$NAMESPACE" &>/dev/null; then
        log_warn "Namespace '$NAMESPACE' not found, creating it..."
        oc create namespace "$NAMESPACE" 2>/dev/null || {
            log_error "Failed to create namespace"
            return 1
        }
    fi
    
    # Check if Grafana operator is already installed
    local csv_phase=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .status.phase' | head -1 || echo "")
    
    if [[ "$csv_phase" == "Succeeded" ]]; then
        log_info "Grafana Operator is already installed and ready (CSV phase: Succeeded)"
    elif oc get crd grafanas.integreatly.org &>/dev/null; then
        log_info "Grafana Operator CRD found, operator is available"
    else
        log_info "Installing Grafana Operator (namespace-scoped in $NAMESPACE)..."
        if oc apply -f k8s/grafana/grafana-operator.yaml &>/dev/null; then
            log_success "Grafana Operator subscription and OperatorGroup created"
            log_info "Waiting for Grafana Operator to be installed (this may take a few minutes)..."
            
            # Wait for CSV to succeed or CRD to be available
            local max_wait=300
            local waited=0
            while [[ $waited -lt $max_wait ]]; do
                csv_phase=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .status.phase' | head -1 || echo "")
                if [[ "$csv_phase" == "Succeeded" ]]; then
                    log_success "Grafana Operator installed successfully (CSV phase: Succeeded)"
                    break
                elif oc get crd grafanas.integreatly.org &>/dev/null; then
                    log_success "Grafana Operator CRD available"
                    break
                fi
                sleep 5
                waited=$((waited + 5))
                if [[ $((waited % 30)) -eq 0 ]]; then
                    log_info "Still waiting for Grafana Operator... (${waited}s, CSV phase: ${csv_phase:-none})"
                fi
            done
            
            if [[ $waited -ge $max_wait ]]; then
                log_warn "Grafana Operator may not be fully ready yet (waited ${max_wait}s)"
                log_info "Current CSV phase: ${csv_phase:-unknown}"
                log_info "It may take several minutes to fully install"
            fi
        else
            log_error "Failed to install Grafana Operator"
            log_error "This requires cluster-admin permissions"
            return 1
        fi
    fi
    
    # Deploy Service Account and RBAC for Thanos Querier access
    log_info "Creating Service Account and RBAC for Grafana..."
    if oc apply -f k8s/grafana/grafana-rbac.yaml &>/dev/null; then
        log_success "Service Account and ClusterRoleBinding created"
    else
        log_error "Failed to create Service Account and RBAC"
        log_error "This requires cluster-admin permissions for ClusterRoleBinding"
        return 1
    fi
    
    # Create a long-lived token for the service account
    log_info "Creating service account token for Thanos Querier authentication..."
    local token=""
    local token_output=$(oc create token grafana-prometheus -n "$NAMESPACE" --duration=8760h 2>&1)
    local token_exit=$?
    if [[ $token_exit -eq 0 ]] && [[ -n "$token_output" ]]; then
        token="$token_output"
        log_success "Service account token created"
    else
        log_warn "Failed to create token, will use placeholder (datasource may not work)"
        log_info "You can manually create a token with:"
        log_info "  oc create token grafana-prometheus -n $NAMESPACE --duration=8760h"
        log_info "Then patch the datasource:"
        log_info "  oc patch grafanadatasource prometheus-uwm -n $NAMESPACE --type=json -p='[{\"op\": \"replace\", \"path\": \"/spec/datasource/secureJsonData/httpHeaderValue1\", \"value\": \"Bearer <TOKEN>\"}]'"
        token="PLACEHOLDER_TOKEN"
    fi
    
    # Deploy Grafana DataSource
    log_info "Deploying Grafana DataSource..."
    local ds_output=$(oc apply -f k8s/grafana/grafana-datasource.yaml 2>&1)
    local ds_exit=$?
    if [[ $ds_exit -eq 0 ]]; then
        log_success "Grafana DataSource deployed"
        
        # Patch the datasource with the actual token if we have one
        if [[ -n "$token" ]] && [[ "$token" != "PLACEHOLDER_TOKEN" ]]; then
            log_info "Updating Grafana DataSource with service account token..."
            if oc patch grafanadatasource prometheus-uwm -n "$NAMESPACE" --type=json \
                -p="[{\"op\": \"replace\", \"path\": \"/spec/datasource/secureJsonData/httpHeaderValue1\", \"value\": \"Bearer $token\"}]" &>/dev/null; then
                log_success "Grafana DataSource token updated"
            else
                log_warn "Failed to update datasource token (may need manual update)"
            fi
        fi
    else
        log_error "Failed to deploy Grafana DataSource"
        echo "$ds_output" | sed 's/^/  /'
        return 1
    fi
    
    # Deploy Grafana Instance
    log_info "Deploying Grafana Instance..."
    local instance_output=$(oc apply -f k8s/grafana/grafana-instance.yaml 2>&1)
    local instance_exit=$?
    if [[ $instance_exit -eq 0 ]]; then
        log_success "Grafana Instance deployed"
    else
        log_error "Failed to deploy Grafana Instance"
        echo "$instance_output" | sed 's/^/  /'
        return 1
    fi
    
    # Plugins are configured in grafana-instance.yaml via spec.plugins
    # The Grafana Operator will automatically install them during deployment
    log_info "Plugins are configured in the Grafana instance manifest and will be installed automatically by the operator"
    # Deploy Grafana Dashboards
    log_info "Deploying Grafana Dashboards..."
    local dashboard_files=(
        # Original dashboards
        "k8s/grafana/grafana-dashboard.yaml"
        "k8s/grafana/grafana-dashboard-eip-distribution.yaml"
        "k8s/grafana/grafana-dashboard-cpic-health.yaml"
        "k8s/grafana/grafana-dashboard-node-performance.yaml"
        "k8s/grafana/grafana-dashboard-eip-timeline.yaml"
        "k8s/grafana/grafana-dashboard-cluster-health.yaml"
        # New advanced plugin dashboards
        "k8s/grafana/grafana-dashboard-state-visualization.yaml"
        "k8s/grafana/grafana-dashboard-enhanced-tables.yaml"
        "k8s/grafana/grafana-dashboard-architecture-diagram.yaml"
        "k8s/grafana/grafana-dashboard-custom-gauges.yaml"
        "k8s/grafana/grafana-dashboard-timeline-events.yaml"
        "k8s/grafana/grafana-dashboard-node-health-grid.yaml"
        "k8s/grafana/grafana-dashboard-network-topology.yaml"
        "k8s/grafana/grafana-dashboard-interactive-drilldown.yaml"
    )
    
    local dashboards_deployed=0
    local dashboards_failed=0
    
    for dashboard_file in "${dashboard_files[@]}"; do
        local dashboard_name=$(basename "$dashboard_file" .yaml)
        local dashboard_output=$(oc apply -f "$dashboard_file" 2>&1)
        local dashboard_exit=$?
        if [[ $dashboard_exit -eq 0 ]]; then
            log_success "  ✓ $dashboard_name deployed"
            ((dashboards_deployed++))
        else
            log_error "  ✗ Failed to deploy $dashboard_name"
            echo "$dashboard_output" | sed 's/^/    /'
            ((dashboards_failed++))
        fi
    done
    
    if [[ $dashboards_failed -eq 0 ]]; then
        log_success "All $dashboards_deployed Grafana Dashboards deployed successfully!"
    else
        log_warn "$dashboards_failed dashboard(s) failed to deploy, $dashboards_deployed succeeded"
    fi
    
    log_success "Grafana deployment completed!"
    log_info "Grafana will be available shortly. Check status with:"
    log_info "  oc get grafana -n $NAMESPACE"
    log_info "  oc get route -n $NAMESPACE | grep grafana"
    log_info "  oc get grafanadashboard -n $NAMESPACE"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
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
    
    check_prerequisites
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    log_info "Deploying to namespace: $NAMESPACE"
    
    deploy_grafana
    
    log_success "Grafana deployment completed!"
    log_info "Grafana resources status:"
    oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>/dev/null || log_info "  (Resources may still be initializing)"
}

# Run main function
main "$@"

