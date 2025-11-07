#!/bin/bash
#
# Deploy Monitoring Infrastructure for EIP Monitoring (COO or UWM)
# This script is completely independent and can be used standalone
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"
MONITORING_TYPE="${MONITORING_TYPE:-uwm}"  # Default to uwm
REMOVE_MONITORING="${REMOVE_MONITORING:-false}"
VERBOSE="${VERBOSE:-false}"

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

# Helper function to run oc commands with optional verbose output
oc_cmd() {
    if [[ "$VERBOSE" == "true" ]]; then
        oc "$@"
    else
        oc "$@" 2>/dev/null
    fi
}

# Helper function for oc commands that need to suppress output in non-verbose mode
oc_cmd_silent() {
    if [[ "$VERBOSE" == "true" ]]; then
        oc "$@"
    else
        oc "$@" &>/dev/null
    fi
}

# Show usage
show_usage() {
    cat << EOF
Deploy Monitoring Infrastructure for EIP Monitoring

Usage: $0 [options]

Options:
  -n, --namespace NS        Kubernetes namespace (default: eip-monitoring)
  --monitoring-type TYPE    Monitoring type: coo or uwm (default: uwm)
  --remove-monitoring       Remove monitoring infrastructure
  -v, --verbose            Show verbose output (raw oc command output)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
  MONITORING_TYPE           Monitoring type: coo or uwm (default: uwm)
  REMOVE_MONITORING         Set to true to remove monitoring (default: false)
  VERBOSE                   Set to true to show verbose output (default: false)

Examples:
  $0 --monitoring-type uwm
  $0 --monitoring-type coo -n my-namespace
  $0 --remove-monitoring
  $0 --remove-monitoring --verbose

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

# Enable User Workload Monitoring if not already enabled
enable_user_workload_monitoring() {
    log_info "Checking User Workload Monitoring configuration..."
    
    # Check if cluster-monitoring-config exists
    if ! oc get configmap cluster-monitoring-config -n openshift-monitoring &>/dev/null; then
        log_info "Creating cluster-monitoring-config ConfigMap..."
        oc create configmap cluster-monitoring-config -n openshift-monitoring --from-literal=config.yaml="enableUserWorkload: true" 2>/dev/null || {
            log_error "Failed to create cluster-monitoring-config"
            log_error "This requires cluster-admin permissions"
            return 1
        }
        log_success "Created cluster-monitoring-config with enableUserWorkload: true"
        return 0
    fi
    
    # Get current config
    local cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    # Check if already enabled
    if echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
        log_info "User Workload Monitoring is already enabled"
        return 0
    fi
    
    # Check if config is empty or doesn't have the setting
    if [[ -z "$cluster_config" ]]; then
        log_info "Enabling User Workload Monitoring (empty config)..."
        oc patch configmap cluster-monitoring-config -n openshift-monitoring --type merge -p '{"data":{"config.yaml":"enableUserWorkload: true\n"}}' 2>/dev/null || {
            log_error "Failed to enable User Workload Monitoring"
            log_error "This requires cluster-admin permissions"
            return 1
        }
        log_success "Enabled User Workload Monitoring"
        return 0
    fi
    
    # Config exists but doesn't have enableUserWorkload
    log_info "Enabling User Workload Monitoring (updating existing config)..."
    
    # Use a temporary file to safely update the YAML
    local temp_config=$(mktemp)
    echo "$cluster_config" > "$temp_config"
    local temp_config_new="${temp_config}.new"
    
    # Check if config.yaml already has enableUserWorkload set to false
    if echo "$cluster_config" | grep -qE "enableUserWorkload:\s*false"; then
        # Replace false with true (macOS compatible sed)
        sed 's/enableUserWorkload:[[:space:]]*false/enableUserWorkload: true/g' "$temp_config" > "$temp_config_new"
        mv "$temp_config_new" "$temp_config"
    else
        # Add enableUserWorkload: true to the config
        # Try to add it at the beginning, or append if that fails
        if ! grep -q "enableUserWorkload" "$temp_config"; then
            {
                echo "enableUserWorkload: true"
                cat "$temp_config"
            } > "$temp_config_new"
            mv "$temp_config_new" "$temp_config"
        fi
    fi
    
    # Read the updated config and escape for JSON
    local updated_config=$(cat "$temp_config")
    # Escape JSON special characters
    updated_config=$(echo "$updated_config" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    # Convert newlines to \n for JSON
    updated_config=$(echo "$updated_config" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    
    # Apply the updated config
    oc patch configmap cluster-monitoring-config -n openshift-monitoring --type merge \
        -p "{\"data\":{\"config.yaml\":\"$updated_config\"}}" 2>/dev/null || {
        log_error "Failed to enable User Workload Monitoring"
        log_error "This requires cluster-admin permissions"
        rm -f "$temp_config" "$temp_config_new"
        return 1
    }
    
    rm -f "$temp_config" "$temp_config_new"
    log_success "Enabled User Workload Monitoring"
    log_info "Waiting for User Workload Monitoring to initialize (this may take a few minutes)..."
    
    # Wait for namespace to be created (with timeout)
    local max_wait=300  # 5 minutes
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if oc get namespace openshift-user-workload-monitoring &>/dev/null; then
            log_success "User Workload Monitoring namespace created"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]]; then
            log_info "Still waiting for User Workload Monitoring to initialize... (${waited}s)"
        fi
    done
    
    if [[ $waited -ge $max_wait ]]; then
        log_warn "User Workload Monitoring namespace not created yet (waited ${max_wait}s)"
        log_info "It may take several minutes to fully initialize"
    fi
}

# Enable AlertManager for user workloads
enable_user_workload_alertmanager() {
    log_info "Checking AlertManager configuration for user workloads..."
    
    # Wait for namespace to exist (with timeout)
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if oc get namespace openshift-user-workload-monitoring &>/dev/null; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    if ! oc get namespace openshift-user-workload-monitoring &>/dev/null; then
        log_warn "openshift-user-workload-monitoring namespace not found, skipping AlertManager configuration"
        return 0
    fi
    
    # Check if user-workload-monitoring-config exists
    if ! oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring &>/dev/null; then
        log_info "Creating user-workload-monitoring-config ConfigMap with AlertManager enabled..."
        oc create configmap user-workload-monitoring-config -n openshift-user-workload-monitoring \
            --from-literal=config.yaml="alertmanager:
  enabled: true
  enableAlertmanagerConfig: true" 2>/dev/null || {
            log_error "Failed to create user-workload-monitoring-config"
            log_error "This requires cluster-admin permissions"
            return 1
        }
        log_success "Created user-workload-monitoring-config with AlertManager enabled"
        return 0
    fi
    
    # Get current config
    local uwm_config=$(oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    # Check if AlertManager is already enabled
    if echo "$uwm_config" | grep -qE "alertmanager:\s*enabled:\s*true"; then
        log_info "AlertManager is already enabled for user workloads"
        return 0
    fi
    
    # Check if config is empty
    if [[ -z "$uwm_config" ]]; then
        log_info "Enabling AlertManager for user workloads (empty config)..."
        oc patch configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --type merge \
            -p '{"data":{"config.yaml":"alertmanager:\n  enabled: true\n  enableAlertmanagerConfig: true\n"}}' 2>/dev/null || {
            log_error "Failed to enable AlertManager"
            log_error "This requires cluster-admin permissions"
            return 1
        }
        log_success "Enabled AlertManager for user workloads"
        return 0
    fi
    
    # Config exists but doesn't have AlertManager enabled
    log_info "Enabling AlertManager for user workloads (updating existing config)..."
    
    # Use a temporary file to safely update the YAML
    local temp_config=$(mktemp)
    echo "$uwm_config" > "$temp_config"
    local temp_config_new="${temp_config}.new"
    
    # Check if alertmanager section exists
    if grep -q "^alertmanager:" "$temp_config"; then
        # Update existing alertmanager section
        # Replace enabled: false with enabled: true, or add enabled: true if missing
        if grep -qE "alertmanager:\s*$" "$temp_config" || grep -qE "^\s*enabled:\s*false" "$temp_config"; then
            # Use awk to update the alertmanager section
            awk '
            /^alertmanager:/ { 
                print; 
                getline; 
                if ($0 ~ /^[[:space:]]*enabled:/) {
                    print "  enabled: true"
                    if ($0 !~ /enableAlertmanagerConfig/) {
                        print "  enableAlertmanagerConfig: true"
                    }
                } else {
                    print "  enabled: true"
                    print "  enableAlertmanagerConfig: true"
                    print $0
                }
                next
            }
            { print }
            ' "$temp_config" > "$temp_config_new"
            mv "$temp_config_new" "$temp_config"
        else
            # AlertManager section exists but enabled might be missing or true already
            # Just ensure enableAlertmanagerConfig is set
            if ! grep -q "enableAlertmanagerConfig" "$temp_config"; then
                sed '/^alertmanager:/a\
  enableAlertmanagerConfig: true' "$temp_config" > "$temp_config_new"
                mv "$temp_config_new" "$temp_config"
            fi
        fi
    else
        # Add alertmanager section
        {
            echo "alertmanager:"
            echo "  enabled: true"
            echo "  enableAlertmanagerConfig: true"
            echo ""
            cat "$temp_config"
        } > "$temp_config_new"
        mv "$temp_config_new" "$temp_config"
    fi
    
    # Read the updated config and escape for JSON
    local updated_config=$(cat "$temp_config")
    # Escape JSON special characters
    updated_config=$(echo "$updated_config" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    # Convert newlines to \n for JSON
    updated_config=$(echo "$updated_config" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    
    # Apply the updated config
    oc patch configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --type merge \
        -p "{\"data\":{\"config.yaml\":\"$updated_config\"}}" 2>/dev/null || {
        log_error "Failed to enable AlertManager"
        log_error "This requires cluster-admin permissions"
        rm -f "$temp_config" "$temp_config_new"
        return 1
    }
    
    rm -f "$temp_config" "$temp_config_new"
    log_success "Enabled AlertManager for user workloads"
    log_info "AlertManager pods will start shortly (may take a few minutes)"
}

# Detect currently installed monitoring type
detect_current_monitoring_type() {
    # Check for COO resources in the namespace (MonitoringStack, ServiceMonitor with COO labels, etc.)
    # Use --no-headers and check for actual output to ensure resources exist
    if (oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .); then
        echo "coo"
        return 0
    fi
    
    # Check for COO ServiceMonitor
    if (oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .); then
        echo "coo"
        return 0
    fi
    
    # Check for COO operator subscription (fallback check)
    if (oc get subscription cluster-observability-operator -n openshift-operators --no-headers 2>/dev/null | grep -q .); then
        # Only return COO if we also have COO resources, otherwise might be unused operator
        if (oc get servicemonitor -n "$NAMESPACE" -l coo=eip-monitoring --no-headers 2>/dev/null | grep -q .) || \
           (oc get prometheusrule -n "$NAMESPACE" -l coo=eip-monitoring --no-headers 2>/dev/null | grep -q .); then
            echo "coo"
            return 0
        fi
    fi
    
    # Check for UWM resources in namespace first (most reliable indicator)
    # Only detect UWM if actual resources exist, not just based on cluster config
    # Use --no-headers and check for actual output to ensure resources exist
    if (oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .) || \
       (oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .) || \
       (oc get prometheusrule -n "$NAMESPACE" -l monitoring=uwm --no-headers 2>/dev/null | grep -q .) || \
       (oc get networkpolicy eip-monitor-uwm -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .); then
        echo "uwm"
        return 0
    fi
    
    echo "none"
    return 0
}

# Install COO operator
install_coo_operator() {
    log_info "Installing Cluster Observability Operator..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local subscription_file="${project_root}/k8s/monitoring/coo/operator/coo-operator-subscription.yaml"
    
    if [[ ! -f "$subscription_file" ]]; then
        log_error "COO operator subscription file not found: $subscription_file"
        return 1
    fi
    
    oc apply -f "$subscription_file" || {
        log_error "Failed to install COO operator subscription"
        log_error "This requires cluster-admin permissions"
        return 1
    }
    
    log_success "COO operator subscription created"
    log_info "Waiting for COO operator to be installed (this may take a few minutes)..."
    
    # Wait for CSV to succeed
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local csv_phase=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("cluster-observability")) | .status.phase' | head -1 || echo "")
        if [[ "$csv_phase" == "Succeeded" ]]; then
            log_success "COO operator installed successfully"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]]; then
            log_info "Still waiting for COO operator... (${waited}s, CSV phase: ${csv_phase:-none})"
        fi
    done
    
    if [[ $waited -ge $max_wait ]]; then
        log_warn "COO operator may not be fully ready yet (waited ${max_wait}s)"
    fi
}

# Configure COO monitoring stack
configure_coo_monitoring_stack() {
    log_info "Deploying COO MonitoringStack..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local monitoringstack_file="${project_root}/k8s/monitoring/coo/monitoring/coo-monitoringstack.yaml"
    
    if [[ ! -f "$monitoringstack_file" ]]; then
        log_error "COO MonitoringStack file not found: $monitoringstack_file"
        return 1
    fi
    
    oc apply -f "$monitoringstack_file" || {
        log_error "Failed to deploy COO MonitoringStack"
        return 1
    }
    
    log_success "COO MonitoringStack deployed"
    log_info "Waiting for COO Prometheus and Alertmanager to be ready (this may take a few minutes)..."
    
    # Wait for Prometheus pods
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local prom_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || echo "0")
        prom_pods=$(echo "$prom_pods" | tr -d '[:space:]')
        if [[ "$prom_pods" =~ ^[0-9]+$ ]] && [[ "$prom_pods" -gt 0 ]]; then
            log_success "COO Prometheus pods are running"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]]; then
            log_info "Still waiting for COO Prometheus... (${waited}s)"
        fi
    done
}

# Remove COO monitoring
remove_coo_monitoring() {
    log_info "Removing COO monitoring infrastructure..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # Delete MonitoringStack
    if oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting COO MonitoringStack..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete monitoringstack eip-monitoring-stack -n "$NAMESPACE" --wait=true || log_warn "Failed to delete MonitoringStack"
        else
            oc delete monitoringstack eip-monitoring-stack -n "$NAMESPACE" --wait=true &>/dev/null || log_warn "Failed to delete MonitoringStack"
        fi
    fi
    
    # Delete COO manifests
    log_info "Removing COO manifests..."
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml" || true
        oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml" || true
        oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/networkpolicy-coo.yaml" || true
        oc delete -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml" || true
    else
        oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml" &>/dev/null || true
        oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml" &>/dev/null || true
        oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/networkpolicy-coo.yaml" &>/dev/null || true
        oc delete -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml" &>/dev/null || true
    fi
    
    # Delete COO operator subscription
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        log_info "Deleting COO operator subscription..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete subscription cluster-observability-operator -n openshift-operators || log_warn "Failed to delete COO operator subscription"
        else
            oc delete subscription cluster-observability-operator -n openshift-operators &>/dev/null || log_warn "Failed to delete COO operator subscription"
        fi
    fi
    
    # Delete ThanosQuerier
    if oc get thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting COO ThanosQuerier..."
        oc delete thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" 2>/dev/null || true
    fi
    
    log_success "COO monitoring infrastructure removed"
}

# Remove UWM monitoring
remove_uwm_monitoring() {
    log_info "Removing UWM monitoring infrastructure..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # Verify UWM resources actually exist before attempting removal
    local has_uwm_resources=false
    if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null || \
       oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null || \
       oc get networkpolicy eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
        has_uwm_resources=true
    fi
    
    if [[ "$has_uwm_resources" == "false" ]]; then
        log_info "No UWM resources found in namespace, skipping removal"
        return 0
    fi
    
    # Delete UWM manifests
    log_info "Removing UWM manifests..."
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml" || true
        oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml" || true
        oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml" || true
        oc delete -f "${project_root}/k8s/monitoring/uwm/rbac/grafana-rbac-uwm.yaml" || true
    else
        oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml" &>/dev/null || true
        oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml" &>/dev/null || true
        oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml" &>/dev/null || true
        oc delete -f "${project_root}/k8s/monitoring/uwm/rbac/grafana-rbac-uwm.yaml" &>/dev/null || true
    fi
    
    # Disable UWM in cluster-monitoring-config
    log_info "Disabling User Workload Monitoring..."
    local cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    if [[ -n "$cluster_config" ]] && echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
        # Remove or set to false
        local temp_config=$(mktemp)
        echo "$cluster_config" > "$temp_config"
        sed 's/enableUserWorkload:[[:space:]]*true/enableUserWorkload: false/g' "$temp_config" > "${temp_config}.new"
        mv "${temp_config}.new" "$temp_config"
        
        local updated_config=$(cat "$temp_config")
        updated_config=$(echo "$updated_config" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
        updated_config=$(echo "$updated_config" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
        
        if [[ "$VERBOSE" == "true" ]]; then
            oc patch configmap cluster-monitoring-config -n openshift-monitoring --type merge \
                -p "{\"data\":{\"config.yaml\":\"$updated_config\"}}" || {
                log_warn "Failed to disable UWM in cluster-monitoring-config"
            }
        else
            oc patch configmap cluster-monitoring-config -n openshift-monitoring --type merge \
                -p "{\"data\":{\"config.yaml\":\"$updated_config\"}}" &>/dev/null || {
                log_warn "Failed to disable UWM in cluster-monitoring-config"
            }
        fi
        rm -f "$temp_config"
    fi
    
    # Delete user-workload-monitoring-config
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring || true
    else
        oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring &>/dev/null || true
    fi
    
    log_success "UWM monitoring infrastructure removed"
}

# Deploy monitoring infrastructure
deploy_monitoring() {
    # Check OpenShift connectivity
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        exit 1
    fi
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    
    # Validate monitoring type
    if [[ "$MONITORING_TYPE" != "coo" ]] && [[ "$MONITORING_TYPE" != "uwm" ]]; then
        log_error "Invalid monitoring type: $MONITORING_TYPE. Must be 'coo' or 'uwm'"
        exit 1
    fi
    
    # Detect current monitoring type
    local current_type=$(detect_current_monitoring_type)
    
    # If removing monitoring
    if [[ "$REMOVE_MONITORING" == "true" ]]; then
        if [[ "$current_type" == "none" ]]; then
            log_warn "No monitoring infrastructure detected to remove"
            return 0
        fi
        
        if [[ "$current_type" == "coo" ]]; then
            remove_coo_monitoring
        elif [[ "$current_type" == "uwm" ]]; then
            remove_uwm_monitoring
        fi
        return 0
    fi
    
    # If switching types, remove current first
    if [[ "$current_type" != "none" ]] && [[ "$current_type" != "$MONITORING_TYPE" ]]; then
        log_warn "Detected $current_type monitoring, but requested $MONITORING_TYPE"
        log_info "Removing existing $current_type monitoring before installing $MONITORING_TYPE..."
        if [[ "$current_type" == "coo" ]]; then
            remove_coo_monitoring
        elif [[ "$current_type" == "uwm" ]]; then
            remove_uwm_monitoring
        fi
        sleep 10  # Wait a bit before installing new type
    fi
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        log_info "Deploying COO monitoring infrastructure..."
        
        # Install COO operator
        install_coo_operator
        
        # Configure monitoring stack
        configure_coo_monitoring_stack
        
        # Apply COO manifests
        log_info "Applying COO monitoring manifests..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml"
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml"
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/networkpolicy-coo.yaml"
            oc apply -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml"
        else
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/networkpolicy-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml" 2>/dev/null
        fi
        
        log_success "COO monitoring infrastructure deployed!"
        
    elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
        log_info "Deploying UWM monitoring infrastructure..."
        
        # Enable UWM
        enable_user_workload_monitoring
        enable_user_workload_alertmanager
        
        # Apply UWM manifests
        log_info "Applying UWM monitoring manifests..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml"
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml"
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml"
            oc apply -f "${project_root}/k8s/monitoring/uwm/rbac/grafana-rbac-uwm.yaml"
        else
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/uwm/rbac/grafana-rbac-uwm.yaml" 2>/dev/null
        fi
        
        log_success "UWM monitoring infrastructure deployed!"
    fi
    
    log_info "Monitoring infrastructure status:"
    if [[ "$VERBOSE" == "true" ]]; then
        local status_output=$(oc get servicemonitor,prometheusrule -n "$NAMESPACE" 2>&1)
    else
        local status_output=$(oc get servicemonitor,prometheusrule -n "$NAMESPACE" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$status_output" ]] || echo "$status_output" | grep -qiE "(no resources found|not found)"; then
        log_info "  (Resources may still be initializing)"
    else
        echo "$status_output" | sed 's/^/  /'
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
            --monitoring-type)
                MONITORING_TYPE="$2"
                shift 2
                ;;
            --remove-monitoring)
                REMOVE_MONITORING="true"
                shift
                ;;
            -v|--verbose)
                VERBOSE="true"
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
    log_info "Deploying to namespace: $NAMESPACE"
    
    # If removing, detect the actual type first and log it
    if [[ "$REMOVE_MONITORING" == "true" ]]; then
        local detected_type=$(detect_current_monitoring_type)
        if [[ "$detected_type" != "none" ]]; then
            log_info "Detected monitoring type: $detected_type"
        else
            log_info "Monitoring type: (none detected)"
        fi
    else
        log_info "Monitoring type: $MONITORING_TYPE"
    fi
    
    deploy_monitoring
    
    log_success "Monitoring deployment completed!"
    log_info "Monitoring infrastructure status:"
    if [[ "$VERBOSE" == "true" ]]; then
        local status_output=$(oc get servicemonitor,prometheusrule -n "$NAMESPACE" 2>&1)
    else
        local status_output=$(oc get servicemonitor,prometheusrule -n "$NAMESPACE" 2>/dev/null || echo "")
    fi
    
    if [[ "$REMOVE_MONITORING" == "true" ]]; then
        # Check if output is empty or contains "No resources found"
        if [[ -z "$status_output" ]] || echo "$status_output" | grep -qiE "(no resources found|not found)"; then
            log_success "  ✓ No monitoring resources found (removed successfully)"
        else
            if [[ "$VERBOSE" == "true" ]]; then
                echo "$status_output" | sed 's/^/  /'
            else
                echo "$status_output" | sed 's/^/  /'
            fi
        fi
    else
        if [[ -z "$status_output" ]] || echo "$status_output" | grep -qiE "(no resources found|not found)"; then
            log_info "  (Resources may still be initializing)"
        else
            echo "$status_output" | sed 's/^/  /'
        fi
    fi
}

# Run main function only if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

