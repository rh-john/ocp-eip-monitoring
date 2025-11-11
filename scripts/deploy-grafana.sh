#!/bin/bash
#
# Deploy Grafana Operator and Dashboards for EIP Monitoring
# This script is completely independent and can be used standalone
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"
REMOVE_GRAFANA="${REMOVE_GRAFANA:-false}"

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
  --remove                   Remove Grafana resources (Grafana instances, dashboards, datasources)
  --remove-operator          Also remove Grafana Operator subscription (requires --remove)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
  REMOVE_GRAFANA            Set to 'true' to remove Grafana resources
  REMOVE_OPERATOR           Set to 'true' to also remove Grafana Operator subscription

Examples:
  $0
  $0 -n my-namespace
  $0 --remove
  $0 --remove --remove-operator

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
        
        if oc apply -f k8s/grafana/grafana-operator.yaml &>/dev/null; then
            log_success "Grafana Operator subscription and OperatorGroup created"
            log_info "Waiting for Grafana Operator to be installed (this may take a few minutes)..."
            
            # Wait for CSV to succeed or CRD to be available
            local max_wait=300
            local waited=0
            while [[ $waited -lt $max_wait ]]; do
                csv_phase=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .status.phase' | head -1 || echo "")
                
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

# Remove Grafana resources
remove_grafana() {
    log_info "Removing Grafana resources from namespace $NAMESPACE..."
    
    # Check for multiple OperatorGroups before cleanup (may affect removal)
    local operatorgroup_count=$(oc get operatorgroup -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "$operatorgroup_count" -gt 1 ]]; then
        log_warn "Multiple OperatorGroups found in namespace $NAMESPACE"
        log_info "This may affect operator cleanup. Checking OperatorGroups..."
        local operatorgroups=$(oc get operatorgroup -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        log_info "Found OperatorGroups: $operatorgroups"
        
        # Identify which OperatorGroups exist
        local expected_og="eip-monitoring-operatorgroup"
        local has_expected=false
        local duplicate_ogs=()
        
        for og in $operatorgroups; do
            if [[ "$og" == "$expected_og" ]]; then
                has_expected=true
            else
                duplicate_ogs+=("$og")
            fi
        done
        
        if [[ ${#duplicate_ogs[@]} -gt 0 ]]; then
            log_warn "Found duplicate OperatorGroups: ${duplicate_ogs[*]}"
            log_info "These will be cleaned up after removing the subscription"
        fi
    fi
    
    # Delete Grafana instances
    log_info "Removing Grafana instances..."
    local grafana_instances=$(oc get grafana -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$grafana_instances" ]]; then
        for instance in $grafana_instances; do
            log_info "  Deleting Grafana instance: $instance"
            oc delete grafana "$instance" -n "$NAMESPACE" --wait=true 2>/dev/null || log_warn "Failed to delete Grafana instance: $instance"
        done
    else
        log_info "  No Grafana instances found"
    fi
    
    # Delete Grafana dashboards
    log_info "Removing Grafana dashboards..."
    local dashboards=$(oc get grafanadashboard -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$dashboards" ]]; then
        for dashboard in $dashboards; do
            log_info "  Deleting dashboard: $dashboard"
            oc delete grafanadashboard "$dashboard" -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete dashboard: $dashboard"
        done
    else
        log_info "  No Grafana dashboards found"
    fi
    
    # Delete Grafana datasources
    log_info "Removing Grafana datasources..."
    local datasources=$(oc get grafanadatasource -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$datasources" ]]; then
        for datasource in $datasources; do
            log_info "  Deleting datasource: $datasource"
            oc delete grafanadatasource "$datasource" -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete datasource: $datasource"
        done
    else
        log_info "  No Grafana datasources found"
    fi
    
    # Delete RBAC resources
    log_info "Removing Grafana RBAC resources..."
    if oc get serviceaccount grafana-prometheus -n "$NAMESPACE" &>/dev/null; then
        log_info "  Deleting ServiceAccount: grafana-prometheus"
        oc delete serviceaccount grafana-prometheus -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete ServiceAccount"
    fi
    
    if oc get clusterrolebinding grafana-prometheus &>/dev/null; then
        log_info "  Deleting ClusterRoleBinding: grafana-prometheus"
        oc delete clusterrolebinding grafana-prometheus 2>/dev/null || log_warn "Failed to delete ClusterRoleBinding"
    fi
    
    # Delete token secrets
    log_info "Removing Grafana token secrets..."
    local token_secrets=$(oc get secret -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.type=="Opaque" and (.metadata.name | contains("grafana") or contains("prometheus"))) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$token_secrets" ]]; then
        for secret in $token_secrets; do
            log_info "  Deleting secret: $secret"
            oc delete secret "$secret" -n "$NAMESPACE" 2>/dev/null || true
        done
    fi
    
    # Remove Grafana Operator subscription if requested
    if [[ "${REMOVE_OPERATOR:-false}" == "true" ]]; then
        log_info "Removing Grafana Operator subscription..."
        
        # Check for subscription
        if oc get subscription grafana-operator -n "$NAMESPACE" &>/dev/null; then
            log_info "  Deleting subscription: grafana-operator"
            oc delete subscription grafana-operator -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete subscription"
            
            # Wait a bit for operator to clean up CSVs
            log_info "Waiting for operator to clean up CSVs..."
            sleep 10
            
            # Delete any orphaned CSVs
            local csvs=$(oc get csv -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("grafana-operator")) | .metadata.name' 2>/dev/null || echo "")
            if [[ -n "$csvs" ]]; then
                for csv in $csvs; do
                    log_info "  Deleting CSV: $csv"
                    # Remove finalizers if present
                    oc patch csv "$csv" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
                    oc delete csv "$csv" -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete CSV: $csv"
                done
            fi
        else
            log_info "  No Grafana Operator subscription found"
        fi
        
        # Clean up OperatorGroups - check for duplicates and remove appropriately
        log_info "Cleaning up OperatorGroups..."
        local operatorgroups=$(oc get operatorgroup -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$operatorgroups" ]]; then
            # If there are multiple OperatorGroups, identify which ones to delete
            local expected_og="eip-monitoring-operatorgroup"
            local og_list=($operatorgroups)
            
            if [[ ${#og_list[@]} -gt 1 ]]; then
                log_warn "Multiple OperatorGroups found during cleanup: ${og_list[*]}"
                log_info "Removing all OperatorGroups (they can be recreated if needed)..."
                
                for og in "${og_list[@]}"; do
                    log_info "  Deleting OperatorGroup: $og"
                    oc delete operatorgroup "$og" -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete OperatorGroup: $og"
                done
            else
                # Single OperatorGroup - check if it's the expected one or a duplicate
                local og_name="${og_list[0]}"
                log_info "  Deleting OperatorGroup: $og_name"
                oc delete operatorgroup "$og_name" -n "$NAMESPACE" 2>/dev/null || log_warn "Failed to delete OperatorGroup: $og_name"
            fi
        else
            log_info "  No OperatorGroups found"
        fi
        
        # Check for InstallPlans and clean them up
        log_info "Cleaning up InstallPlans..."
        local installplans=$(oc get installplan -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$installplans" ]]; then
            for ip in $installplans; do
                log_info "  Deleting InstallPlan: $ip"
                oc delete installplan "$ip" -n "$NAMESPACE" 2>/dev/null || true
            done
        fi
    else
        log_info "Grafana Operator subscription will be kept (use --remove-operator to remove it)"
    fi
    
    log_success "Grafana resources removed"
    
    # Final check for any remaining resources
    log_info "Checking for remaining Grafana resources..."
    local remaining=$(oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ "$remaining" -gt 0 ]]; then
        log_warn "Some Grafana resources may still exist"
        oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>/dev/null || true
    else
        log_success "All Grafana resources removed successfully"
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --remove)
                REMOVE_GRAFANA="true"
                shift
                ;;
            --remove-operator)
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
    
    if [[ "$REMOVE_GRAFANA" == "true" ]]; then
        log_info "Removing Grafana resources..."
        remove_grafana
        log_success "Grafana removal completed!"
    else
        log_info "Deploying Grafana resources..."
        deploy_grafana
        log_success "Grafana deployment completed!"
        log_info "Grafana resources status:"
        oc get grafana,grafanadatasource,grafanadashboard -n "$NAMESPACE" 2>/dev/null || log_info "  (Resources may still be initializing)"
    fi
}

# Run main function
main "$@"

