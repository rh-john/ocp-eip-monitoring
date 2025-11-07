#!/bin/bash
#
# Deploy Grafana Operator and Dashboards for EIP Monitoring
# This script is completely independent and can be used standalone
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"
<<<<<<< Updated upstream
MONITORING_TYPE="${MONITORING_TYPE:-}"  # Will be auto-detected if not set
=======
>>>>>>> Stashed changes
REMOVE_GRAFANA="${REMOVE_GRAFANA:-false}"

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
<<<<<<< Updated upstream
  --monitoring-type TYPE    Monitoring type: coo or uwm (auto-detected if not specified)
  --remove-grafana          Remove Grafana resources
=======
  --remove-grafana         Remove Grafana datasources and resources
>>>>>>> Stashed changes
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
<<<<<<< Updated upstream
  MONITORING_TYPE           Monitoring type: coo or uwm (auto-detected if not specified)
=======
  REMOVE_GRAFANA            Set to true to remove Grafana resources (default: false)
>>>>>>> Stashed changes

Examples:
  $0
  $0 -n my-namespace
<<<<<<< Updated upstream
  $0 --monitoring-type coo
  $0 --monitoring-type uwm
=======
>>>>>>> Stashed changes
  $0 --remove-grafana

EOF
}

# Auto-detect monitoring type
detect_monitoring_type() {
    # Check for COO (Cluster Observability Operator)
    # COO uses MonitoringStack CRD
    if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
        # Check if there are any MonitoringStack resources
        local monitoring_stacks=$(oc get monitoringstack --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
        if [[ "$monitoring_stacks" =~ ^[0-9]+$ ]] && [[ "$monitoring_stacks" -gt 0 ]]; then
            log_info "Detected Cluster Observability Operator (COO) - found $monitoring_stacks MonitoringStack resource(s)" >&2
            echo "coo"
            return 0
        fi
    fi
    
    # Check for UWM (User Workload Monitoring)
    # UWM uses openshift-user-workload-monitoring namespace
    if oc get namespace openshift-user-workload-monitoring &>/dev/null; then
        # Verify it's actually active by checking for Prometheus pods
        local prom_pods=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null | tr -d '[:space:]' || echo "0")
        if [[ "$prom_pods" =~ ^[0-9]+$ ]] && [[ "$prom_pods" -gt 0 ]]; then
            log_info "Detected User Workload Monitoring (UWM) - found $prom_pods Prometheus pod(s) in openshift-user-workload-monitoring" >&2
            echo "uwm"
            return 0
        fi
    fi
    
    # If neither is clearly detected, check for UWM namespace existence (even without pods)
    if oc get namespace openshift-user-workload-monitoring &>/dev/null; then
        log_warn "Found openshift-user-workload-monitoring namespace but no running Prometheus pods" >&2
        log_info "Assuming UWM (User Workload Monitoring)" >&2
        echo "uwm"
        return 0
    fi
    
    # Default fallback - could not detect
    log_warn "Could not auto-detect monitoring type" >&2
    log_info "Checking for COO MonitoringStack CRD..." >&2
    if oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
        log_info "COO CRD found but no MonitoringStack resources detected" >&2
    fi
    log_info "Checking for UWM namespace..." >&2
    if ! oc get namespace openshift-user-workload-monitoring &>/dev/null; then
        log_info "UWM namespace not found" >&2
    fi
    log_error "Please specify --monitoring-type coo or --monitoring-type uwm" >&2
    return 1
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

# Remove Grafana resources
remove_grafana_resources() {
    log_info "Removing Grafana resources..."
    
    local resources_found=false
    
    # Delete dashboards
    if oc get grafanadashboard -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        oc delete grafanadashboard -n "$NAMESPACE" --all 2>&1 | grep -v "No resources found" || true
        resources_found=true
    else
        log_info "  No GrafanaDashboards found"
    fi
    
    # Delete datasources
    if oc get grafanadatasource -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        oc delete grafanadatasource -n "$NAMESPACE" --all 2>&1 | grep -v "No resources found" || true
        resources_found=true
    else
        log_info "  No GrafanaDataSources found"
    fi
    
    # Delete Grafana instance
    if oc get grafana -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
        oc delete grafana -n "$NAMESPACE" --all 2>&1 | grep -v "No resources found" || true
        resources_found=true
    else
        log_info "  No Grafana instances found"
    fi
    
    # Delete RBAC (monitoring-specific)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local rbac_file="${project_root}/k8s/monitoring/${MONITORING_TYPE}/rbac/grafana-rbac-${MONITORING_TYPE}.yaml"
    if [[ -f "$rbac_file" ]]; then
        log_info "  Removing RBAC resources..."
        oc delete -f "$rbac_file" 2>&1 | grep -v "not found\|No resources found" || true
        resources_found=true
    fi
    
    if [[ "$resources_found" == "true" ]]; then
        log_success "Grafana resources removed"
    else
        log_info "No Grafana resources found to remove"
    fi
}

# Deploy Grafana resources
deploy_grafana() {
    # Validate monitoring type
    if [[ "$MONITORING_TYPE" != "coo" ]] && [[ "$MONITORING_TYPE" != "uwm" ]]; then
        log_error "Invalid monitoring type: $MONITORING_TYPE. Must be 'coo' or 'uwm'"
        exit 1
    fi
    
    log_info "Deploying Grafana for EIP monitoring (${MONITORING_TYPE})..."
    
    # Ensure namespace exists first
    if ! oc get namespace "$NAMESPACE" &>/dev/null; then
        log_warn "Namespace '$NAMESPACE' not found, creating it..."
        oc create namespace "$NAMESPACE" 2>/dev/null || {
            log_error "Failed to create namespace"
            return 1
        }
    fi
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local grafana_dir="${project_root}/k8s/grafana"
    local monitoring_dir="${project_root}/k8s/monitoring/${MONITORING_TYPE}"
    
    # Check if Grafana operator is already installed
    local csv_phase=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .status.phase' | head -1 || echo "")
    
    if [[ "$csv_phase" == "Succeeded" ]]; then
        log_info "Grafana Operator is already installed and ready (CSV phase: Succeeded)"
    elif oc get crd grafanas.integreatly.org &>/dev/null; then
        log_info "Grafana Operator CRD found, operator is available"
    else
        log_info "Installing Grafana Operator (namespace-scoped in $NAMESPACE)..."
        local operator_file="${grafana_dir}/grafana-operator.yaml"
        if [[ ! -f "$operator_file" ]]; then
            log_error "Grafana operator file not found: $operator_file"
            return 1
        fi
        if oc apply -f "$operator_file" &>/dev/null; then
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
    
    # Deploy Service Account and RBAC
    log_info "Creating Service Account and RBAC for Grafana..."
    local rbac_file="${monitoring_dir}/rbac/grafana-rbac-${MONITORING_TYPE}.yaml"
    if oc apply -f "$rbac_file" &>/dev/null; then
        log_success "Service Account and RBAC created"
    else
        log_error "Failed to create Service Account and RBAC"
        log_error "This requires cluster-admin permissions for ClusterRoleBinding"
        return 1
    fi
    
    # Deploy Grafana DataSource
    log_info "Deploying Grafana DataSource (${MONITORING_TYPE})..."
    local ds_file="${monitoring_dir}/grafana/grafana-datasource-${MONITORING_TYPE}.yaml"
    
    local ds_output=$(oc apply -f "$ds_file" 2>&1)
    local ds_exit=$?
    if [[ $ds_exit -eq 0 ]]; then
        log_success "Grafana DataSource deployed"
        
        # For UWM, create and patch token for Thanos Querier
        if [[ "$MONITORING_TYPE" == "uwm" ]]; then
            log_info "Creating service account token for Thanos Querier authentication..."
            local token=""
            local token_output=$(oc create token grafana-prometheus -n "$NAMESPACE" --duration=8760h 2>&1)
            local token_exit=$?
            if [[ $token_exit -eq 0 ]] && [[ -n "$token_output" ]]; then
                token="$token_output"
                log_info "Updating Grafana DataSource with service account token..."
                if oc patch grafanadatasource prometheus-uwm -n "$NAMESPACE" --type=json \
                    -p="[{\"op\": \"replace\", \"path\": \"/spec/datasource/secureJsonData/httpHeaderValue1\", \"value\": \"Bearer $token\"}]" &>/dev/null; then
                    log_success "Grafana DataSource token updated"
                else
                    log_warn "Failed to update datasource token (may need manual update)"
                fi
            else
                log_warn "Failed to create token, datasource may not work until token is manually added"
            fi
        fi
    else
        log_error "Failed to deploy Grafana DataSource"
        echo "$ds_output" | sed 's/^/  /'
        return 1
    fi
    
    # Deploy Grafana Instance
    log_info "Deploying Grafana Instance..."
    local instance_file="${grafana_dir}/grafana-instance.yaml"
    local instance_output=$(oc apply -f "$instance_file" 2>&1)
    local instance_exit=$?
    if [[ $instance_exit -eq 0 ]]; then
        log_success "Grafana Instance deployed"
    else
        log_error "Failed to deploy Grafana Instance"
        echo "$instance_output" | sed 's/^/  /'
        return 1
    fi
    
    log_info "Plugins are configured in the Grafana instance manifest and will be installed automatically by the operator"
    
    # Deploy Grafana Dashboards
    log_info "Deploying Grafana Dashboards..."
    local dashboards_deployed=0
    local dashboards_failed=0
    
    for dashboard_file in "${grafana_dir}"/grafana-dashboard*.yaml; do
        if [[ -f "$dashboard_file" ]]; then
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

# Remove Grafana resources
remove_grafana() {
    log_info "Removing Grafana datasources and resources..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # Delete COO Grafana datasource
    if oc get grafanadatasource prometheus-coo -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting COO GrafanaDatasource..."
        oc delete grafanadatasource prometheus-coo -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete COO GrafanaDatasource"
    fi
    
    # Delete UWM Grafana datasource
    if oc get grafanadatasource prometheus-uwm -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting UWM GrafanaDatasource..."
        oc delete grafanadatasource prometheus-uwm -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete UWM GrafanaDatasource"
    fi
    
    # Also try deleting via manifest files if they exist
    if [[ -f "${project_root}/k8s/monitoring/coo/grafana/grafana-datasource-coo.yaml" ]]; then
        oc delete -f "${project_root}/k8s/monitoring/coo/grafana/grafana-datasource-coo.yaml" 2>/dev/null || true
    fi
    
    if [[ -f "${project_root}/k8s/monitoring/uwm/grafana/grafana-datasource-uwm.yaml" ]]; then
        oc delete -f "${project_root}/k8s/monitoring/uwm/grafana/grafana-datasource-uwm.yaml" 2>/dev/null || true
    fi
    
    log_success "Grafana datasources removed"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
<<<<<<< Updated upstream
            --monitoring-type)
                MONITORING_TYPE="$2"
                shift 2
                ;;
=======
>>>>>>> Stashed changes
            --remove-grafana)
                REMOVE_GRAFANA="true"
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
    
    check_prerequisites
    
    # Auto-detect monitoring type if not explicitly set
    if [[ -z "$MONITORING_TYPE" ]]; then
        log_info "Auto-detecting monitoring type..."
        local detected_type
        detected_type=$(detect_monitoring_type)
        if [[ -z "$detected_type" ]]; then
            exit 1
        fi
        MONITORING_TYPE="$detected_type"
    fi
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    log_info "Deploying to namespace: $NAMESPACE"
    log_info "Monitoring type: $MONITORING_TYPE"
    
    if [[ "$REMOVE_GRAFANA" == "true" ]]; then
<<<<<<< Updated upstream
        remove_grafana_resources
=======
        remove_grafana
>>>>>>> Stashed changes
    else
        deploy_grafana
        
        log_success "Grafana deployment completed!"
        log_info "Grafana resources status:"
<<<<<<< Updated upstream
        oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>&1 | grep -v "No resources found" || log_info "  (Resources may still be initializing)"
=======
        oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>/dev/null || log_info "  (Resources may still be initializing)"
>>>>>>> Stashed changes
    fi
}

# Run main function
main "$@"

