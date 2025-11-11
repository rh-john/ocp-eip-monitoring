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
PERSISTENT="${PERSISTENT:-false}"  # Enable persistent storage using default storage class
DELETE_PERSISTENT_STORAGE="${DELETE_PERSISTENT_STORAGE:-false}"  # Delete persistent storage during cleanup
UWM_STORAGE_CLASS="${UWM_STORAGE_CLASS:-}"  # Optional: storage class for UWM Prometheus
UWM_STORAGE_SIZE="${UWM_STORAGE_SIZE:-50Gi}"  # Default storage size for UWM Prometheus
COO_STORAGE_CLASS="${COO_STORAGE_CLASS:-}"  # Optional: storage class for COO Prometheus
COO_STORAGE_SIZE="${COO_STORAGE_SIZE:-50Gi}"  # Default storage size for COO Prometheus

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
  --persistent              Enable persistent storage using default storage class (for both COO and UWM)
  --delete-persistent-storage Delete persistent volumes (PVCs) during cleanup (use with --remove-monitoring)
  --uwm-storage-class CLASS Storage class for UWM Prometheus persistent storage (optional)
  --uwm-storage-size SIZE   Storage size for UWM Prometheus (default: 50Gi)
  --coo-storage-class CLASS Storage class for COO Prometheus persistent storage (optional)
  --coo-storage-size SIZE   Storage size for COO Prometheus (default: 50Gi)
  -v, --verbose            Show verbose output (raw oc command output)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
  MONITORING_TYPE           Monitoring type: coo or uwm (default: uwm)
  REMOVE_MONITORING         Set to true to remove monitoring (default: false)
  PERSISTENT                Set to true to enable persistent storage using default storage class
  DELETE_PERSISTENT_STORAGE Set to true to delete persistent volumes during cleanup
  UWM_STORAGE_CLASS         Storage class for UWM Prometheus persistent storage (optional)
  UWM_STORAGE_SIZE          Storage size for UWM Prometheus (default: 50Gi)
  COO_STORAGE_CLASS         Storage class for COO Prometheus persistent storage (optional)
  COO_STORAGE_SIZE          Storage size for COO Prometheus (default: 50Gi)
  VERBOSE                   Set to true to show verbose output (default: false)

Examples:
  $0 --monitoring-type uwm
  $0 --monitoring-type coo -n my-namespace
  $0 --monitoring-type uwm --persistent
  $0 --monitoring-type coo --persistent
  $0 --monitoring-type uwm --uwm-storage-class managed-premium --uwm-storage-size 100Gi
  $0 --monitoring-type coo --coo-storage-class managed-premium --coo-storage-size 100Gi
  $0 --remove-monitoring
  $0 --remove-monitoring --delete-persistent-storage
  $0 --remove-monitoring --verbose

Note: To deploy both COO and UWM simultaneously:
  1. Deploy COO: $0 --monitoring-type coo
  2. Deploy UWM: $0 --monitoring-type uwm
  3. Apply combined NetworkPolicy: oc apply -f k8s/monitoring/networkpolicy-combined.yaml
     (This replaces the individual NetworkPolicies to avoid conflicts)

Note on Persistent Storage:
  By default, both COO and UWM Prometheus use ephemeral storage (emptyDir). For production,
  use --persistent to automatically configure persistent storage using the default storage class,
  or specify a storage class explicitly using --coo-storage-class or --uwm-storage-class.
  
  When removing monitoring, use --delete-persistent-storage to also delete the persistent
  volume claims (PVCs). By default, PVCs are retained to preserve data.

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

# Configure persistent storage for UWM Prometheus (optional)
configure_uwm_persistent_storage() {
    local storage_class="${1:-}"
    local storage_size="${2:-50Gi}"
    
    log_info "Checking persistent storage configuration for UWM Prometheus..."
    
    # Wait for namespace to exist
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
        log_warn "openshift-user-workload-monitoring namespace not found, skipping persistent storage configuration"
        return 0
    fi
    
    # Get current config
    local uwm_config=$(oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    # Check if persistent storage is already configured
    if echo "$uwm_config" | grep -A10 "^prometheus:" | grep -qE "volumeClaimTemplate|retention:"; then
        log_info "Persistent storage is already configured for UWM Prometheus"
        return 0
    fi
    
    # If --persistent flag is set and no storage class specified, detect default
    if [[ "$PERSISTENT" == "true" ]] && [[ -z "$storage_class" ]]; then
        log_info "Detecting default storage class for UWM..."
        storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        
        if [[ -z "$storage_class" ]]; then
            # Try alternative annotation
            storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        fi
        
        if [[ -z "$storage_class" ]]; then
            log_warn "No default storage class found. Persistent storage will not be configured."
            log_info "Specify a storage class explicitly using --uwm-storage-class"
            return 0
        else
            log_info "Using detected default storage class: $storage_class"
        fi
    fi
    
    # If storage_class is not provided and --persistent is not set, try to detect a default storage class
    if [[ -z "$storage_class" ]] && [[ "$PERSISTENT" != "true" ]]; then
        log_info "Detecting default storage class..."
        storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        
        if [[ -z "$storage_class" ]]; then
            # Try alternative annotation
            storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        fi
        
        if [[ -z "$storage_class" ]]; then
            log_warn "No default storage class found. Persistent storage will not be configured."
            log_info "To configure persistent storage manually, edit user-workload-monitoring-config ConfigMap:"
            log_info "  oc edit configmap user-workload-monitoring-config -n openshift-user-workload-monitoring"
            log_info "Add:"
            log_info "  prometheus:"
            log_info "    volumeClaimTemplate:"
            log_info "      spec:"
            log_info "        storageClassName: <your-storage-class>"
            log_info "        resources:"
            log_info "          requests:"
            log_info "            storage: ${storage_size}"
            return 0
        fi
        
        log_info "Using storage class: $storage_class"
    fi
    
    log_info "Configuring persistent storage for UWM Prometheus (${storage_size})..."
    
    # Create or update config
    local temp_config=$(mktemp)
    local temp_yaml=$(mktemp)
    
    if [[ -z "$uwm_config" ]]; then
        # Create new config
        cat > "$temp_config" <<EOF
alertmanager:
  enabled: true
  enableAlertmanagerConfig: true
prometheus:
  volumeClaimTemplate:
    spec:
      storageClassName: ${storage_class}
      resources:
        requests:
          storage: ${storage_size}
EOF
    else
        # Update existing config
        echo "$uwm_config" > "$temp_config"
        
        # Check if prometheus section exists
        if grep -q "^prometheus:" "$temp_config"; then
            # Update existing prometheus section
            local temp_updated=$(mktemp)
            if grep -A20 "^prometheus:" "$temp_config" | grep -q "volumeClaimTemplate"; then
                log_info "Prometheus volumeClaimTemplate already exists, skipping"
                rm -f "$temp_config" "$temp_yaml"
                return 0
            else
                # Add volumeClaimTemplate to existing prometheus section
                awk '
                /^prometheus:/ {
                    print
                    print "  volumeClaimTemplate:"
                    print "    spec:"
                    print "      storageClassName: '"${storage_class}"'"
                    print "      resources:"
                    print "        requests:"
                    print "          storage: '"${storage_size}"'"
                    next
                }
                { print }
                ' "$temp_config" > "$temp_updated"
                mv "$temp_updated" "$temp_config"
            fi
        else
            # Add prometheus section
            {
                echo "$uwm_config"
                echo ""
                echo "prometheus:"
                echo "  volumeClaimTemplate:"
                echo "    spec:"
                echo "      storageClassName: ${storage_class}"
                echo "      resources:"
                echo "        requests:"
                echo "          storage: ${storage_size}"
            } > "${temp_config}.new"
            mv "${temp_config}.new" "$temp_config"
        fi
    fi
    
    # Create ConfigMap YAML
    cat > "$temp_yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
$(sed 's/^/    /' "$temp_config")
EOF
    
    # Apply the config
    if [[ "$VERBOSE" == "true" ]]; then
        oc apply -f "$temp_yaml" || {
            log_error "Failed to configure persistent storage"
            rm -f "$temp_config" "$temp_yaml"
            return 1
        }
    else
        oc apply -f "$temp_yaml" &>/dev/null || {
            log_error "Failed to configure persistent storage"
            log_info "Run with --verbose to see detailed error messages"
            rm -f "$temp_config" "$temp_yaml"
            return 1
        }
    fi
    
    rm -f "$temp_config" "$temp_yaml"
    log_success "Configured persistent storage for UWM Prometheus (${storage_size} using ${storage_class})"
    log_info "Prometheus pods will be recreated with persistent volumes (this may take a few minutes)"
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
    # Check for both patterns: "alertmanager:" followed by "enabled: true" or just "enabled: true" under alertmanager
    if echo "$uwm_config" | grep -A5 "^alertmanager:" | grep -qE "^\s*enabled:\s*true"; then
        log_info "AlertManager is already enabled for user workloads"
        return 0
    fi
    
    # Check if config is empty
    if [[ -z "$uwm_config" ]]; then
        log_info "Enabling AlertManager for user workloads (empty config)..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc patch configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --type merge \
                -p '{"data":{"config.yaml":"alertmanager:\n  enabled: true\n  enableAlertmanagerConfig: true\n"}}' || {
                log_error "Failed to enable AlertManager"
                log_error "This requires cluster-admin permissions"
                return 1
            }
        else
            oc patch configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --type merge \
                -p '{"data":{"config.yaml":"alertmanager:\n  enabled: true\n  enableAlertmanagerConfig: true\n"}}' 2>&1 | grep -v "^configmap/" || {
                log_error "Failed to enable AlertManager"
                log_error "This requires cluster-admin permissions"
                return 1
            }
        fi
        log_success "Enabled AlertManager for user workloads"
        return 0
    fi
    
    # Config exists but doesn't have AlertManager enabled
    log_info "Enabling AlertManager for user workloads (updating existing config)..."
    
    # Use a more robust approach: use oc apply with a temporary file instead of complex JSON escaping
    local temp_config=$(mktemp)
    local temp_yaml=$(mktemp)
    
    # Write current config to temp file
    echo "$uwm_config" > "$temp_config"
    
    # Check if alertmanager section exists
    if grep -q "^alertmanager:" "$temp_config"; then
        # Update existing alertmanager section
        # Use a Python-like approach with sed/awk that's more reliable
        local temp_updated=$(mktemp)
        
        # Try to update enabled: false to enabled: true
        if grep -qE "^\s*enabled:\s*false" "$temp_config"; then
            sed 's/^\(\s*\)enabled:\s*false/\1enabled: true/' "$temp_config" > "$temp_updated"
            mv "$temp_updated" "$temp_config"
        fi
        
        # Ensure enableAlertmanagerConfig is set
        if ! grep -q "enableAlertmanagerConfig" "$temp_config"; then
            # Add enableAlertmanagerConfig after enabled line
            sed '/^\s*enabled:/a\
  enableAlertmanagerConfig: true' "$temp_config" > "$temp_updated"
            mv "$temp_updated" "$temp_config"
        fi
    else
        # Add alertmanager section at the beginning
        {
            echo "alertmanager:"
            echo "  enabled: true"
            echo "  enableAlertmanagerConfig: true"
            echo ""
            cat "$temp_config"
        } > "${temp_config}.new"
        mv "${temp_config}.new" "$temp_config"
    fi
    
    # Create a temporary YAML file for the ConfigMap
    cat > "$temp_yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
$(sed 's/^/    /' "$temp_config")
EOF
    
    # Apply using oc apply instead of patch (more reliable for YAML)
    if [[ "$VERBOSE" == "true" ]]; then
        oc apply -f "$temp_yaml" || {
            log_error "Failed to enable AlertManager"
            log_error "This requires cluster-admin permissions"
            rm -f "$temp_config" "$temp_yaml"
            return 1
        }
    else
        oc apply -f "$temp_yaml" &>/dev/null || {
            log_error "Failed to enable AlertManager"
            log_error "This requires cluster-admin permissions"
            log_info "Run with --verbose to see detailed error messages"
            rm -f "$temp_config" "$temp_yaml"
            return 1
        }
    fi
    
    rm -f "$temp_config" "$temp_yaml"
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

# Detect all installed monitoring types (for coexistence support)
detect_all_monitoring_types() {
    local types=()
    
    # Check for COO
    if (oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .) || \
       (oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .); then
        types+=("coo")
    fi
    
    # Check for UWM
    if (oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .) || \
       (oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .); then
        types+=("uwm")
    fi
    
    if [[ ${#types[@]} -eq 0 ]]; then
        echo "none"
    else
        echo "${types[*]}"
    fi
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
    
    # Check if we need to add persistent storage configuration
    local storage_class="${COO_STORAGE_CLASS:-}"
    local storage_size="${COO_STORAGE_SIZE:-50Gi}"
    
    # If --persistent flag is set and no storage class specified, detect default
    if [[ "$PERSISTENT" == "true" ]] && [[ -z "$storage_class" ]]; then
        log_info "Detecting default storage class for COO..."
        storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        
        if [[ -z "$storage_class" ]]; then
            # Try alternative annotation
            storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        fi
        
        if [[ -z "$storage_class" ]]; then
            log_warn "No default storage class found. Persistent storage will not be configured."
            log_info "Specify a storage class explicitly using --coo-storage-class"
        else
            log_info "Using detected default storage class: $storage_class"
        fi
    fi
    
    # If storage_class is not provided and --persistent is not set, try to detect a default storage class
    if [[ -z "$storage_class" ]] && [[ "$PERSISTENT" != "true" ]]; then
        log_info "Detecting default storage class for COO..."
        storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        
        if [[ -z "$storage_class" ]]; then
            # Try alternative annotation
            storage_class=$(oc get storageclass -o json 2>/dev/null | jq -r '.items[] | select(.metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true") | .metadata.name' | head -1)
        fi
    fi
    
    # If we have a storage class, update the MonitoringStack to include persistent storage
    if [[ -n "$storage_class" ]]; then
        log_info "Configuring persistent storage for COO Prometheus (${storage_size} using ${storage_class})..."
        
        # Create a temporary MonitoringStack file with persistent storage
        local temp_monitoringstack=$(mktemp)
        cat > "$temp_monitoringstack" <<EOF
---
# COO MonitoringStack CR
# Deploys Prometheus and Alertmanager instances managed by COO
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: eip-monitoring-stack
  namespace: ${NAMESPACE}
  labels:
    app: eip-monitor
    coo: eip-monitoring
    app.kubernetes.io/part-of: eip-monitoring-stack
spec:
  logLevel: info
  retention: 15d
  resourceSelector:
    matchLabels:
      app: eip-monitor
  prometheusConfig:
    volumeClaimTemplate:
      spec:
        storageClassName: ${storage_class}
        resources:
          requests:
            storage: ${storage_size}
EOF
        
        if [[ "$VERBOSE" == "true" ]]; then
            oc apply -f "$temp_monitoringstack" || {
                log_error "Failed to deploy COO MonitoringStack with persistent storage"
                rm -f "$temp_monitoringstack"
                return 1
            }
        else
            oc apply -f "$temp_monitoringstack" 2>/dev/null || {
                log_error "Failed to deploy COO MonitoringStack with persistent storage"
                log_info "Run with --verbose to see detailed error messages"
                rm -f "$temp_monitoringstack"
                return 1
            }
        fi
        
        rm -f "$temp_monitoringstack"
        log_success "COO MonitoringStack deployed with persistent storage"
    else
        # No storage class, use original file
        log_info "No storage class specified or detected, using ephemeral storage"
        if [[ "$VERBOSE" == "true" ]]; then
            oc apply -f "$monitoringstack_file" || {
                log_error "Failed to deploy COO MonitoringStack"
                return 1
            }
        else
            oc apply -f "$monitoringstack_file" 2>/dev/null || {
                log_error "Failed to deploy COO MonitoringStack"
                return 1
            }
        fi
        log_success "COO MonitoringStack deployed (using ephemeral storage)"
    fi
    
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
    
    # Delete COO manifests using label selector (safer - only deletes COO resources)
    log_info "Removing COO manifests (using label selector: monitoring-type=coo)..."
    
    # Use label selector to ensure we only delete COO resources
    # This prevents accidental deletion of UWM resources if both are deployed
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete servicemonitor,prometheusrule,networkpolicy -n "$NAMESPACE" -l monitoring-type=coo || true
    else
        oc delete servicemonitor,prometheusrule,networkpolicy -n "$NAMESPACE" -l monitoring-type=coo &>/dev/null || true
    fi
    
    # Also delete by name as fallback (in case labels weren't applied)
    log_info "Removing COO manifests (by name, as fallback)..."
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete servicemonitor eip-monitor-coo -n "$NAMESPACE" 2>/dev/null || true
        oc delete prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" 2>/dev/null || true
        oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" 2>/dev/null || true
    else
        oc delete servicemonitor eip-monitor-coo -n "$NAMESPACE" 2>/dev/null || true
        oc delete prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" 2>/dev/null || true
        oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" 2>/dev/null || true
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
    
    # Delete persistent volumes (PVCs) if requested
    if [[ "$DELETE_PERSISTENT_STORAGE" == "true" ]]; then
        log_info "Deleting COO Prometheus persistent volumes..."
        
        # Find PVCs created by Prometheus StatefulSets managed by COO
        # COO creates Prometheus with labels matching the MonitoringStack
        local pvcs=$(oc get pvc -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "prometheus" or .metadata.name | startswith("prometheus-")) | .metadata.name' 2>/dev/null || echo "")
        
        if [[ -n "$pvcs" ]]; then
            while IFS= read -r pvc_name; do
                if [[ -n "$pvc_name" ]]; then
                    log_info "Deleting PVC: $pvc_name"
                    if [[ "$VERBOSE" == "true" ]]; then
                        oc delete pvc "$pvc_name" -n "$NAMESPACE" || log_warn "Failed to delete PVC: $pvc_name"
                    else
                        oc delete pvc "$pvc_name" -n "$NAMESPACE" &>/dev/null || log_warn "Failed to delete PVC: $pvc_name"
                    fi
                fi
            done <<< "$pvcs"
            log_success "COO persistent volumes deleted"
        else
            log_info "No COO Prometheus PVCs found to delete"
        fi
    else
        log_info "Persistent volumes retained (use --delete-persistent-storage to remove them)"
    fi
    
    # Check if combined NetworkPolicy exists and handle it
    # Only delete combined NetworkPolicy if UWM is not also deployed
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        # Check if UWM resources still exist
        if ! oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
            log_info "Deleting combined NetworkPolicy (UWM not detected)..."
            if [[ "$VERBOSE" == "true" ]]; then
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" || true
            else
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null || true
            fi
        else
            log_info "Keeping combined NetworkPolicy (UWM still deployed)..."
        fi
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
    
    # Delete UWM manifests using label selector (safer - only deletes UWM resources)
    log_info "Removing UWM manifests (using label selector: monitoring-type=uwm)..."
    
    # Use label selector to ensure we only delete UWM resources
    # This prevents accidental deletion of COO resources if both are deployed
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete servicemonitor,prometheusrule,networkpolicy -n "$NAMESPACE" -l monitoring-type=uwm || true
    else
        oc delete servicemonitor,prometheusrule,networkpolicy -n "$NAMESPACE" -l monitoring-type=uwm &>/dev/null || true
    fi
    
    # Also delete by name as fallback (in case labels weren't applied)
    log_info "Removing UWM manifests (by name, as fallback)..."
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete servicemonitor eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
        oc delete prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" 2>/dev/null || true
        oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
    else
        oc delete servicemonitor eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
        oc delete prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" 2>/dev/null || true
        oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
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
    
    # Delete persistent volumes (PVCs) if requested
    if [[ "$DELETE_PERSISTENT_STORAGE" == "true" ]]; then
        log_info "Deleting UWM Prometheus persistent volumes..."
        
        # Find PVCs created by Prometheus StatefulSets in openshift-user-workload-monitoring namespace
        # UWM Prometheus PVCs are typically named like "prometheus-user-workload-prometheus-*"
        local pvcs=$(oc get pvc -n openshift-user-workload-monitoring -o json 2>/dev/null | jq -r '.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "prometheus" or .metadata.name | contains("prometheus")) | .metadata.name' 2>/dev/null || echo "")
        
        if [[ -n "$pvcs" ]]; then
            while IFS= read -r pvc_name; do
                if [[ -n "$pvc_name" ]]; then
                    log_info "Deleting PVC: $pvc_name"
                    if [[ "$VERBOSE" == "true" ]]; then
                        oc delete pvc "$pvc_name" -n openshift-user-workload-monitoring || log_warn "Failed to delete PVC: $pvc_name"
                    else
                        oc delete pvc "$pvc_name" -n openshift-user-workload-monitoring &>/dev/null || log_warn "Failed to delete PVC: $pvc_name"
                    fi
                fi
            done <<< "$pvcs"
            log_success "UWM persistent volumes deleted"
        else
            log_info "No UWM Prometheus PVCs found to delete"
        fi
    else
        log_info "Persistent volumes retained (use --delete-persistent-storage to remove them)"
    fi
    
    # Check if combined NetworkPolicy exists and handle it
    # Only delete combined NetworkPolicy if COO is not also deployed
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        # Check if COO resources still exist
        if ! oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
            log_info "Deleting combined NetworkPolicy (COO not detected)..."
            if [[ "$VERBOSE" == "true" ]]; then
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" || true
            else
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null || true
            fi
        else
            log_info "Keeping combined NetworkPolicy (COO still deployed)..."
        fi
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
    
    # Detect current monitoring type(s)
    local current_type=$(detect_current_monitoring_type)
    local all_types=$(detect_all_monitoring_types)
    
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
    
    # Check if the requested type is already installed
    if echo "$all_types" | grep -q "$MONITORING_TYPE"; then
        log_info "Monitoring type '$MONITORING_TYPE' is already installed"
        log_info "Updating/reapplying manifests..."
    elif [[ "$current_type" != "none" ]]; then
        # Different type detected - allow both to coexist
        log_info "Detected $current_type monitoring already installed"
        log_info "Installing $MONITORING_TYPE monitoring alongside $current_type (both will coexist)..."
    fi
    
    # If both types are present, suggest using combined NetworkPolicy
    if echo "$all_types" | grep -q "coo" && echo "$all_types" | grep -q "uwm"; then
        log_info "Both COO and UWM are installed - consider applying combined NetworkPolicy:"
        log_info "  oc apply -f k8s/monitoring/networkpolicy-combined.yaml"
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
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/scrapeconfig-federation.yaml"
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/networkpolicy-coo.yaml"
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/thanosquerier-coo.yaml"
        else
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/scrapeconfig-federation.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/networkpolicy-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/thanosquerier-coo.yaml" 2>/dev/null
        fi
        
        # Add COO monitoring labels to deployment and service for service discovery
        log_info "Adding COO monitoring labels to eip-monitor deployment and service..."
        if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
            # Add labels to deployment metadata and pod template
            # Ensure pods have: app=eip-monitor, service=eip-monitor (required by ServiceMonitor)
            oc patch deployment eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/monitoring-coo", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/monitoring-coo", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/service", "value": "eip-monitor"}
            ]' 2>/dev/null || {
                # Fallback: use oc label
                oc label deployment eip-monitor -n "$NAMESPACE" monitoring-coo="true" --overwrite &>/dev/null || true
            }
            log_success "COO monitoring labels added to deployment"
        else
            log_warn "Deployment eip-monitor not found, skipping label update"
        fi
        
        # Ensure service has correct labels for ServiceMonitor discovery
        if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
            oc patch service eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/app", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/service", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/monitoring-coo", "value": "true"},
                {"op": "replace", "path": "/spec/selector/app", "value": "eip-monitor"}
            ]' 2>/dev/null || {
                # Fallback: use oc label and patch
                oc label service eip-monitor -n "$NAMESPACE" app=eip-monitor service=eip-monitor monitoring-coo="true" --overwrite &>/dev/null || true
                oc patch service eip-monitor -n "$NAMESPACE" --type merge -p '{"spec":{"selector":{"app":"eip-monitor"}}}' &>/dev/null || true
            }
            log_success "Service labels updated for COO"
        fi
        
        log_success "COO monitoring infrastructure deployed!"
        
    elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
        log_info "Deploying UWM monitoring infrastructure..."
        
        # Enable UWM
        enable_user_workload_monitoring
        enable_user_workload_alertmanager
        
        # Configure persistent storage if storage class is provided or --persistent flag is set
        if [[ "$PERSISTENT" == "true" ]] || [[ -n "$UWM_STORAGE_CLASS" ]]; then
            configure_uwm_persistent_storage "$UWM_STORAGE_CLASS" "$UWM_STORAGE_SIZE" || {
                log_warn "Persistent storage configuration failed, continuing with deployment..."
            }
        elif oc get storageclass &>/dev/null; then
            # Storage classes available but not explicitly requested - skip silently
            log_info "Skipping persistent storage configuration (not requested)"
            log_info "UWM Prometheus will use ephemeral storage (data will be lost on pod restart)"
            log_info "Use --persistent to enable persistent storage with default storage class"
        else
            log_info "Skipping persistent storage configuration (no storage class available)"
            log_info "UWM Prometheus will use ephemeral storage (data will be lost on pod restart)"
        fi
        
        # Apply UWM manifests
        log_info "Applying UWM monitoring manifests..."
        local manifest_errors=0
        
        if [[ "$VERBOSE" == "true" ]]; then
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml" || manifest_errors=$((manifest_errors + 1))
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml" || manifest_errors=$((manifest_errors + 1))
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml" || manifest_errors=$((manifest_errors + 1))
        else
            if ! oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml" 2>/dev/null; then
                log_error "Failed to apply servicemonitor-uwm.yaml"
                manifest_errors=$((manifest_errors + 1))
            fi
            if ! oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml" 2>/dev/null; then
                log_error "Failed to apply prometheusrule-uwm.yaml"
                manifest_errors=$((manifest_errors + 1))
            fi
            if ! oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml" 2>/dev/null; then
                log_error "Failed to apply networkpolicy-uwm.yaml"
                manifest_errors=$((manifest_errors + 1))
            fi
        fi
        
        if [[ $manifest_errors -gt 0 ]]; then
            log_error "Failed to apply $manifest_errors UWM manifest(s)"
            log_info "Run with --verbose to see detailed error messages"
            log_info "Check that the manifest files exist:"
            log_info "  ls -la ${project_root}/k8s/monitoring/uwm/monitoring/"
            return 1
        fi
        
        log_success "UWM monitoring manifests applied successfully"
        
        # Add UWM monitoring labels to deployment and service for service discovery
        log_info "Adding UWM monitoring labels to eip-monitor deployment and service..."
        if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
            # Add labels to deployment metadata and pod template
            # Ensure pods have: app=eip-monitor, service=eip-monitor (required by ServiceMonitor)
            if oc patch deployment eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/service", "value": "eip-monitor"}
            ]' 2>/dev/null; then
                log_success "UWM monitoring labels added to deployment"
            else
                # Fallback: use oc label
                if oc label deployment eip-monitor -n "$NAMESPACE" monitoring-uwm="true" --overwrite &>/dev/null; then
                    log_success "UWM monitoring labels added to deployment (using fallback method)"
                else
                    log_warn "Failed to add UWM labels to deployment (may need manual intervention)"
                fi
            fi
        else
            log_warn "Deployment eip-monitor not found in namespace $NAMESPACE"
            log_info "Deployment must exist before UWM can scrape metrics"
            log_info "Deploy the eip-monitor application first:"
            log_info "  oc apply -f k8s/deployment/k8s-manifests.yaml"
        fi
        
        # Ensure service has correct labels for ServiceMonitor discovery
        if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
            if oc patch service eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/app", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/service", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "replace", "path": "/spec/selector/app", "value": "eip-monitor"}
            ]' 2>/dev/null; then
                log_success "Service labels updated for UWM"
            else
                # Fallback: use oc label and patch
                if oc label service eip-monitor -n "$NAMESPACE" app=eip-monitor service=eip-monitor monitoring-uwm="true" --overwrite &>/dev/null && \
                   oc patch service eip-monitor -n "$NAMESPACE" --type merge -p '{"spec":{"selector":{"app":"eip-monitor"}}}' &>/dev/null; then
                    log_success "Service labels updated for UWM (using fallback method)"
                else
                    log_warn "Failed to update service labels (may need manual intervention)"
                fi
            fi
        else
            log_warn "Service eip-monitor not found in namespace $NAMESPACE"
            log_info "Service must exist before UWM can scrape metrics"
            log_info "Deploy the eip-monitor application first:"
            log_info "  oc apply -f k8s/deployment/k8s-manifests.yaml"
        fi
        
        log_success "UWM monitoring infrastructure deployed!"
        log_info ""
        log_info "Next steps:"
        log_info "  1. Verify UWM Prometheus is running:"
        log_info "     oc get pods -n openshift-user-workload-monitoring | grep prometheus"
        log_info "  2. Check if metrics are being scraped:"
        log_info "     oc get servicemonitor eip-monitor-uwm -n $NAMESPACE -o yaml"
        log_info "  3. If both COO and UWM are deployed, apply combined NetworkPolicy:"
        log_info "     oc apply -f k8s/monitoring/networkpolicy-combined.yaml"
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
            --persistent)
                PERSISTENT="true"
                shift
                ;;
            --delete-persistent-storage)
                DELETE_PERSISTENT_STORAGE="true"
                shift
                ;;
            --uwm-storage-class)
                UWM_STORAGE_CLASS="$2"
                shift 2
                ;;
            --uwm-storage-size)
                UWM_STORAGE_SIZE="$2"
                shift 2
                ;;
            --coo-storage-class)
                COO_STORAGE_CLASS="$2"
                shift 2
                ;;
            --coo-storage-size)
                COO_STORAGE_SIZE="$2"
                shift 2
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

