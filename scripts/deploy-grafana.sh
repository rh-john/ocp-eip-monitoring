#!/bin/bash
#
# Deploy Grafana Operator and Dashboards for EIP Monitoring
# This script is completely independent and can be used standalone
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"
MONITORING_TYPE="${MONITORING_TYPE:-}"
REMOVE_GRAFANA="${REMOVE_GRAFANA:-false}"
REMOVE_OPERATOR="${REMOVE_OPERATOR:-false}"
DELETE_CRDS="${DELETE_CRDS:-false}"  # Delete Grafana CRDs during cleanup (requires cluster-admin)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'  # Light blue (cyan)
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
  -t, --monitoring-type TYPE Monitoring type: coo or uwm (required for deployment)
  -r, --remove              Remove Grafana resources (dashboards, datasources, instances, RBAC)
  --remove-operator         Also remove Grafana Operator subscription (requires --remove)
  --all                     Remove all Grafana resources including operator (equivalent to --remove --remove-operator)
  --delete-crds             Delete Grafana CRDs during cleanup (requires cluster-admin, only with --remove-operator or --all)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
  MONITORING_TYPE           Monitoring type: coo or uwm (required for deployment)
  REMOVE_GRAFANA            Set to 'true' to remove Grafana resources
  REMOVE_OPERATOR           Set to 'true' to also remove Grafana Operator subscription
  DELETE_CRDS               Set to 'true' to delete Grafana CRDs (requires cluster-admin)

Examples:
  # Deploy Grafana for COO
  $0 --monitoring-type coo
  
  # Deploy Grafana for UWM
  $0 --monitoring-type uwm -n my-namespace
  
  # Remove Grafana resources
  $0 --remove --monitoring-type coo
  
  # Remove Grafana resources and operator
  $0 --remove --remove-operator --monitoring-type uwm
  
  # Remove everything (Grafana resources and operator)
  $0 --all --monitoring-type coo
  
  # Remove everything including CRDs (for E2E tests, requires cluster-admin)
  $0 --all --monitoring-type uwm --delete-crds

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
    
    # Calculate project root once at the beginning of the function
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # Ensure namespace exists first
    if ! oc get namespace "$NAMESPACE" &>/dev/null; then
        log_warn "Namespace '$NAMESPACE' not found, creating it..."
        oc create namespace "$NAMESPACE" 2>/dev/null || {
            log_error "Failed to create namespace"
            return 1
        }
    fi
    
    # Check if Grafana operator is already installed
    # First check cluster-scoped (openshift-operators) and namespace-scoped installations
    local cluster_csv_phase=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .status.phase' | head -1 || echo "")
    local namespace_csv_phase=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .status.phase' | head -1 || echo "")
    
    if [[ "$cluster_csv_phase" == "Succeeded" ]] || [[ "$namespace_csv_phase" == "Succeeded" ]]; then
        log_info "Grafana Operator is already installed and ready (CSV phase: Succeeded)"
    elif oc get crd grafanas.integreatly.org &>/dev/null; then
        log_info "Grafana Operator CRD found, operator is available"
    else
        log_info "Installing Grafana Operator (namespace-scoped in $NAMESPACE)..."
        
        # Check for multiple OperatorGroups (this prevents subscription resolution)
        local operatorgroup_count=$(oc get operatorgroup -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
        if [[ "$operatorgroup_count" -gt 1 ]]; then
            log_warn "Multiple OperatorGroups found in namespace $NAMESPACE (this prevents operator installation)"
            log_info "Checking for duplicate OperatorGroups..."
            local operatorgroups=$(oc get operatorgroup -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
            log_info "Found OperatorGroups: $operatorgroups"
            
            # Check which OperatorGroup has the MultipleOperatorGroup condition
            local duplicate_og=""
            for og in $operatorgroups; do
                local condition=$(oc get operatorgroup "$og" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="MultipleOperatorGroup")].status}' 2>/dev/null || echo "")
                if [[ "$condition" == "True" ]]; then
                    # Check if this is NOT the one we're about to create
                    if [[ "$og" != "eip-monitoring-operatorgroup" ]]; then
                        duplicate_og="$og"
                        log_warn "Found duplicate OperatorGroup: $og (will be deleted)"
                        break
                    fi
                fi
            done
            
            # Delete duplicate OperatorGroups (keep eip-monitoring-operatorgroup if it exists)
            if [[ -n "$duplicate_og" ]]; then
                log_info "Deleting duplicate OperatorGroup: $duplicate_og"
                oc delete operatorgroup "$duplicate_og" -n "$NAMESPACE" 2>/dev/null || true
                log_success "Deleted duplicate OperatorGroup"
                sleep 3  # Wait for OLM to reconcile
            else
                # If we can't identify which one to delete, warn and try to proceed
                log_warn "Could not identify which OperatorGroup to delete"
                log_info "You may need to manually delete duplicate OperatorGroups:"
                log_info "  oc get operatorgroup -n $NAMESPACE"
                log_info "  oc delete operatorgroup <duplicate-name> -n $NAMESPACE"
            fi
        fi
        
        local operator_file="${project_root}/k8s/grafana/grafana-operator.yaml"
        if [[ ! -f "$operator_file" ]]; then
            log_error "Grafana operator file not found: $operator_file"
            log_info "The file should contain OperatorGroup and Subscription for namespace-scoped installation"
            return 1
        fi
        
        if oc apply -f "$operator_file" &>/dev/null; then
            log_success "Grafana Operator subscription and OperatorGroup created"
            log_info "Waiting for Grafana Operator to be installed (this may take a few minutes)..."
            
            # Wait for CSV to succeed or CRD to be available
            local max_wait=300
            local waited=0
            while [[ $waited -lt $max_wait ]]; do
                local csv_phase=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .status.phase' | head -1 || echo "")
                
                # Check subscription status for better diagnostics
                local subscription_state=$(oc get subscription grafana-operator -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
                local current_csv=$(oc get subscription grafana-operator -n "$NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
                local installplan_pending=$(oc get subscription grafana-operator -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="InstallPlanPending")].status}' 2>/dev/null || echo "")
                
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
                    local status_info="CSV phase: ${csv_phase:-none}"
                    if [[ -n "$subscription_state" ]]; then
                        status_info="$status_info, Subscription state: $subscription_state"
                    fi
                    if [[ -n "$current_csv" ]]; then
                        status_info="$status_info, CSV: $current_csv"
                    fi
                    if [[ "$installplan_pending" == "True" ]]; then
                        status_info="$status_info, InstallPlan pending"
                    fi
                    log_info "Still waiting for Grafana Operator... (${waited}s, $status_info)"
                    
                    # If CSV phase is still "none" after 60s, check for common issues
                    if [[ $waited -ge 60 ]] && ([[ -z "$csv_phase" ]] || [[ "$csv_phase" == "none" ]]); then
                        # Check for multiple OperatorGroups again
                        local og_count=$(oc get operatorgroup -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
                        if [[ "$og_count" -gt 1 ]]; then
                            log_warn "Multiple OperatorGroups still detected - this prevents CSV creation"
                            log_info "Run: oc get operatorgroup -n $NAMESPACE"
                            log_info "Delete duplicates: oc delete operatorgroup <name> -n $NAMESPACE"
                        fi
                        
                        # Check InstallPlan status
                        local installplan=$(oc get installplan -n "$NAMESPACE" --no-headers 2>/dev/null | head -1 || echo "")
                        if [[ -z "$installplan" ]]; then
                            log_warn "No InstallPlan found - subscription may not be resolving"
                            log_info "Check subscription: oc get subscription grafana-operator -n $NAMESPACE -o yaml"
                        fi
                    fi
                fi
            done
            
            if [[ $waited -ge $max_wait ]]; then
                log_warn "Grafana Operator may not be fully ready yet (waited ${max_wait}s)"
                log_info "Current CSV phase: ${csv_phase:-unknown}"
                
                # Provide diagnostic information
                local final_state=$(oc get subscription grafana-operator -n "$NAMESPACE" -o jsonpath='{.status.state}' 2>/dev/null || echo "")
                local final_csv=$(oc get subscription grafana-operator -n "$NAMESPACE" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
                if [[ -n "$final_state" ]]; then
                    log_info "Subscription state: $final_state"
                fi
                if [[ -n "$final_csv" ]]; then
                    log_info "Expected CSV: $final_csv"
                fi
                
                # Check for common issues
                local og_count=$(oc get operatorgroup -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
                if [[ "$og_count" -gt 1 ]]; then
                    log_error "Multiple OperatorGroups detected - this prevents operator installation"
                    log_info "Fix: oc get operatorgroup -n $NAMESPACE"
                    log_info "Delete duplicates: oc delete operatorgroup <name> -n $NAMESPACE"
                fi
                
                log_info "It may take several minutes to fully install"
                log_info "Check status: oc get csv,installplan,subscription -n $NAMESPACE"
            fi
        else
            log_error "Failed to install Grafana Operator"
            log_error "This requires cluster-admin permissions for OperatorGroup/Subscription creation"
            log_info ""
            log_info "Alternative: Install Grafana Operator cluster-wide (requires cluster-admin):"
            log_info "  oc apply -f - <<'EOF'"
            log_info "apiVersion: operators.coreos.com/v1alpha1"
            log_info "kind: Subscription"
            log_info "metadata:"
            log_info "  name: grafana-operator"
            log_info "  namespace: openshift-operators"
            log_info "spec:"
            log_info "  channel: v5"
            log_info "  name: grafana-operator"
            log_info "  source: community-operators"
            log_info "  sourceNamespace: openshift-marketplace"
            log_info "  installPlanApproval: Automatic"
            log_info "EOF"
            return 1
        fi
    fi
    
    # Determine RBAC and datasource files based on monitoring type
    local rbac_file=""
    local datasource_file=""
    local service_account_name=""
    local datasource_name=""
    
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        rbac_file="${project_root}/k8s/grafana/coo/grafana-rbac-coo.yaml"
        datasource_file="${project_root}/k8s/grafana/coo/grafana-datasource-coo.yaml"
        service_account_name="grafana-prometheus-coo"
        datasource_name="prometheus-coo"
    elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
        rbac_file="${project_root}/k8s/grafana/uwm/grafana-rbac-uwm.yaml"
        datasource_file="${project_root}/k8s/grafana/uwm/grafana-datasource-uwm.yaml"
        service_account_name="grafana-prometheus"
        datasource_name="prometheus-uwm"
    else
        log_error "Invalid or missing monitoring type: $MONITORING_TYPE"
        log_error "Must specify --monitoring-type coo or --monitoring-type uwm"
        return 1
    fi
    
    # Check if RBAC file exists
    if [[ ! -f "$rbac_file" ]]; then
        log_error "RBAC file not found: $rbac_file"
        return 1
    fi
    
    # Check if datasource file exists
    if [[ ! -f "$datasource_file" ]]; then
        log_error "Datasource file not found: $datasource_file"
        return 1
    fi
    
    # Deploy Service Account and RBAC
    log_info "Creating Service Account and RBAC for Grafana ($MONITORING_TYPE)..."
    if oc apply -f "$rbac_file" &>/dev/null; then
        log_success "Service Account and RBAC created"
    else
        log_error "Failed to create Service Account and RBAC"
        if [[ "$MONITORING_TYPE" == "uwm" ]]; then
            log_error "This requires cluster-admin permissions for ClusterRoleBinding"
        fi
        return 1
    fi
    
    # Create a long-lived token for the service account (only needed for UWM)
    local token=""
    if [[ "$MONITORING_TYPE" == "uwm" ]]; then
        log_info "Creating service account token for Thanos Querier authentication..."
        local token_output=$(oc create token "$service_account_name" -n "$NAMESPACE" --duration=8760h 2>&1)
        local token_exit=$?
        if [[ $token_exit -eq 0 ]] && [[ -n "$token_output" ]]; then
            token="$token_output"
            log_success "Service account token created"
        else
            log_warn "Failed to create token, will use placeholder (datasource may not work)"
            log_info "You can manually create a token with:"
            log_info "  oc create token $service_account_name -n $NAMESPACE --duration=8760h"
            log_info "Then patch the datasource:"
            log_info "  oc patch grafanadatasource $datasource_name -n $NAMESPACE --type=json -p='[{\"op\": \"replace\", \"path\": \"/spec/datasource/secureJsonData/httpHeaderValue1\", \"value\": \"Bearer <TOKEN>\"}]'"
            token="PLACEHOLDER_TOKEN"
        fi
    fi
    
    # Deploy Grafana Instance FIRST (DataSource and Dashboards depend on it via instanceSelector)
    log_info "Deploying Grafana Instance..."
    local instance_output=$(oc apply -f "${project_root}/k8s/grafana/grafana-instance.yaml" 2>&1)
    local instance_exit=$?
    if [[ $instance_exit -eq 0 ]]; then
        log_success "Grafana Instance deployed"
        log_info "Waiting for Grafana Instance to be ready..."
        # Wait a moment for the instance to start initializing
        sleep 5
    else
        log_error "Failed to deploy Grafana Instance"
        echo "$instance_output" | sed 's/^/  /'
        return 1
    fi
    
    # Deploy Grafana DataSource (now that Instance exists)
    log_info "Deploying Grafana DataSource ($MONITORING_TYPE)..."
    local ds_output=$(oc apply -f "$datasource_file" 2>&1)
    local ds_exit=$?
    if [[ $ds_exit -eq 0 ]]; then
        log_success "Grafana DataSource deployed"
        
        # Patch the datasource with the actual token if we have one (UWM only)
        if [[ "$MONITORING_TYPE" == "uwm" ]] && [[ -n "$token" ]] && [[ "$token" != "PLACEHOLDER_TOKEN" ]]; then
            log_info "Updating Grafana DataSource with service account token..."
            if oc patch grafanadatasource "$datasource_name" -n "$NAMESPACE" --type=json \
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
    
    # Plugins are configured in grafana-instance.yaml via spec.plugins
    # The Grafana Operator will automatically install them during deployment
    log_info "Plugins are configured in the Grafana instance manifest and will be installed automatically by the operator"
    # Deploy Grafana Dashboards
    log_info "Deploying Grafana Dashboards..."
    # Automatically discover all dashboard files in the dashboards directory
    local dashboard_dir="${project_root}/k8s/grafana/dashboards"
    local dashboard_files=()
    
    if [[ -d "$dashboard_dir" ]]; then
        # Find all YAML files matching the dashboard pattern
        for file in "${dashboard_dir}"/grafana-dashboard*.yaml; do
            [[ -f "$file" ]] && dashboard_files+=("$file")
        done
        
        # Sort for consistent deployment order
        IFS=$'\n' dashboard_files=($(sort <<<"${dashboard_files[*]}"))
        unset IFS
        
        if [[ ${#dashboard_files[@]} -eq 0 ]]; then
            log_warn "No dashboard files found in $dashboard_dir"
        else
            log_info "Found ${#dashboard_files[@]} dashboard file(s) to deploy"
        fi
    else
        log_error "Dashboard directory not found: $dashboard_dir"
        return 1
    fi
    
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

# Remove Grafana resources
remove_grafana() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Removing Grafana resources..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Determine RBAC resources based on monitoring type
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local rbac_file=""
    local service_account_name=""
    
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        rbac_file="${project_root}/k8s/grafana/coo/grafana-rbac-coo.yaml"
        service_account_name="grafana-prometheus-coo"
    elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
        rbac_file="${project_root}/k8s/grafana/uwm/grafana-rbac-uwm.yaml"
        service_account_name="grafana-prometheus"
    else
        log_warn "Monitoring type not specified, will attempt to remove all Grafana resources"
    fi
    
    # Delete Grafana resources in correct dependency order
    # Order: Dashboards -> DataSources -> Instances (reverse of creation order)
    # Check if CRDs exist before attempting deletion (operator may not be installed)
    if oc get crd grafanadashboards.integreatly.org &>/dev/null; then
        log_info "Deleting GrafanaDashboards..."
        oc delete grafanadashboard -n "$NAMESPACE" --all --wait=false --timeout=30s 2>&1 | grep -vE "(No resources found|the server doesn't have a resource type)" || true
        
        # Wait a moment for dashboards to start deletion
        sleep 2
        
        # Force delete if finalizers are blocking (common issue with Grafana CRDs)
        log_info "Checking for resources stuck with finalizers..."
        local stuck_dashboards=$(oc get grafanadashboard -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
        if [[ -n "$stuck_dashboards" ]]; then
            log_warn "Found GrafanaDashboards with finalizers, removing finalizers..."
            echo "$stuck_dashboards" | while read -r name; do
                oc patch grafanadashboard "$name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            done
        fi
    else
        log_info "GrafanaDashboards CRD not found (operator not installed), skipping dashboard cleanup"
    fi
    
    if oc get crd grafanadatasources.integreatly.org &>/dev/null; then
        log_info "Deleting GrafanaDataSources..."
        oc delete grafanadatasource -n "$NAMESPACE" --all --wait=false --timeout=30s 2>&1 | grep -vE "(No resources found|the server doesn't have a resource type)" || true
        
        # Wait a moment for datasources to start deletion
        sleep 2
        
        local stuck_datasources=$(oc get grafanadatasource -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
        if [[ -n "$stuck_datasources" ]]; then
            log_warn "Found GrafanaDataSources with finalizers, removing finalizers..."
            echo "$stuck_datasources" | while read -r name; do
                oc patch grafanadatasource "$name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            done
        fi
    else
        log_info "GrafanaDataSources CRD not found (operator not installed), skipping datasource cleanup"
    fi
    
    if oc get crd grafanas.integreatly.org &>/dev/null; then
        log_info "Deleting Grafana Instances..."
        oc delete grafana -n "$NAMESPACE" --all --wait=false --timeout=30s 2>&1 | grep -vE "(No resources found|the server doesn't have a resource type)" || true
        
        local stuck_instances=$(oc get grafana -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
        if [[ -n "$stuck_instances" ]]; then
            log_warn "Found Grafana Instances with finalizers, removing finalizers..."
            echo "$stuck_instances" | while read -r name; do
                oc patch grafana "$name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            done
        fi
    else
        log_info "Grafana CRD not found (operator not installed), skipping instance cleanup"
    fi
    
    # Wait a moment for finalizer removal to take effect
    sleep 2
    
    # Force delete any remaining resources (in case they're still stuck after finalizer removal)
    log_info "Force deleting any remaining Grafana resources..."
    oc delete grafanadashboard -n "$NAMESPACE" --all --force --grace-period=0 2>&1 | grep -vE "(No resources found|Warning: Immediate deletion)" || true
    oc delete grafanadatasource -n "$NAMESPACE" --all --force --grace-period=0 2>&1 | grep -vE "(No resources found|Warning: Immediate deletion)" || true
    oc delete grafana -n "$NAMESPACE" --all --force --grace-period=0 2>&1 | grep -vE "(No resources found|Warning: Immediate deletion)" || true
    
    # Remove RBAC resources if monitoring type is specified
    if [[ -n "$MONITORING_TYPE" ]] && [[ -n "$rbac_file" ]] && [[ -f "$rbac_file" ]]; then
        log_info "Removing RBAC resources..."
        # Check for ClusterRoleBinding (UWM) or RoleBinding (COO)
        if [[ "$MONITORING_TYPE" == "uwm" ]]; then
            # UWM uses ClusterRoleBinding with exact name
            if oc get clusterrolebinding grafana-prometheus-eip-monitoring &>/dev/null; then
                log_info "Deleting ClusterRoleBinding: grafana-prometheus-eip-monitoring"
                oc delete clusterrolebinding grafana-prometheus-eip-monitoring 2>&1 | grep -vE "(not found|No resources found)" || true
            fi
        elif [[ "$MONITORING_TYPE" == "coo" ]]; then
            # COO uses RoleBinding and Role with exact names
            if oc get rolebinding grafana-prometheus-coo -n "$NAMESPACE" &>/dev/null; then
                log_info "Deleting RoleBinding: grafana-prometheus-coo"
                oc delete rolebinding grafana-prometheus-coo -n "$NAMESPACE" 2>&1 | grep -vE "(not found|No resources found)" || true
            fi
            if oc get role grafana-prometheus-coo -n "$NAMESPACE" &>/dev/null; then
                log_info "Deleting Role: grafana-prometheus-coo"
                oc delete role grafana-prometheus-coo -n "$NAMESPACE" 2>&1 | grep -vE "(not found|No resources found)" || true
            fi
        fi
        
        # Delete ServiceAccount
        if [[ -n "$service_account_name" ]]; then
            log_info "Deleting ServiceAccount: $service_account_name"
            oc delete serviceaccount "$service_account_name" -n "$NAMESPACE" 2>&1 | grep -vE "(not found|No resources found)" || true
        fi
    else
        log_warn "Monitoring type not specified or RBAC file not found, skipping RBAC cleanup"
        log_info "You may need to manually remove RBAC resources"
    fi
    
    log_success "Grafana resources removed"
    echo ""
}

# Remove Grafana Operator subscription
remove_grafana_operator() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Removing Grafana Operator subscription..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Remove Grafana operator subscription (cluster-scoped)
    if oc get subscription grafana-operator -n openshift-operators &>/dev/null; then
        log_info "Removing Grafana Operator subscription (cluster-scoped)..."
        oc delete subscription grafana-operator -n openshift-operators 2>/dev/null || {
            log_warn "Failed to delete Grafana operator subscription (may require cluster-admin)"
        }
        
        # Wait for CSV to be removed, or delete it directly if stuck
        log_info "Waiting for Grafana operator CSV to be removed..."
        local max_wait=30
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local csv_info=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | "\(.metadata.name)|\(.metadata.deletionTimestamp // "active")"' | head -1 || echo "")
            if [[ -z "$csv_info" ]]; then
                log_success "Grafana operator removed"
                break
            fi
            
            # Check if CSV is being deleted
            local csv_name=$(echo "$csv_info" | cut -d'|' -f1)
            local deletion_status=$(echo "$csv_info" | cut -d'|' -f2)
            
            if [[ "$deletion_status" != "active" ]]; then
                log_info "Grafana operator CSV is being deleted (deletionTimestamp: $deletion_status), waiting..."
            fi
            
            sleep 2
            waited=$((waited + 2))
        done
        
        # If CSV still exists after waiting, try to delete it directly
        local remaining_csv=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .metadata.name' | head -1 || echo "")
        if [[ -n "$remaining_csv" ]]; then
            log_warn "Grafana operator CSV still exists after subscription deletion, deleting CSV directly..."
            oc delete csv "$remaining_csv" -n openshift-operators --force --grace-period=0 2>/dev/null || {
                log_warn "Failed to delete Grafana operator CSV directly (may require cluster-admin or CSV may be stuck)"
            }
            
            # Remove finalizers if CSV is stuck
            local csv_finalizers=$(oc get csv "$remaining_csv" -n openshift-operators -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
            if [[ -n "$csv_finalizers" ]]; then
                log_info "Removing finalizers from Grafana operator CSV..."
                oc patch csv "$remaining_csv" -n openshift-operators -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            fi
        else
            log_success "Grafana operator removed successfully"
        fi
    else
        log_info "Grafana operator subscription (cluster-scoped) not found"
    fi
    
    # Also check for namespace-scoped Grafana operator
    if oc get subscription grafana-operator -n "$NAMESPACE" &>/dev/null; then
        log_info "Removing namespace-scoped Grafana Operator subscription..."
        oc delete subscription grafana-operator -n "$NAMESPACE" 2>/dev/null || true
        
        # Wait for CSV to be removed
        log_info "Waiting for namespace-scoped Grafana operator CSV to be removed..."
        local max_wait=30
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local csv_exists=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .metadata.name' | head -1 || echo "")
            if [[ -z "$csv_exists" ]]; then
                log_success "Namespace-scoped Grafana operator removed"
                break
            fi
            sleep 2
            waited=$((waited + 2))
        done
        
        if [[ $waited -ge $max_wait ]]; then
            log_warn "Namespace-scoped Grafana operator removal may still be in progress"
        fi
    else
        log_info "Namespace-scoped Grafana operator subscription not found"
    fi
    
    # Check for CSV in namespace even if subscription is missing (orphaned operator)
    local namespace_csv=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .metadata.name' | head -1 || echo "")
    if [[ -n "$namespace_csv" ]]; then
        log_warn "Found Grafana operator CSV '$namespace_csv' in namespace (may be orphaned)"
        log_info "Deleting CSV directly..."
        oc delete csv "$namespace_csv" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || {
            log_warn "Failed to delete CSV directly, removing finalizers..."
            local csv_finalizers=$(oc get csv "$namespace_csv" -n "$NAMESPACE" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
            if [[ -n "$csv_finalizers" ]]; then
                oc patch csv "$namespace_csv" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                sleep 2
                oc delete csv "$namespace_csv" -n "$NAMESPACE" --force --grace-period=0 2>/dev/null || true
            fi
        }
    fi
    
    # Delete operator deployment and related resources if they still exist
    if oc get deployment grafana-operator-controller-manager -n "$NAMESPACE" &>/dev/null || \
       oc get deployment -n "$NAMESPACE" 2>/dev/null | grep -q "grafana-operator"; then
        log_info "Removing Grafana operator deployment and related resources..."
        # Find the exact deployment name
        local operator_deployment=$(oc get deployment -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .metadata.name' | head -1 || echo "")
        if [[ -n "$operator_deployment" ]]; then
            log_info "Deleting deployment: $operator_deployment"
            oc delete deployment "$operator_deployment" -n "$NAMESPACE" --force --grace-period=0 2>&1 | grep -vE "(Warning: Immediate deletion)" || true
        fi
        
        # Delete service
        local operator_service=$(oc get service -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .metadata.name' | head -1 || echo "")
        if [[ -n "$operator_service" ]]; then
            log_info "Deleting service: $operator_service"
            oc delete service "$operator_service" -n "$NAMESPACE" 2>&1 | grep -vE "(not found|No resources found)" || true
        fi
        
        # Delete replicaset
        oc delete replicaset -n "$NAMESPACE" -l app.kubernetes.io/name=grafana-operator --force --grace-period=0 2>&1 | grep -vE "(not found|No resources found|Warning: Immediate deletion)" || true
        
        # Delete pods
        oc delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=grafana-operator --force --grace-period=0 2>&1 | grep -vE "(not found|No resources found|Warning: Immediate deletion)" || true
    fi
    
    # Optionally delete Grafana CRDs if they still exist (requires cluster-admin)
    # Note: CRDs are typically cleaned up by the operator, but may remain if operator cleanup fails
    # CRDs must be deleted AFTER all resources using them are deleted and operator is removed
    if [[ "${DELETE_CRDS:-false}" == "true" ]]; then
        log_info "Deleting Grafana CRDs (requires cluster-admin permissions)..."
        
        # Wait a bit for operator to clean up CRDs automatically
        log_info "Waiting for operator to clean up CRDs (if supported)..."
        sleep 5
        
        local grafana_crds=(
            "grafanas.integreatly.org"
            "grafanadashboards.integreatly.org"
            "grafanadatasources.integreatly.org"
        )
        
        for crd in "${grafana_crds[@]}"; do
            if oc get crd "$crd" &>/dev/null; then
                log_info "Deleting CRD: $crd..."
                oc delete crd "$crd" 2>&1 | grep -vE "(not found|No resources found)" || log_warn "Failed to delete CRD: $crd (may require cluster-admin or CRD may be in use)"
            fi
        done
        
        log_success "Grafana CRD deletion completed"
    else
        log_info "Grafana CRDs will not be deleted (operator should clean them up automatically)"
        log_info "To force CRD deletion, use: $0 --all --monitoring-type <coo|uwm> --delete-crds"
        log_info "Note: CRD deletion requires cluster-admin permissions"
    fi
    
    log_success "Grafana Operator removal completed"
    echo ""
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -t|--monitoring-type)
                MONITORING_TYPE="$2"
                shift 2
                ;;
            -r|--remove)
                REMOVE_GRAFANA="true"
                shift
                ;;
            --remove-operator)
                REMOVE_OPERATOR="true"
                shift
                ;;
            --delete-crds)
                DELETE_CRDS="true"
                shift
                ;;
            --all)
                REMOVE_GRAFANA="true"
                REMOVE_OPERATOR="true"
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
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    log_info "Namespace: $NAMESPACE"
    
    # Handle removal
    if [[ "$REMOVE_GRAFANA" == "true" ]]; then
        # Validate --delete-crds is only used with --remove-operator or --all
        if [[ "$DELETE_CRDS" == "true" ]] && [[ "$REMOVE_OPERATOR" != "true" ]]; then
            log_error "--delete-crds requires --remove-operator or --all"
            log_error "CRDs can only be deleted when the operator is removed"
            show_usage
            exit 1
        fi
        
        # Monitoring type is helpful for RBAC cleanup but not strictly required
        if [[ -z "$MONITORING_TYPE" ]]; then
            log_warn "Monitoring type not specified for removal"
            log_info "Will attempt to remove all Grafana resources, but RBAC cleanup may be incomplete"
        elif [[ "$MONITORING_TYPE" != "coo" ]] && [[ "$MONITORING_TYPE" != "uwm" ]]; then
            log_error "Invalid monitoring type: $MONITORING_TYPE. Must be 'coo' or 'uwm'"
            show_usage
            exit 1
        fi
        
        log_info "Monitoring type: ${MONITORING_TYPE:-not specified}"
        remove_grafana
        
        if [[ "$REMOVE_OPERATOR" == "true" ]]; then
            remove_grafana_operator
        fi
        
        log_success "Grafana cleanup completed!"
        return 0
    fi
    
    # Validate monitoring type for deployment
    if [[ -z "$MONITORING_TYPE" ]]; then
        log_error "Monitoring type is required for deployment. Use --monitoring-type coo or --monitoring-type uwm"
        show_usage
        exit 1
    fi
    
    if [[ "$MONITORING_TYPE" != "coo" ]] && [[ "$MONITORING_TYPE" != "uwm" ]]; then
        log_error "Invalid monitoring type: $MONITORING_TYPE. Must be 'coo' or 'uwm'"
        show_usage
        exit 1
    fi
    
    log_info "Monitoring type: $MONITORING_TYPE"
    
    deploy_grafana
    
    log_success "Grafana deployment completed!"
    log_info "Grafana resources status:"
    oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>/dev/null || log_info "  (Resources may still be initializing)"
}

# Run main function
main "$@"

