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

Note: To deploy both COO and UWM simultaneously:
  1. Deploy COO: $0 --monitoring-type coo
  2. Deploy UWM: $0 --monitoring-type uwm
  3. Apply combined NetworkPolicy: oc apply -f k8s/monitoring/networkpolicy-combined.yaml
     (This replaces the individual NetworkPolicies to avoid conflicts)

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
    
    # Check if subscription already exists and is healthy
    local subscription_exists=false
    local subscription_healthy=false
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        subscription_exists=true
        # Check if subscription is properly linked to a CSV
        local installed_csv=$(oc get subscription cluster-observability-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
        local subscription_state=$(oc get subscription cluster-observability-operator -n openshift-operators -o jsonpath='{.status.state}' 2>/dev/null || echo "")
        
        if [[ -n "$installed_csv" ]] && [[ "$subscription_state" == "AtLatestKnown" ]]; then
            subscription_healthy=true
            log_info "COO operator subscription already exists and is healthy (installedCSV: $installed_csv)"
        else
            log_warn "COO operator subscription exists but may not be properly linked (installedCSV: ${installed_csv:-null}, state: ${subscription_state:-null})"
        fi
    fi
    
    # Check if CSV exists independently (not linked to subscription)
    local csv_exists=false
    local csv_name=""
    local csv_phase=""
    csv_name=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("cluster-observability")) | .metadata.name' | head -1 || echo "")
    if [[ -n "$csv_name" ]]; then
        csv_exists=true
        csv_phase=$(oc get csv "$csv_name" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        
        # Check if CSV is owned by a subscription
        local csv_owner=$(oc get csv "$csv_name" -n openshift-operators -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Subscription")].name}' 2>/dev/null || echo "")
        
        if [[ -z "$csv_owner" ]]; then
            log_warn "CSV $csv_name exists but is not owned by a subscription"
            if [[ "$subscription_exists" == "true" ]] && [[ "$subscription_healthy" == "false" ]]; then
                log_info "Subscription exists but CSV is not linked. This may cause resolution issues."
                log_info "To fix: delete the CSV and let the subscription reinstall it:"
                log_info "  oc delete csv $csv_name -n openshift-operators"
            fi
        elif [[ "$csv_phase" == "Succeeded" ]] && [[ "$subscription_healthy" == "true" ]]; then
            log_success "COO operator is already installed and healthy (CSV: $csv_name, phase: $csv_phase)"
            return 0
        fi
    fi
    
    # If subscription is healthy, we're done
    if [[ "$subscription_healthy" == "true" ]]; then
        log_success "COO operator subscription is healthy, skipping installation"
        return 0
    fi
    
    # Apply subscription (idempotent - will update if exists, create if not)
    log_info "Applying COO operator subscription..."
    if oc apply -f "$subscription_file" 2>/dev/null; then
        if [[ "$subscription_exists" == "true" ]]; then
            log_success "COO operator subscription updated"
        else
            log_success "COO operator subscription created"
        fi
    else
        log_error "Failed to install COO operator subscription"
        log_error "This requires cluster-admin permissions"
        return 1
    fi
    
    log_info "Waiting for COO operator to be installed (this may take a few minutes)..."
    
    # Wait for CSV to succeed
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local csv_phase=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("cluster-observability")) | .status.phase' | head -1 || echo "")
        local installed_csv=$(oc get subscription cluster-observability-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
        
        if [[ "$csv_phase" == "Succeeded" ]] && [[ -n "$installed_csv" ]]; then
            log_success "COO operator installed successfully (CSV: $installed_csv)"
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]]; then
            log_info "Still waiting for COO operator... (${waited}s, CSV phase: ${csv_phase:-none}, installedCSV: ${installed_csv:-null})"
        fi
    done
    
    if [[ $waited -ge $max_wait ]]; then
        log_warn "COO operator may not be fully ready yet (waited ${max_wait}s)"
        local final_csv=$(oc get subscription cluster-observability-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
        if [[ -z "$final_csv" ]]; then
            log_warn "Subscription installedCSV is still null - there may be a resolution issue"
            log_info "Check subscription status: oc get subscription cluster-observability-operator -n openshift-operators -o yaml"
        fi
    fi
}

# Verify ThanosQuerier store discovery
verify_thanosquerier_stores() {
    log_info "Verifying ThanosQuerier store discovery..."
    
    local thanos_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=thanos-query --no-headers 2>/dev/null | awk '{print $1}' | head -1)
    
    if [[ -z "$thanos_pod" ]]; then
        log_warn "ThanosQuerier pod not found, skipping store verification"
        return 0
    fi
    
    # Wait for ThanosQuerier to be ready
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if oc get pod "$thanos_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    # Check ThanosQuerier logs for store discovery
    local max_attempts=6
    local attempt=0
    local stores_found=false
    
    while [[ $attempt -lt $max_attempts ]]; do
        local log_output=$(oc logs "$thanos_pod" -n "$NAMESPACE" --tail=100 2>&1 | grep -i "adding new sidecar" || echo "")
        
        if [[ -n "$log_output" ]]; then
            local store_count=$(echo "$log_output" | grep -c "adding new sidecar" || echo "0")
            if [[ "$store_count" -gt 0 ]]; then
                stores_found=true
                log_success "ThanosQuerier discovered $store_count Prometheus store(s)"
                break
            fi
        fi
        
        attempt=$((attempt + 1))
        if [[ $attempt -lt $max_attempts ]]; then
            sleep 10
        fi
    done
    
    if [[ "$stores_found" == "false" ]]; then
        log_warn "ThanosQuerier store discovery verification failed"
        log_warn "This may indicate that:"
        log_warn "  1. MonitoringStack label 'app.kubernetes.io/part-of: eip-monitoring-stack' is missing"
        log_warn "  2. Prometheus pods don't have Thanos sidecars running"
        log_warn "  3. COO operator hasn't reconciled yet"
        log_warn "ThanosQuerier may still work, but stores may not be discovered yet."
        log_warn "You can check logs with: oc logs $thanos_pod -n $NAMESPACE | grep -i store"
        return 1
    fi
    
    return 0
}

# Setup federation token secret for COO Prometheus
setup_federation_token() {
    log_info "Setting up federation token secret for COO Prometheus..."
    
    local token_secret_name="eip-monitoring-stack-prometheus-token"
    local service_account="eip-monitoring-stack-prometheus"
    
    # Wait for service account to exist (created by MonitoringStack)
    log_info "Waiting for service account $service_account to be created..."
    local max_wait=60
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        if oc get serviceaccount "$service_account" -n "$NAMESPACE" &>/dev/null; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    if ! oc get serviceaccount "$service_account" -n "$NAMESPACE" &>/dev/null; then
        log_error "Service account $service_account not found in namespace $NAMESPACE"
        return 1
    fi
    
    # Check if token secret already exists
    if oc get secret "$token_secret_name" -n "$NAMESPACE" &>/dev/null; then
        log_info "Token secret $token_secret_name already exists, checking if it's valid..."
        # Check if token is valid by checking its size (should be > 0)
        local token_size=$(oc get secret "$token_secret_name" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null | wc -c || echo "0")
        if [[ "$token_size" -gt 100 ]]; then
            log_info "Existing token secret appears valid (${token_size} bytes), skipping recreation"
            return 0
        else
            log_warn "Existing token secret appears invalid or empty, recreating..."
            oc delete secret "$token_secret_name" -n "$NAMESPACE" 2>/dev/null || true
        fi
    fi
    
    # Create new token
    log_info "Creating new federation token..."
    local token_output
    token_output=$(oc create token "$service_account" -n "$NAMESPACE" --duration=8760h 2>&1)
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create token for service account $service_account: $token_output"
        return 1
    fi
    
    local token=$(echo "$token_output" | tail -1)
    if [[ -z "$token" ]]; then
        log_error "Token creation succeeded but token is empty"
        return 1
    fi
    
    # Create secret with token
    oc create secret generic "$token_secret_name" \
        -n "$NAMESPACE" \
        --from-literal=token="$token" \
        --dry-run=client -o yaml | oc apply -f - || {
        log_error "Failed to create token secret $token_secret_name"
        return 1
    }
    
    log_success "Federation token secret created: $token_secret_name"
    return 0
}

# Verify federation is working
verify_federation() {
    log_info "Verifying Prometheus federation is working..."
    
    # Wait for Prometheus pods to be ready
    log_info "Waiting for Prometheus pods to be ready..."
    local max_wait=120
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local prom_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || echo "0")
        prom_pods=$(echo "$prom_pods" | tr -d '[:space:]')
        if [[ "$prom_pods" =~ ^[0-9]+$ ]] && [[ "$prom_pods" -gt 0 ]]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    if [[ "$prom_pods" =~ ^[0-9]+$ ]] && [[ "$prom_pods" -eq 0 ]]; then
        log_warn "Prometheus pods not ready after ${max_wait}s, skipping federation verification"
        return 1
    fi
    
    local prometheus_pod=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$prometheus_pod" ]]; then
        log_warn "Prometheus pod not found, skipping federation verification"
        return 1
    fi
    
    # Check federation target health
    log_info "Checking federation target health..."
    local max_retries=12
    local retry=0
    local federation_healthy=false
    
    while [[ $retry -lt $max_retries ]]; do
        local targets_json
        targets_json=$(oc exec -n "$NAMESPACE" "$prometheus_pod" -- curl -s http://localhost:9090/api/v1/targets 2>/dev/null || echo "")
        
        if [[ -n "$targets_json" ]]; then
            # Check for federation target
            local federation_targets
            federation_targets=$(echo "$targets_json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    targets = data.get('data', {}).get('activeTargets', [])
    fed_targets = [t for t in targets if 'federation' in t.get('scrapeUrl', '').lower() or 'federate' in t.get('scrapeUrl', '').lower()]
    if fed_targets:
        health = fed_targets[0].get('health', 'unknown')
        error = fed_targets[0].get('lastError', '')
        print(f'{health}|{error[:100]}')
    else:
        print('not_found|')
except:
    print('error|Failed to parse targets')
" 2>/dev/null || echo "error|Failed to check targets")
            
            local health=$(echo "$federation_targets" | cut -d'|' -f1)
            local error=$(echo "$federation_targets" | cut -d'|' -f2)
            
            if [[ "$health" == "up" ]]; then
                federation_healthy=true
                log_success "Federation target is healthy"
                break
            elif [[ "$health" == "down" ]]; then
                if [[ -n "$error" ]]; then
                    log_warn "Federation target is down: $error"
                else
                    log_warn "Federation target is down (checking again...)"
                fi
            elif [[ "$health" == "unknown" ]]; then
                log_info "Federation target health is unknown (may still be initializing)..."
            fi
        fi
        
        sleep 5
        retry=$((retry + 1))
    done
    
    if [[ "$federation_healthy" == "true" ]]; then
        # Verify federated metrics are available
        log_info "Verifying federated metrics are available..."
        local metrics_check
        metrics_check=$(oc exec -n "$NAMESPACE" "$prometheus_pod" -- curl -s -G --data-urlencode 'query=kube_node_labels' http://localhost:9090/api/v1/query 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    result = data.get('data', {}).get('result', [])
    print(f'{data.get(\"status\", \"unknown\")}|{len(result)}')
except:
    print('error|0')
" 2>/dev/null || echo "error|0")
        
        local status=$(echo "$metrics_check" | cut -d'|' -f1)
        local count=$(echo "$metrics_check" | cut -d'|' -f2)
        
        if [[ "$status" == "success" ]] && [[ "$count" -gt 0 ]]; then
            log_success "Federated metrics are available (found $count kube_node_labels)"
            return 0
        else
            log_warn "Federated metrics check failed (status: $status, count: $count)"
            log_warn "Federation may still be initializing, or there may be a configuration issue"
            return 1
        fi
    else
        log_warn "Federation target verification failed after $max_retries retries"
        log_warn "Federation may still be initializing, or there may be a configuration issue"
        log_warn "You can check federation status with: oc exec -n $NAMESPACE $prometheus_pod -- curl -s http://localhost:9090/api/v1/targets | grep -i federation"
        return 1
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
    
    # Ensure MonitoringStack has the required label for ThanosQuerier discovery
    log_info "Ensuring MonitoringStack has required label for ThanosQuerier discovery..."
    local part_of_label=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || echo "")
    if [[ "$part_of_label" != "eip-monitoring-stack" ]]; then
        log_info "Adding required label to MonitoringStack..."
        oc patch monitoringstack eip-monitoring-stack -n "$NAMESPACE" --type merge \
            -p '{"metadata":{"labels":{"app.kubernetes.io/part-of":"eip-monitoring-stack"}}}' || {
            log_warn "Failed to add label to MonitoringStack (this may affect ThanosQuerier store discovery)"
        }
        # Wait a moment for the label to be applied
        sleep 2
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
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/thanosquerier-coo.yaml"
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/alertmanagerconfig-coo.yaml"
            oc apply -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml"
        else
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/networkpolicy-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/thanosquerier-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/alertmanagerconfig-coo.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml" 2>/dev/null
        fi
        
        # Apply federation ScrapeConfig if it exists
        local scrapeconfig_file="${project_root}/k8s/monitoring/coo/monitoring/scrapeconfig-federation.yaml"
        if [[ -f "$scrapeconfig_file" ]]; then
            log_info "Applying federation ScrapeConfig..."
            if [[ "$VERBOSE" == "true" ]]; then
                oc apply -f "$scrapeconfig_file"
            else
                oc apply -f "$scrapeconfig_file" 2>/dev/null
            fi
            
            # Setup federation token secret
            setup_federation_token || {
                log_warn "Failed to setup federation token, but deployment continues"
                log_warn "Federation may not work until the token is created manually"
            }
            
            # Wait for Prometheus to pick up the new token
            log_info "Waiting for Prometheus to pick up federation configuration..."
            sleep 10
            
            # Verify federation is working (non-blocking)
            verify_federation || {
                log_warn "Federation verification failed, but deployment continues"
                log_warn "Federation may still be initializing, or there may be a configuration issue"
            }
        else
            log_warn "Federation ScrapeConfig file not found: $scrapeconfig_file"
            log_warn "Federation will not be configured. If you need cluster metrics, create the ScrapeConfig file."
        fi
        
        # Verify ThanosQuerier store discovery
        log_info "Waiting for ThanosQuerier to be ready..."
        local max_wait=60
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            if oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=thanos-query --no-headers 2>/dev/null | grep -q "Running"; then
                break
            fi
            sleep 5
            waited=$((waited + 5))
        done
        
        # Verify store discovery (non-blocking - warns but doesn't fail deployment)
        verify_thanosquerier_stores || {
            log_warn "ThanosQuerier store discovery verification failed, but deployment continues"
            log_warn "ThanosQuerier may need more time to discover stores, or there may be a configuration issue"
        }
        
        # Install Perses datasources and dashboards for console integration
        # Note: These must be in openshift-operators namespace to be visible in the web console
        # The Perses instance is created automatically by UIPlugin
        log_info "Installing Perses datasources and dashboards for console integration..."
        if [[ -d "${project_root}/k8s/monitoring/coo/perses" ]]; then
            # Install datasources
            if [[ -d "${project_root}/k8s/monitoring/coo/perses/datasources" ]]; then
                for datasource in "${project_root}"/k8s/monitoring/coo/perses/datasources/*.yaml; do
                    if [[ -f "$datasource" ]]; then
                        local ds_name=$(basename "$datasource" .yaml)
                        if [[ "$VERBOSE" == "true" ]]; then
                            oc apply -f "$datasource" && log_success "  ✓ Installed Perses datasource: $ds_name"
                        else
                            if oc apply -f "$datasource" &>/dev/null; then
                                log_success "  ✓ Installed Perses datasource: $ds_name"
                            else
                                log_warn "  ✗ Failed to install Perses datasource: $ds_name"
                            fi
                        fi
                    fi
                done
            fi
            # Install dashboards
            if [[ -d "${project_root}/k8s/monitoring/coo/perses/dashboards" ]]; then
                for dashboard in "${project_root}"/k8s/monitoring/coo/perses/dashboards/*.yaml; do
                    if [[ -f "$dashboard" ]]; then
                        local db_name=$(basename "$dashboard" .yaml)
                        if [[ "$VERBOSE" == "true" ]]; then
                            oc apply -f "$dashboard" && log_success "  ✓ Installed Perses dashboard: $db_name"
                        else
                            if oc apply -f "$dashboard" &>/dev/null; then
                                log_success "  ✓ Installed Perses dashboard: $db_name"
                            else
                                log_warn "  ✗ Failed to install Perses dashboard: $db_name"
                            fi
                        fi
                    fi
                done
            fi
        else
            log_warn "Perses directory not found: ${project_root}/k8s/monitoring/coo/perses"
        fi
        
        # Install COO UI plugins (for OpenShift console integration)
        log_info "Installing COO UI plugins..."
        if [[ -d "${project_root}/k8s/monitoring/coo/ui-plugins" ]]; then
            for ui_plugin in "${project_root}"/k8s/monitoring/coo/ui-plugins/*.yaml; do
                if [[ -f "$ui_plugin" ]]; then
                    local plugin_name=$(basename "$ui_plugin" .yaml)
                    if [[ "$VERBOSE" == "true" ]]; then
                        oc apply -f "$ui_plugin" && log_success "  ✓ Installed UI plugin: $plugin_name"
                    else
                        if oc apply -f "$ui_plugin" &>/dev/null; then
                            log_success "  ✓ Installed UI plugin: $plugin_name"
                        else
                            log_warn "  ✗ Failed to install UI plugin: $plugin_name"
                        fi
                    fi
                fi
            done
        else
            log_warn "UI plugins directory not found: ${project_root}/k8s/monitoring/coo/ui-plugins"
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
        
        # Apply UWM manifests
        log_info "Applying UWM monitoring manifests..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml"
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml"
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml"
        else
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml" 2>/dev/null
            oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/networkpolicy-uwm.yaml" 2>/dev/null
        fi
        
        # Add UWM monitoring labels to deployment and service for service discovery
        log_info "Adding UWM monitoring labels to eip-monitor deployment and service..."
        if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
            # Add labels to deployment metadata and pod template
            # Ensure pods have: app=eip-monitor, service=eip-monitor (required by ServiceMonitor)
            oc patch deployment eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/service", "value": "eip-monitor"}
            ]' 2>/dev/null || {
                # Fallback: use oc label
                oc label deployment eip-monitor -n "$NAMESPACE" monitoring-uwm="true" --overwrite &>/dev/null || true
            }
            log_success "UWM monitoring labels added to deployment"
        else
            log_warn "Deployment eip-monitor not found, skipping label update"
        fi
        
        # Ensure service has correct labels for ServiceMonitor discovery
        if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
            oc patch service eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/app", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/service", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "replace", "path": "/spec/selector/app", "value": "eip-monitor"}
            ]' 2>/dev/null || {
                # Fallback: use oc label and patch
                oc label service eip-monitor -n "$NAMESPACE" app=eip-monitor service=eip-monitor monitoring-uwm="true" --overwrite &>/dev/null || true
                oc patch service eip-monitor -n "$NAMESPACE" --type merge -p '{"spec":{"selector":{"app":"eip-monitor"}}}' &>/dev/null || true
            }
            log_success "Service labels updated for UWM"
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
                if [[ $# -lt 2 ]]; then
                    log_error "Option $1 requires a value"
                    show_usage
                    exit 1
                fi
                NAMESPACE="$2"
                shift 2
                ;;
            --monitoring-type)
                if [[ $# -lt 2 ]]; then
                    log_error "Option $1 requires a value (coo or uwm)"
                    show_usage
                    exit 1
                fi
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

