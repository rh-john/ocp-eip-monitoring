#!/bin/bash
#
# Deploy Monitoring Infrastructure for EIP Monitoring (COO or UWM)
# This script is completely independent and can be used standalone
#

set -euo pipefail

# Source common functions (pod finding, prerequisites, oc_cmd helpers)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/scripts/lib/common.sh"

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"
MONITORING_TYPE="${MONITORING_TYPE:-}"  # No default - must be explicitly specified
REMOVE_MONITORING="${REMOVE_MONITORING:-false}"
VERBOSE="${VERBOSE:-false}"
DELETE_CRDS="${DELETE_CRDS:-false}"  # Delete COO CRDs during cleanup (requires cluster-admin)
PERSISTENT_STORAGE="${PERSISTENT_STORAGE:-true}"  # Enable persistent storage for Prometheus (default: true)
SHOW_STATUS="${SHOW_STATUS:-false}"  # Show monitoring status
TEST_MONITORING="${TEST_MONITORING:-false}"  # Test monitoring infrastructure

# Note: Logging functions (log_info, log_success, log_warn, log_error) are now sourced from scripts/lib/common.sh
# Note: oc_cmd() and oc_cmd_silent() are now sourced from scripts/lib/common.sh
# They use the VERBOSE environment variable for conditional output suppression
# Note: Helper functions (remove_finalizers, ensure_namespace, wait_for_operator_csv) are also available from common.sh

# Show usage
show_usage() {
    cat << EOF
Deploy Monitoring Infrastructure for EIP Monitoring

Usage: $0 [options]

Options:
  -n, --namespace NS        Kubernetes namespace (default: eip-monitoring)
  --monitoring-type TYPE    Monitoring type: coo, uwm, or all (required for deployment)
  --all                     Deploy both COO and UWM monitoring (same as --monitoring-type all)
  --persistent              Enable persistent storage for Prometheus (both COO and UWM)
  --status                  Show monitoring infrastructure status
  --test                    Test monitoring infrastructure
  --remove-monitoring [TYPE] Remove monitoring infrastructure (TYPE: coo, uwm, or all - required)
  --delete-crds              Delete COO CRDs during cleanup (requires cluster-admin, only for COO removal)
  -v, --verbose            Show verbose output (raw oc command output)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
  MONITORING_TYPE           Monitoring type: coo or uwm (required)
  REMOVE_MONITORING         Set to true to remove monitoring (default: false)
  VERBOSE                   Set to true to show verbose output (default: false)
  PERSISTENT_STORAGE        Set to true to enable persistent storage (default: true)
                            Set to false to use ephemeral storage

Examples:
  $0 --monitoring-type uwm
  $0 --monitoring-type coo -n my-namespace
  $0 --monitoring-type all              # Deploy both COO and UWM
  $0 --all                               # Deploy both COO and UWM
  $0 --monitoring-type coo --persistent  # Deploy COO with persistent storage
  $0 --monitoring-type all --persistent  # Deploy both with persistent storage
  $0 --status                            # Show monitoring status
  $0 --status --monitoring-type coo      # Show COO monitoring status
  $0 --test                              # Test monitoring infrastructure
  $0 --test --monitoring-type uwm        # Test UWM monitoring
  $0 --remove-monitoring coo
  $0 --remove-monitoring --monitoring-type uwm
  $0 --remove-monitoring all
  $0 --remove-monitoring --verbose
  $0 --remove-monitoring coo --delete-crds  # Also delete COO CRDs (requires cluster-admin)

Note: The combined NetworkPolicy (eip-monitor-combined) is always applied,
      which supports both COO and UWM monitoring simultaneously.

EOF
}

# Note: check_prerequisites() is now sourced from scripts/lib/common.sh
# It checks for both oc and jq, and returns error code instead of exiting
# This script calls it and exits if it fails (maintains original behavior)

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
        local create_output create_error
        create_output=$(oc create configmap user-workload-monitoring-config -n openshift-user-workload-monitoring \
            --from-literal=config.yaml="alertmanager:
  enabled: true
  enableAlertmanagerConfig: true" 2>&1)
        local create_exit=$?
        if [[ $create_exit -eq 0 ]]; then
            log_success "Created user-workload-monitoring-config with AlertManager enabled"
            return 0
        else
            log_error "Failed to create user-workload-monitoring-config"
            log_error "Error: $create_output"
            log_error "This requires cluster-admin permissions"
            return 1
        fi
    fi
    
    # Get current config
    local uwm_config=$(oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    # Check if AlertManager is already enabled
    # Handle multiline YAML: check for alertmanager: section with enabled: true
    if echo "$uwm_config" | grep -q "^alertmanager:" && echo "$uwm_config" | grep -A 5 "^alertmanager:" | grep -qE "^\s*enabled:\s*true"; then
        log_info "AlertManager is already enabled for user workloads"
        return 0
    fi
    
    # Check if config is empty
    if [[ -z "$uwm_config" ]]; then
        if [[ "${VERBOSE:-false}" == "true" ]]; then
            log_info "Enabling AlertManager for user workloads (empty config)..."
        fi
        local patch_output patch_error
        patch_output=$(oc patch configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --type merge \
            -p '{"data":{"config.yaml":"alertmanager:\n  enabled: true\n  enableAlertmanagerConfig: true\n"}}' 2>&1)
        local patch_exit=$?
        if [[ $patch_exit -eq 0 ]]; then
            log_success "Enabled AlertManager for user workloads"
            return 0
        else
            log_error "Failed to enable AlertManager"
            log_error "Error: $patch_output"
            log_error "This requires cluster-admin permissions"
            return 1
        fi
    fi
    
    # Config exists but doesn't have AlertManager enabled
    if [[ "${VERBOSE:-false}" == "true" ]]; then
        log_info "Enabling AlertManager for user workloads (updating existing config)..."
        log_info "Current config (first 200 chars): $(echo "$uwm_config" | head -c 200)"
    fi
    
    # Use a temporary file to safely update the YAML
    local temp_config
    temp_config=$(mktemp) || {
        log_error "Failed to create temporary file"
        return 1
    }
    
    # Write config to temp file
    if ! echo "$uwm_config" > "$temp_config"; then
        log_error "Failed to write config to temporary file"
        rm -f "$temp_config"
        return 1
    fi
    
    local temp_config_new="${temp_config}.new"
    
    # Temporarily disable exit on error for YAML parsing operations
    set +e
    
    # Check if alertmanager section exists
    if grep -q "^alertmanager:" "$temp_config" 2>/dev/null; then
        # Update existing alertmanager section
        # Replace enabled: false with enabled: true, or add enabled: true if missing
        if grep -qE "alertmanager:\s*$" "$temp_config" 2>/dev/null || grep -qE "^\s*enabled:\s*false" "$temp_config" 2>/dev/null; then
            # Use awk to update the alertmanager section
            if ! awk '
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
            ' "$temp_config" > "$temp_config_new" 2>/dev/null; then
                log_error "Failed to update AlertManager section in config"
                set -e
                rm -f "$temp_config" "$temp_config_new"
                return 1
            fi
            if ! mv "$temp_config_new" "$temp_config" 2>/dev/null; then
                log_error "Failed to update temporary config file"
                set -e
                rm -f "$temp_config" "$temp_config_new"
                return 1
            fi
        else
            # AlertManager section exists but enabled might be missing or true already
            # Just ensure enableAlertmanagerConfig is set
            if ! grep -q "enableAlertmanagerConfig" "$temp_config" 2>/dev/null; then
                if ! sed '/^alertmanager:/a\
  enableAlertmanagerConfig: true' "$temp_config" > "$temp_config_new" 2>/dev/null; then
                    log_error "Failed to add enableAlertmanagerConfig to config"
                    set -e
                    rm -f "$temp_config" "$temp_config_new"
                    return 1
                fi
                if ! mv "$temp_config_new" "$temp_config" 2>/dev/null; then
                    log_error "Failed to update temporary config file"
                    set -e
                    rm -f "$temp_config" "$temp_config_new"
                    return 1
                fi
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
        } > "$temp_config_new" 2>/dev/null || {
            log_error "Failed to create updated config with AlertManager section"
            set -e
            rm -f "$temp_config" "$temp_config_new"
            return 1
        }
        if ! mv "$temp_config_new" "$temp_config" 2>/dev/null; then
            log_error "Failed to update temporary config file"
            set -e
            rm -f "$temp_config" "$temp_config_new"
            return 1
        fi
    fi
    
    # Re-enable exit on error
    set -e
    
    # Read the updated config and escape for JSON
    local updated_config
    updated_config=$(cat "$temp_config") || {
        log_error "Failed to read updated config from temporary file"
        rm -f "$temp_config" "$temp_config_new"
        return 1
    }
    
    # Escape JSON special characters
    updated_config=$(echo "$updated_config" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    # Convert newlines to \n for JSON
    updated_config=$(echo "$updated_config" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    
    # Apply the updated config
    local patch_output
    patch_output=$(oc patch configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --type merge \
        -p "{\"data\":{\"config.yaml\":\"$updated_config\"}}" 2>&1)
    local patch_exit=$?
    if [[ $patch_exit -eq 0 ]]; then
        rm -f "$temp_config" "$temp_config_new"
        log_success "Enabled AlertManager for user workloads"
        log_info "AlertManager pods will start shortly (may take a few minutes)"
        return 0
    else
        rm -f "$temp_config" "$temp_config_new"
        log_error "Failed to enable AlertManager"
        log_error "Error: $patch_output"
        log_error "This requires cluster-admin permissions"
        if [[ "${VERBOSE:-false}" == "true" ]]; then
            log_info "Debug: Updated config (first 500 chars):"
            log_info "$(echo "$updated_config" | head -c 500)"
        fi
        return 1
    fi
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
        
        # If subscription is healthy and CSV matches installedCSV, we're good
        if [[ "$subscription_healthy" == "true" ]] && [[ "$csv_name" == "$installed_csv" ]] && [[ "$csv_phase" == "Succeeded" ]]; then
            log_success "COO operator is already installed and healthy (CSV: $csv_name, phase: $csv_phase)"
            return 0
        fi
        
        # Check if CSV is owned by a subscription (only warn if subscription is not healthy or CSV doesn't match)
        local csv_owner=$(oc get csv "$csv_name" -n openshift-operators -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Subscription")].name}' 2>/dev/null || echo "")
        
        if [[ -z "$csv_owner" ]]; then
            # Only warn if subscription is not healthy or CSV doesn't match installedCSV
            if [[ "$subscription_healthy" == "false" ]] || [[ "$csv_name" != "$installed_csv" ]]; then
                log_warn "CSV $csv_name exists but is not owned by a subscription"
                if [[ "$subscription_exists" == "true" ]] && [[ "$subscription_healthy" == "false" ]]; then
                    log_info "Subscription exists but CSV is not linked. This may cause resolution issues."
                    log_info "To fix: delete the CSV and let the subscription reinstall it:"
                    log_info "  oc delete csv $csv_name -n openshift-operators"
                fi
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
    
    # Use common function to find ThanosQuerier pod
    local thanos_pod=$(find_thanosquerier_pod "$NAMESPACE")
    
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
    
    # Use common function to find Prometheus pod (prefer COO labels for COO deployments)
    local prometheus_pod=$(find_prometheus_pod "$NAMESPACE" "true")
    if [[ -z "$prometheus_pod" ]]; then
        log_warn "Prometheus pod not found, skipping federation verification"
        return 1
    fi
    
    # Check prerequisites before verifying federation
    local token_secret_name="eip-monitoring-stack-prometheus-token"
    local service_account="eip-monitoring-stack-prometheus"
    
    # Check if token secret exists
    if ! oc get secret "$token_secret_name" -n "$NAMESPACE" &>/dev/null; then
        log_error "Federation token secret '$token_secret_name' not found!"
        log_info "Attempting to create federation token..."
        setup_federation_token || {
            log_error "Failed to create federation token. Federation will not work."
            log_info "To fix manually:"
            log_info "  1. Ensure service account exists: oc get sa $service_account -n $NAMESPACE"
            log_info "  2. Create token: oc create token $service_account -n $NAMESPACE --duration=8760h"
            log_info "  3. Create secret: oc create secret generic $token_secret_name -n $NAMESPACE --from-literal=token=<token>"
            log_info "  4. Restart Prometheus pods: oc delete pods -n $NAMESPACE -l app.kubernetes.io/name=prometheus"
            return 1
        }
    fi
    
    # Check if RBAC is applied
    if ! oc get clusterrolebinding eip-monitoring-stack-prometheus-federation &>/dev/null; then
        log_warn "Federation RBAC ClusterRoleBinding not found!"
        log_info "Applying federation RBAC..."
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local project_root="$(dirname "$script_dir")"
        local rbac_file="${project_root}/k8s/monitoring/coo/rbac/prometheus-federation-rbac.yaml"
        if [[ -f "$rbac_file" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                oc apply -f "$rbac_file" || log_warn "Failed to apply federation RBAC"
            else
                oc apply -f "$rbac_file" &>/dev/null || log_warn "Failed to apply federation RBAC"
            fi
        else
            log_warn "Federation RBAC file not found: $rbac_file"
        fi
    fi
    
    # Check federation target health
    # Note: Federation can take time to initialize (ScrapeConfig reconciliation, Prometheus discovery)
    log_info "Checking federation target health (this may take up to 60s for ScrapeConfig to be reconciled)..."
    local max_retries=12
    local retry=0
    local federation_healthy=false
    local auth_error_count=0
    local last_log_time=0
    local log_interval=15  # Only log warnings every 15 seconds to reduce noise
    
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
        print(f'{health}|{error[:200]}')
    else:
        print('not_found|')
except:
    print('error|Failed to parse targets')
" 2>/dev/null || echo "error|Failed to check targets")
            
            local health=$(echo "$federation_targets" | cut -d'|' -f1)
            local error=$(echo "$federation_targets" | cut -d'|' -f2)
            local elapsed=$((retry * 5))
            
            if [[ "$health" == "up" ]]; then
                federation_healthy=true
                log_success "Federation target is healthy"
                break
            elif [[ "$health" == "down" ]]; then
                if [[ -n "$error" ]]; then
                    # Check for authentication errors (always log these)
                    if echo "$error" | grep -qiE "401|unauthorized|authentication|forbidden"; then
                        auth_error_count=$((auth_error_count + 1))
                        if [[ $auth_error_count -ge 3 ]]; then
                            log_error "Federation authentication failed (401 Unauthorized) - persistent auth issue detected"
                            log_info "Diagnostics:"
                            log_info "  1. Check token secret exists: oc get secret $token_secret_name -n $NAMESPACE"
                            log_info "  2. Check token is valid: oc get secret $token_secret_name -n $NAMESPACE -o jsonpath='{.data.token}' | base64 -d | wc -c"
                            log_info "  3. Check RBAC is applied: oc get clusterrolebinding eip-monitoring-stack-prometheus-federation"
                            log_info "  4. Check service account: oc get sa $service_account -n $NAMESPACE"
                            log_info "  5. Recreate token: oc create token $service_account -n $NAMESPACE --duration=8760h"
                            log_info "  6. Update secret: oc create secret generic $token_secret_name -n $NAMESPACE --from-literal=token=<new-token> --dry-run=client -o yaml | oc apply -f -"
                            log_info "  7. Restart Prometheus pods to pick up new token: oc delete pods -n $NAMESPACE -l app.kubernetes.io/name=prometheus"
                            return 1
                        else
                            # Log auth errors immediately (they're important)
                            log_warn "Federation authentication error (attempt $auth_error_count/3): $error"
                        fi
                    elif [[ $elapsed -ge $last_log_time ]] && [[ $((elapsed % log_interval)) -eq 0 ]]; then
                        # Only log non-auth errors periodically to reduce noise
                        log_info "Federation target is down (${elapsed}s elapsed, will continue checking...)"
                        last_log_time=$elapsed
                    fi
                elif [[ $elapsed -ge $last_log_time ]] && [[ $((elapsed % log_interval)) -eq 0 ]]; then
                    log_info "Federation target not ready yet (${elapsed}s elapsed, will continue checking...)"
                    last_log_time=$elapsed
                fi
            elif [[ "$health" == "unknown" ]]; then
                # Only log "unknown" status periodically
                if [[ $elapsed -ge $last_log_time ]] && [[ $((elapsed % log_interval)) -eq 0 ]]; then
                    log_info "Federation target health is unknown (${elapsed}s elapsed, may still be initializing...)"
                    last_log_time=$elapsed
                fi
            elif [[ "$health" == "not_found" ]]; then
                # ScrapeConfig may not be discovered yet - this is normal early on
                if [[ $elapsed -ge $last_log_time ]] && [[ $((elapsed % log_interval)) -eq 0 ]]; then
                    log_info "Federation target not found yet (${elapsed}s elapsed, ScrapeConfig may still be reconciling...)"
                    last_log_time=$elapsed
                fi
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
        # Federation verification failed, but this is non-blocking
        if [[ $auth_error_count -ge 3 ]]; then
            log_error "Federation authentication failed after $max_retries retries"
            log_error "Persistent authentication errors detected. Please fix authentication issues before retrying."
            log_info "You can check federation status with: oc exec -n $NAMESPACE $prometheus_pod -- curl -s http://localhost:9090/api/v1/targets | grep -i federation"
            return 1
        else
            log_warn "Federation target verification failed after $max_retries retries (${max_retries} * 5s = $((max_retries * 5))s total)"
            log_info "This is expected if Prometheus was just deployed - federation can take several minutes to initialize"
            log_info "Federation will continue to initialize in the background. This is non-blocking."
            log_info "You can check federation status later with: oc exec -n $NAMESPACE $prometheus_pod -- curl -s http://localhost:9090/api/v1/targets | grep -i federation"
            # Return 0 (success) since this is non-blocking - deployment can continue
            return 0
        fi
    fi
}

# Configure UWM persistent storage
configure_uwm_persistent_storage() {
    log_info "Configuring persistent storage for UWM Prometheus..."
    
    # Get current config
    local uwm_config=$(oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    # Check if persistent storage is already configured
    if echo "$uwm_config" | grep -qE "prometheus:\s*$" && echo "$uwm_config" | grep -A 10 "^prometheus:" | grep -qE "^\s*volumeClaimTemplate:"; then
        log_info "Persistent storage already configured for UWM Prometheus"
        return 0
    fi
    
    # Use a temporary file to safely update the YAML
    local temp_config=$(mktemp)
    if [[ -n "$uwm_config" ]]; then
        echo "$uwm_config" > "$temp_config"
    else
        # Create empty config
        echo "" > "$temp_config"
    fi
    
    local temp_config_new="${temp_config}.new"
    
    # Add or update prometheus section with persistent storage
    if grep -q "^prometheus:" "$temp_config" 2>/dev/null; then
        # Update existing prometheus section - add volumeClaimTemplate if missing
        if ! grep -A 10 "^prometheus:" "$temp_config" | grep -qE "^\s*volumeClaimTemplate:"; then
            # Add volumeClaimTemplate after prometheus:
            awk '
            /^prometheus:/ {
                print
                print "  volumeClaimTemplate:"
                print "    spec:"
                print "      accessModes:"
                print "      - ReadWriteOnce"
                print "      resources:"
                print "        requests:"
                print "          storage: 50Gi"
                next
            }
            { print }
            ' "$temp_config" > "$temp_config_new" 2>/dev/null || {
                log_error "Failed to update UWM config with persistent storage"
                rm -f "$temp_config" "$temp_config_new"
                return 1
            }
        else
            # volumeClaimTemplate already exists, just log
            log_info "Persistent storage already configured in UWM config"
            rm -f "$temp_config" "$temp_config_new"
            return 0
        fi
    else
        # Add new prometheus section
        cat "$temp_config" > "$temp_config_new"
        if [[ -n "$uwm_config" ]]; then
            echo "" >> "$temp_config_new"
        fi
        echo "prometheus:" >> "$temp_config_new"
        echo "  volumeClaimTemplate:" >> "$temp_config_new"
        echo "    spec:" >> "$temp_config_new"
        echo "      accessModes:" >> "$temp_config_new"
        echo "      - ReadWriteOnce" >> "$temp_config_new"
        echo "      resources:" >> "$temp_config_new"
        echo "        requests:" >> "$temp_config_new"
        echo "          storage: 50Gi" >> "$temp_config_new"
    fi
    
    # Update the ConfigMap
    local updated_config=$(cat "$temp_config_new")
    # Escape special characters for JSON
    updated_config=$(echo "$updated_config" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    updated_config=$(echo "$updated_config" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
    
    if oc patch configmap user-workload-monitoring-config -n openshift-user-workload-monitoring --type merge \
        -p "{\"data\":{\"config.yaml\":\"$updated_config\"}}" &>/dev/null; then
        log_success "Persistent storage configured for UWM Prometheus (50Gi)"
        rm -f "$temp_config" "$temp_config_new"
        return 0
    else
        log_error "Failed to configure persistent storage for UWM Prometheus"
        log_error "This requires cluster-admin permissions"
        rm -f "$temp_config" "$temp_config_new"
        return 1
    fi
}

# Configure COO monitoring stack
configure_coo_monitoring_stack() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local monitoringstack_file="${project_root}/k8s/monitoring/coo/monitoring/monitoringstack-coo.yaml"
    
    if [[ ! -f "$monitoringstack_file" ]]; then
        log_error "COO MonitoringStack file not found: $monitoringstack_file"
        return 1
    fi
    
    oc_cmd_silent apply -f "$monitoringstack_file" || {
        log_error "Failed to deploy COO MonitoringStack"
        return 1
    }
    
    # Configure persistent storage if explicitly requested
    if [[ "${PERSISTENT_STORAGE:-false}" == "true" ]]; then
        log_info "Configuring persistent storage for COO Prometheus..."
        # Check if persistent storage is already configured
        local existing_pvc=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.spec.prometheusConfig.persistentVolumeClaim}' 2>/dev/null || echo "")
        if [[ -n "$existing_pvc" ]] && [[ "$existing_pvc" != "null" ]]; then
            log_info "Persistent storage already configured for COO Prometheus"
        else
            # Patch MonitoringStack to enable persistent storage
            # Default: 50Gi storage, ReadWriteOnce access mode
            oc_cmd_silent patch monitoringstack eip-monitoring-stack -n "$NAMESPACE" --type merge \
                -p '{
                    "spec": {
                        "prometheusConfig": {
                            "persistentVolumeClaim": {
                                "accessModes": ["ReadWriteOnce"],
                                "resources": {
                                    "requests": {
                                        "storage": "50Gi"
                                    }
                                }
                            }
                        }
                    }
                }' || {
                log_warn "Failed to configure persistent storage for COO MonitoringStack"
            }
            log_success "Persistent storage configured for COO Prometheus (50Gi)"
        fi
    else
        # Don't modify existing persistent storage configuration - leave it as-is (idempotent)
        local existing_pvc=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.spec.prometheusConfig.persistentVolumeClaim}' 2>/dev/null || echo "")
        if [[ -n "$existing_pvc" ]] && [[ "$existing_pvc" != "null" ]]; then
            log_info "Persistent storage is already configured (leaving as-is)"
        else
            log_info "Using default ephemeral storage (persistent storage not configured)"
        fi
    fi
    
    # Ensure MonitoringStack has the required label for ThanosQuerier discovery
    local part_of_label=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || echo "")
    if [[ "$part_of_label" != "eip-monitoring-stack" ]]; then
        oc_cmd_silent patch monitoringstack eip-monitoring-stack -n "$NAMESPACE" --type merge \
            -p '{"metadata":{"labels":{"app.kubernetes.io/part-of":"eip-monitoring-stack"}}}' || {
            log_warn "Failed to add label to MonitoringStack (this may affect ThanosQuerier store discovery)"
        }
        # Wait a moment for the label to be applied
        sleep 2
    fi
    
    # Wait for Prometheus pods
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local prom_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null || echo "0")
        prom_pods=$(echo "$prom_pods" | tr -d '[:space:]')
        if [[ "$prom_pods" =~ ^[0-9]+$ ]] && [[ "$prom_pods" -gt 0 ]]; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
        if [[ $((waited % 30)) -eq 0 ]] && [[ "${VERBOSE:-false}" == "true" ]]; then
            log_info "Still waiting for COO Prometheus... (${waited}s)"
        fi
    done
}

# Generic function to clean up all resources owned by a parent resource using ownerReferences
# Usage: cleanup_owned_resources <parent_kind> <parent_name> [parent_namespace] [target_namespace]
#   parent_kind: Kubernetes kind of the parent resource (e.g., "MonitoringStack", "UIPlugin")
#   parent_name: Name of the parent resource
#   parent_namespace: Namespace of the parent resource (optional, for namespace-scoped parents)
#   target_namespace: Namespace to search for owned resources (optional, defaults to parent_namespace or all namespaces)
# Returns: Number of resources cleaned up
cleanup_owned_resources() {
    local parent_kind="$1"
    local parent_name="$2"
    local parent_namespace="${3:-}"
    local target_namespace="${4:-${parent_namespace}}"
    
    if [[ -z "$parent_kind" ]] || [[ -z "$parent_name" ]]; then
        log_warn "cleanup_owned_resources: parent_kind and parent_name are required"
        return 0
    fi
    
    # Get the parent resource UID
    local parent_uid=""
    if [[ -n "$parent_namespace" ]]; then
        parent_uid=$(oc get "$parent_kind" "$parent_name" -n "$parent_namespace" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
    else
        parent_uid=$(oc get "$parent_kind" "$parent_name" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo "")
    fi
    
    if [[ -z "$parent_uid" ]]; then
        # Parent resource doesn't exist or couldn't be retrieved
        return 0
    fi
    
    local resources_cleaned=0
    
    # Comprehensive list of resource types to check
    local ns_resource_types=(
        "deployment" "service" "pod" "configmap" "secret" "serviceaccount" 
        "role" "rolebinding" "replicaset" "daemonset" "statefulset"
        "ingress" "route" "networkpolicy" "persistentvolumeclaim"
        "servicemonitor" "prometheusrule" "scrapeconfig" "alertmanagerconfig"
    )
    
    local cluster_resource_types=(
        "clusterrole" "clusterrolebinding"
    )
    
    # Check namespace-scoped resources
    # Only search namespaces if target_namespace is specified or parent is namespace-scoped
    # For cluster-scoped parents without target_namespace, skip namespace search (too slow and usually unnecessary)
    if [[ -n "$target_namespace" ]] || [[ -n "$parent_namespace" ]]; then
        local search_namespaces=()
        if [[ -n "$target_namespace" ]]; then
            search_namespaces=("$target_namespace")
        elif [[ -n "$parent_namespace" ]]; then
            # If parent is namespace-scoped, search in parent's namespace
            search_namespaces=("$parent_namespace")
        fi
        
        for resource_type in "${ns_resource_types[@]}"; do
            for ns in "${search_namespaces[@]}"; do
                local resources=$(oc get "$resource_type" -n "$ns" -o json 2>/dev/null || echo "{}")
                
                if command -v jq &>/dev/null && [[ "$resources" != "{}" ]]; then
                    local owned_resources=$(echo "$resources" | jq -r --arg uid "$parent_uid" --arg kind "$parent_kind" --arg name "$parent_name" \
                        '.items[] | select(.metadata.ownerReferences[]? | .uid == $uid and .kind == $kind and .name == $name) | .metadata.name' 2>/dev/null || echo "")
                    
                    if [[ -n "$owned_resources" ]]; then
                        for resource_name in $owned_resources; do
                            if [[ "$VERBOSE" == "true" ]]; then
                                log_info "  Deleting $resource_type/$resource_name in namespace $ns (owned by $parent_kind $parent_name)..."
                            fi
                            
                            # Actually delete and check if it succeeded
                            local delete_output
                            local delete_exit
                            if [[ "$VERBOSE" == "true" ]]; then
                                delete_output=$(oc delete "$resource_type" "$resource_name" -n "$ns" --wait=false --timeout=10s --cascade=background 2>&1)
                                delete_exit=$?
                            else
                                delete_output=$(oc delete "$resource_type" "$resource_name" -n "$ns" --wait=false --timeout=10s --cascade=background 2>&1)
                                delete_exit=$?
                            fi
                            
                            # Check if deletion succeeded (exit code 0 and no error messages)
                            if [[ $delete_exit -eq 0 ]] && ! echo "$delete_output" | grep -qE "(Error|error|not found|No resources found)"; then
                                ((resources_cleaned++))
                                if [[ "$VERBOSE" == "true" ]]; then
                                    log_info "    ✓ Deleted $resource_type/$resource_name"
                                fi
                            else
                                # Show error in verbose mode
                                if [[ "$VERBOSE" == "true" ]]; then
                                    log_warn "    ⚠ Failed to delete $resource_type/$resource_name: $(echo "$delete_output" | head -1)"
                                fi
                            fi
                        done
                    fi
                fi
            done
        done
    fi
    
    # Check cluster-scoped resources
    for resource_type in "${cluster_resource_types[@]}"; do
        local resources=$(oc get "$resource_type" -o json 2>/dev/null || echo "{}")
        
        if command -v jq &>/dev/null && [[ "$resources" != "{}" ]]; then
            local owned_resources=$(echo "$resources" | jq -r --arg uid "$parent_uid" --arg kind "$parent_kind" --arg name "$parent_name" \
                '.items[] | select(.metadata.ownerReferences[]? | .uid == $uid and .kind == $kind and .name == $name) | .metadata.name' 2>/dev/null || echo "")
            
            if [[ -n "$owned_resources" ]]; then
                for resource_name in $owned_resources; do
                    if [[ "$VERBOSE" == "true" ]]; then
                        log_info "  Deleting $resource_type/$resource_name (owned by $parent_kind $parent_name)..."
                    fi
                    
                    # Actually delete and check if it succeeded
                    local delete_output
                    local delete_exit
                    if [[ "$VERBOSE" == "true" ]]; then
                        delete_output=$(oc delete "$resource_type" "$resource_name" --wait=false --timeout=10s --cascade=background 2>&1)
                        delete_exit=$?
                    else
                        delete_output=$(oc delete "$resource_type" "$resource_name" --wait=false --timeout=10s --cascade=background 2>&1)
                        delete_exit=$?
                    fi
                    
                    # Check if deletion succeeded (exit code 0 and no error messages)
                    if [[ $delete_exit -eq 0 ]] && ! echo "$delete_output" | grep -qE "(Error|error|not found|No resources found)"; then
                        ((resources_cleaned++))
                        if [[ "$VERBOSE" == "true" ]]; then
                            log_info "    ✓ Deleted $resource_type/$resource_name"
                        fi
                    else
                        # Show error in verbose mode
                        if [[ "$VERBOSE" == "true" ]]; then
                            log_warn "    ⚠ Failed to delete $resource_type/$resource_name: $(echo "$delete_output" | head -1)"
                        fi
                    fi
                done
            fi
        fi
    done
    
    echo "$resources_cleaned"
}

# Remove COO monitoring
# COO Dependency Tree (deletion order):
# 1. Console operator spec.plugins (remove references)
# 2. ConsolePlugin (created by UIPlugin, referenced by Console operator)
# 3. UIPlugin (managed by COO operator, creates ConsolePlugin, Perses, korrel8r)
# 4. Perses resources (created by UIPlugin, may not have ownerReferences)
# 5. MonitoringStack (managed by COO operator, creates Prometheus, Alertmanager)
# 6. ThanosQuerier (depends on MonitoringStack's Prometheus)
# 7. AlertmanagerConfig (used by MonitoringStack)
# 8. ScrapeConfig (used by MonitoringStack)
# 9. ServiceMonitor, PrometheusRule, NetworkPolicy (user-created, used by MonitoringStack)
# 10. Federation resources (secrets, RBAC)
# 11. COO operator subscription (deletes CSV and operator, which manages all above)
# 12. Orphaned CSVs
# 13. CRDs (optional, after all resources deleted)
remove_coo_monitoring() {
    log_info "Removing COO monitoring infrastructure..."
    log_info "Following COO dependency tree for proper deletion order..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # ============================================================================
    # STEP 1: Remove from Console operator spec.plugins
    # ============================================================================
    # This must happen FIRST so ConsolePlugin can be deleted
    # ConsolePlugin is referenced by Console operator, so we need to remove the reference first
    log_info "Step 1: Removing ConsolePlugin references from Console operator..."
    local console_plugin_names=(
        "troubleshooting-panel-console-plugin"
        "monitoring-console-plugin"
    )
    
    if oc get console.operator.openshift.io cluster &>/dev/null; then
        local plugins_removed=false
        
        # Remove plugins from Console operator spec.plugins
        if command -v jq &>/dev/null; then
            local console_json=$(oc get console.operator.openshift.io cluster -o json 2>/dev/null || echo "")
            if [[ -n "$console_json" ]]; then
                # Remove each plugin one by one
                for console_plugin_name in "${console_plugin_names[@]}"; do
                    # Check if plugin exists in spec.plugins
                    if echo "$console_json" | jq -e ".spec.plugins[]? | select(. == \"${console_plugin_name}\")" &>/dev/null; then
                        log_info "Removing $console_plugin_name from Console operator spec.plugins..."
                        # Remove the plugin from the array using jq
                        local updated_plugins=$(echo "$console_json" | jq --arg plugin "$console_plugin_name" \
                            '.spec.plugins // [] | map(select(. != $plugin))' 2>/dev/null)
                        
                        if [[ -n "$updated_plugins" ]]; then
                            if oc patch console.operator.openshift.io cluster --type=json \
                                -p "[{\"op\": \"replace\", \"path\": \"/spec/plugins\", \"value\": $updated_plugins}]" &>/dev/null; then
                                log_success "  ✓ Removed $console_plugin_name from Console operator"
                                plugins_removed=true
                                # Update console_json for next iteration
                                console_json=$(oc get console.operator.openshift.io cluster -o json 2>/dev/null || echo "")
                            else
                                log_warn "  ⚠ Failed to remove $console_plugin_name from Console operator (may require cluster-admin)"
                            fi
                        fi
                    fi
                done
            fi
        else
            # Fallback: remove plugins one by one using JSON patch remove operation
            for console_plugin_name in "${console_plugin_names[@]}"; do
                # Check if plugin exists in spec.plugins
                local plugin_index=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins[?(@=="'${console_plugin_name}'")]}' 2>/dev/null | wc -l | tr -d '[:space:]')
                if [[ "$plugin_index" -gt 0 ]]; then
                    log_info "Removing $console_plugin_name from Console operator spec.plugins..."
                    # Find the index of the plugin in the array
                    local idx=0
                    local found_idx=""
                    local plugins_array=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
                    for plugin in $plugins_array; do
                        if [[ "$plugin" == "$console_plugin_name" ]]; then
                            found_idx=$idx
                            break
                        fi
                        ((idx++))
                    done
                    
                    if [[ -n "$found_idx" ]]; then
                        # Use JSON patch to remove by index
                        if oc patch console.operator.openshift.io cluster --type=json \
                            -p "[{\"op\": \"remove\", \"path\": \"/spec/plugins/$found_idx\"}]" &>/dev/null; then
                            log_success "  ✓ Removed $console_plugin_name from Console operator"
                            plugins_removed=true
                        else
                            log_warn "  ⚠ Failed to remove $console_plugin_name from Console operator (may require cluster-admin)"
                        fi
                    fi
                fi
            done
        fi
        
        if [[ "$plugins_removed" == "true" ]]; then
            log_info "Waiting for Console operator to process plugin removal..."
            sleep 5
        fi
    else
        log_info "Console operator resource not found, skipping plugin removal from spec.plugins"
    fi
    
    # ============================================================================
    # STEP 2: Delete ConsolePlugin resources
    # ============================================================================
    # ConsolePlugin is created by UIPlugin, but must be deleted before UIPlugin
    # because Console operator may have references to it
    log_info "Step 2: Deleting ConsolePlugin resources..."
    local console_plugin_deleted=0
    
    for console_plugin_name in "${console_plugin_names[@]}"; do
        if oc get consoleplugin "$console_plugin_name" &>/dev/null; then
            # Clean up resources owned by ConsolePlugin
            log_info "Cleaning up resources owned by ConsolePlugin $console_plugin_name..."
            local plugin_owned_count=$(cleanup_owned_resources "ConsolePlugin" "$console_plugin_name" "" "")
            if [[ $plugin_owned_count -gt 0 ]]; then
                log_success "Cleaned up $plugin_owned_count resource(s) owned by ConsolePlugin $console_plugin_name"
            fi
            
            log_info "Deleting ConsolePlugin: $console_plugin_name..."
            if [[ "$VERBOSE" == "true" ]]; then
                if oc delete consoleplugin "$console_plugin_name" --wait=false --timeout=10s --cascade=background 2>&1 | grep -vE "(not found|No resources found|Error from server)"; then
                    ((console_plugin_deleted++))
                fi
            else
                if oc delete consoleplugin "$console_plugin_name" --wait=false --timeout=10s --cascade=background &>/dev/null 2>&1; then
                    ((console_plugin_deleted++))
                fi
            fi
        fi
    done
    
    # Also try to find and delete any ConsolePlugin resources that might exist
    local all_console_plugins=$(oc get consoleplugin -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$all_console_plugins" ]]; then
        for plugin in $all_console_plugins; do
            # Check if it's one of our COO plugins (contains "monitoring" or "troubleshooting")
            if echo "$plugin" | grep -qE "(monitoring|troubleshooting)"; then
                local plugin_owned_count=$(cleanup_owned_resources "ConsolePlugin" "$plugin" "" "")
                if [[ $plugin_owned_count -gt 0 ]]; then
                    log_success "Cleaned up $plugin_owned_count resource(s) owned by ConsolePlugin $plugin"
                fi
                
                if [[ "$VERBOSE" == "true" ]]; then
                    log_info "Deleting ConsolePlugin: $plugin..."
                    oc delete consoleplugin "$plugin" --wait=false --timeout=10s --cascade=background 2>&1 | grep -vE "(not found|No resources found|Error from server)" || true
                else
                    oc delete consoleplugin "$plugin" --wait=false --timeout=10s --cascade=background &>/dev/null 2>&1 || true
                fi
            fi
        done
    fi
    
    if [[ $console_plugin_deleted -gt 0 ]]; then
        log_success "Removed $console_plugin_deleted ConsolePlugin resource(s)"
    else
        log_info "No ConsolePlugin resources found to remove (or already removed)"
    fi
    
    # ============================================================================
    # STEP 3: Delete UIPlugin resources
    # ============================================================================
    # UIPlugin is managed by COO operator and creates ConsolePlugin, Perses, korrel8r
    # Delete UIPlugin to cascade delete owned resources, but handle finalizers
    # If deletion fails, the operator subscription deletion (Step 11) will clean it up
    log_info "Step 3: Deleting UIPlugin resources..."
    
    # First, find all existing UIPlugin resources (dynamically)
    local ui_plugin_list=$(oc get uiplugin -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    local ui_plugin_names=()
    
    if [[ -n "$ui_plugin_list" ]]; then
        # Add found plugins to the list
        for plugin in $ui_plugin_list; do
            ui_plugin_names+=("$plugin")
        done
    fi
    
    # Also check for common plugin names (in case they exist but weren't found above)
    local common_plugin_names=(
        "monitoring"
        "troubleshooting-panel"
        "troubleshooting"
    )
    for plugin_name in "${common_plugin_names[@]}"; do
        if oc get uiplugin "$plugin_name" &>/dev/null; then
            # Add if not already in the list
            # Use safe array access to avoid unbound variable error with set -u
            local already_in_list=false
            if [[ ${#ui_plugin_names[@]} -gt 0 ]]; then
                for existing_plugin in "${ui_plugin_names[@]}"; do
                    if [[ "$existing_plugin" == "$plugin_name" ]]; then
                        already_in_list=true
                        break
                    fi
                done
            fi
            if [[ "$already_in_list" == "false" ]]; then
                ui_plugin_names+=("$plugin_name")
            fi
        fi
    done
    
    # Delete UIPlugin resources - this will cascade delete all owned resources
    log_info "Deleting UIPlugin resources (this will cascade delete all owned resources)..."
    local deleted_count=0
    # Use safe array access to avoid unbound variable error with set -u
    if [[ ${#ui_plugin_names[@]} -eq 0 ]]; then
        log_info "No UIPlugin resources found to delete"
    else
        for plugin_name in "${ui_plugin_names[@]}"; do
            if oc get uiplugin "$plugin_name" &>/dev/null; then
                log_info "Deleting UIPlugin: $plugin_name (will cascade delete owned resources)..."
                
                # Check for finalizers that might prevent deletion
                local finalizers=$(oc get uiplugin "$plugin_name" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
                if [[ -n "$finalizers" ]]; then
                    log_info "  UIPlugin has finalizers: $finalizers"
                    log_info "  Attempting to remove finalizers to allow deletion..."
                    local patch_output=""
                    local patch_exit=0
                    # Use set +e to prevent exit on error, then restore
                    set +e
                    patch_output=$(oc patch uiplugin "$plugin_name" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>&1)
                    patch_exit=$?
                    set -e
                    
                    if [[ $patch_exit -eq 0 ]]; then
                        if [[ "$VERBOSE" == "true" ]] && [[ -n "$patch_output" ]]; then
                            echo "$patch_output" | grep -vE "(not found|No resources found)" || true
                        fi
                        log_info "  ✓ Finalizers removed successfully"
                    else
                        log_warn "  ⚠ Failed to remove finalizers (exit code: $patch_exit)"
                        if [[ "$VERBOSE" == "true" ]] && [[ -n "$patch_output" ]]; then
                            log_warn "  Patch output: $patch_output"
                        fi
                    fi
                    log_info "  Waiting for finalizer removal to take effect..."
                    sleep 3
                fi
            
            local delete_output
            local delete_exit
            log_info "  Attempting to delete UIPlugin: $plugin_name..."
            if [[ "$VERBOSE" == "true" ]]; then
                delete_output=$(oc delete uiplugin "$plugin_name" --wait=false --timeout=30s --cascade=background 2>&1)
                delete_exit=$?
            else
                delete_output=$(oc delete uiplugin "$plugin_name" --wait=false --timeout=30s --cascade=background 2>&1)
                delete_exit=$?
            fi
            
            # Check if deletion succeeded or if resource is being deleted
            if [[ $delete_exit -eq 0 ]]; then
                # Check if the resource was actually deleted or is being deleted
                if echo "$delete_output" | grep -qE "(deleted|marked for deletion)"; then
                    log_success "  ✓ Deleted UIPlugin $plugin_name"
                    ((deleted_count++))
                else
                    log_info "  UIPlugin deletion command succeeded, checking status..."
                fi
            else
                # Check if it's stuck in deletion (has deletionTimestamp)
                local deletion_timestamp=$(oc get uiplugin "$plugin_name" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo "")
                if [[ -n "$deletion_timestamp" ]]; then
                    log_warn "  ⚠ UIPlugin $plugin_name is stuck in deletion (deletionTimestamp: $deletion_timestamp)"
                    log_info "  Removing finalizers to force deletion..."
                    local force_patch_output
                    force_patch_output=$(oc patch uiplugin "$plugin_name" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>&1) || true
                    if [[ "$VERBOSE" == "true" ]] && [[ -n "$force_patch_output" ]]; then
                        echo "$force_patch_output" | grep -vE "(not found|No resources found)" || true
                    fi
                    sleep 2
                    # Try deleting again
                    local force_delete_output
                    force_delete_output=$(oc delete uiplugin "$plugin_name" --wait=false --timeout=10s --force --grace-period=0 2>&1) || true
                    if echo "$force_delete_output" | grep -qE "(deleted|marked for deletion)"; then
                        log_success "  ✓ Force deleted UIPlugin $plugin_name"
                        ((deleted_count++))
                    elif [[ "$VERBOSE" == "true" ]]; then
                        log_warn "  ⚠ Force delete output: $(echo "$force_delete_output" | head -1)"
                    fi
                else
                    if [[ "$VERBOSE" == "true" ]]; then
                        log_warn "  ⚠ Failed to delete UIPlugin $plugin_name: $(echo "$delete_output" | head -1)"
                    else
                        log_warn "  ⚠ Failed to delete UIPlugin $plugin_name (use --verbose for details)"
                    fi
                    # If deletion failed and COO operator subscription exists, suggest deleting it first
                    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
                        log_warn "  ⚠ UIPlugin deletion failed. The COO operator may be preventing deletion."
                        log_info "  Tip: The COO operator subscription will be deleted later in the cleanup process."
                        log_info "  If UIPlugin still exists after operator deletion, it should be cleaned up automatically."
                    fi
                fi
            fi
            fi
        done
    fi
    
    # Wait a moment for cascade deletion to start
    if [[ $deleted_count -gt 0 ]]; then
        log_info "Waiting for cascade deletion to process (5 seconds)..."
        sleep 5
    fi
    
    # Now clean up any remaining resources that might not have been cascade deleted
    # This handles cases where ownerReferences might not be set correctly
    local total_resources_cleaned=0
    # Use safe array access to avoid unbound variable error with set -u
    if [[ ${#ui_plugin_names[@]} -gt 0 ]]; then
        for plugin_name in "${ui_plugin_names[@]}"; do
            # Only check if UIPlugin was deleted (if it still exists, resources might be recreated)
            if ! oc get uiplugin "$plugin_name" &>/dev/null; then
                log_info "Cleaning up any remaining resources for UIPlugin: $plugin_name"
                
                # Use the reusable function to clean up all owned resources
                # UIPlugin is cluster-scoped (no namespace), but we search in openshift-operators namespace
                local plugin_resources_cleaned=$(cleanup_owned_resources "UIPlugin" "$plugin_name" "" "openshift-operators")
                total_resources_cleaned=$((total_resources_cleaned + plugin_resources_cleaned))
                
                # Fallback: Check for resources that might be created by the COO operator for UIPlugins
                # These might not have ownerReferences but could be related (e.g., korrel8r for troubleshooting plugin)
                if [[ "$plugin_name" == *"troubleshooting"* ]]; then
                    # Troubleshooting plugin creates korrel8r resources
                    local related_labels=("app.kubernetes.io/instance=korrel8r" "app=korrel8r")
                    for label in "${related_labels[@]}"; do
                        for resource_type in "deployment" "service" "pod" "replicaset"; do
                            if oc get "$resource_type" -n openshift-operators -l "$label" &>/dev/null; then
                                if [[ "$VERBOSE" == "true" ]]; then
                                    log_info "  Deleting $resource_type with label $label (related to troubleshooting plugin, no ownerReference)..."
                                fi
                                
                                # Actually delete and check if it succeeded
                                local delete_output
                                local delete_exit
                                delete_output=$(oc delete "$resource_type" -n openshift-operators -l "$label" --wait=false --timeout=10s --cascade=background 2>&1)
                                delete_exit=$?
                                
                                # Check if deletion succeeded
                                if [[ $delete_exit -eq 0 ]] && ! echo "$delete_output" | grep -qE "(Error|error|not found|No resources found)"; then
                                    ((plugin_resources_cleaned++))
                                    ((total_resources_cleaned++))
                                    if [[ "$VERBOSE" == "true" ]]; then
                                        log_info "    ✓ Deleted $resource_type with label $label"
                                    fi
                                else
                                    if [[ "$VERBOSE" == "true" ]]; then
                                        log_warn "    ⚠ Failed to delete $resource_type with label $label: $(echo "$delete_output" | head -1)"
                                    fi
                                fi
                            fi
                        done
                    done
                fi
                
                if [[ $plugin_resources_cleaned -gt 0 ]]; then
                    log_success "  Cleaned up $plugin_resources_cleaned remaining resource(s) for UIPlugin $plugin_name"
                fi
            fi
        done
    fi
    
    # Also try label-based deletion (non-blocking) for any remaining plugins
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete uiplugin -l monitoring=coo --wait=false --timeout=5s --cascade=background 2>&1 | grep -vE "(No resources found|not found|Error from server)" || true
        oc delete uiplugin -l coo=eip-monitoring --wait=false --timeout=5s --cascade=background 2>&1 | grep -vE "(No resources found|not found|Error from server)" || true
    else
        oc delete uiplugin -l monitoring=coo --wait=false --timeout=5s --cascade=background &>/dev/null 2>&1 || true
        oc delete uiplugin -l coo=eip-monitoring --wait=false --timeout=5s --cascade=background &>/dev/null 2>&1 || true
    fi
    
    if [[ $deleted_count -gt 0 ]]; then
        log_success "Removed $deleted_count UI plugin(s)"
    else
        log_info "No UI plugins found to remove (or already removed)"
    fi
    
    if [[ $total_resources_cleaned -gt 0 ]]; then
        log_success "Cleaned up $total_resources_cleaned total resource(s) created by UI plugins"
    fi
    
    # ============================================================================
    # STEP 4: Delete Perses resources
    # ============================================================================
    # Perses resources are created by UIPlugin, but may not have ownerReferences
    # Delete them explicitly after UIPlugin is deleted
    log_info "Step 4: Deleting Perses dashboards and datasources..."
    if oc get crd persesdashboards.perses.dev &>/dev/null && oc get crd persesdatasources.perses.dev &>/dev/null; then
        # Delete by label selector (safer - only deletes COO Perses resources)
        # Check if resources exist before attempting deletion
        local perses_monitoring=$(oc get persesdashboard,persesdatasource -n openshift-operators -l monitoring=coo --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        if [[ "$perses_monitoring" =~ ^[0-9]+$ ]] && [[ "$perses_monitoring" -gt 0 ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                oc delete persesdashboard,persesdatasource -n openshift-operators -l monitoring=coo || true
            else
                oc delete persesdashboard,persesdatasource -n openshift-operators -l monitoring=coo &>/dev/null || true
            fi
        fi
        
        local perses_coo=$(oc get persesdashboard,persesdatasource -n openshift-operators -l coo=eip-monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        if [[ "$perses_coo" =~ ^[0-9]+$ ]] && [[ "$perses_coo" -gt 0 ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                oc delete persesdashboard,persesdatasource -n openshift-operators -l coo=eip-monitoring || true
            else
                oc delete persesdashboard,persesdatasource -n openshift-operators -l coo=eip-monitoring &>/dev/null || true
            fi
        fi
        
        # Also delete by name as fallback (in case labels weren't applied)
        if oc get persesdatasource prometheus-coo -n openshift-operators &>/dev/null; then
            if [[ "$VERBOSE" == "true" ]]; then
                oc delete persesdatasource prometheus-coo -n openshift-operators || true
            else
                oc delete persesdatasource prometheus-coo -n openshift-operators &>/dev/null || true
            fi
        fi
        
        # Delete dashboards (list common dashboard names)
        local perses_dashboards=(
            "eip-distribution"
            "eip-distribution-fairness"
            "eip-capacity-planning"
            "eip-health-overview"
            "eip-node-performance"
            "eip-event-correlation"
            "eip-mismatch-analysis"
            "eip-performance-troubleshooting"
            "eip-primary-secondary-analysis"
            "cpic-health"
        )
        for dashboard in "${perses_dashboards[@]}"; do
            if oc get persesdashboard "$dashboard" -n openshift-operators &>/dev/null; then
                if [[ "$VERBOSE" == "true" ]]; then
                    oc delete persesdashboard "$dashboard" -n openshift-operators || true
                else
                    oc delete persesdashboard "$dashboard" -n openshift-operators &>/dev/null || true
                fi
            fi
        done
    else
        log_info "Perses CRDs not found, skipping Perses resource cleanup"
    fi
    
    # ============================================================================
    # STEP 5: Delete MonitoringStack
    # ============================================================================
    # MonitoringStack is managed by COO operator and creates Prometheus, Alertmanager, etc.
    # This must be deleted before ThanosQuerier (which depends on it)
    log_info "Step 5: Deleting MonitoringStack and all resources it owns..."
    if oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
        log_info "Cleaning up resources owned by MonitoringStack eip-monitoring-stack..."
        local owned_count=$(cleanup_owned_resources "MonitoringStack" "eip-monitoring-stack" "$NAMESPACE" "$NAMESPACE")
        if [[ $owned_count -gt 0 ]]; then
            log_success "Cleaned up $owned_count resource(s) owned by MonitoringStack"
        fi
        
        log_info "Deleting COO MonitoringStack..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete monitoringstack eip-monitoring-stack -n "$NAMESPACE" --wait=true --cascade=background || log_warn "Failed to delete MonitoringStack"
        else
            oc delete monitoringstack eip-monitoring-stack -n "$NAMESPACE" --wait=true --cascade=background &>/dev/null || log_warn "Failed to delete MonitoringStack"
        fi
    fi
    
    # ============================================================================
    # STEP 6: Delete ThanosQuerier
    # ============================================================================
    # ThanosQuerier depends on MonitoringStack's Prometheus, so delete it after MonitoringStack
    log_info "Step 6: Deleting ThanosQuerier and all resources it owns..."
    if oc get thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" &>/dev/null; then
        log_info "Cleaning up resources owned by ThanosQuerier eip-monitoring-stack-querier-coo..."
        local querier_owned_count=$(cleanup_owned_resources "ThanosQuerier" "eip-monitoring-stack-querier-coo" "$NAMESPACE" "$NAMESPACE")
        if [[ $querier_owned_count -gt 0 ]]; then
            log_success "Cleaned up $querier_owned_count resource(s) owned by ThanosQuerier"
        fi
        
        log_info "Deleting COO ThanosQuerier..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" --cascade=background || true
        else
            oc delete thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" --cascade=background 2>/dev/null || true
        fi
    fi
    
    # Delete ThanosQuerier Route (may be owned by ThanosQuerier, but delete explicitly as fallback)
    if oc get route thanos-querier-coo -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting COO ThanosQuerier route..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete route thanos-querier-coo -n "$NAMESPACE" --cascade=background || true
        else
            oc delete route thanos-querier-coo -n "$NAMESPACE" --cascade=background 2>/dev/null || true
        fi
    fi
    
    # ============================================================================
    # STEP 7: Delete AlertmanagerConfig
    # ============================================================================
    # AlertmanagerConfig is used by MonitoringStack, delete after MonitoringStack
    log_info "Step 7: Deleting AlertmanagerConfig resources..."
    local alertmanager_configs=$(oc get alertmanagerconfig.monitoring.rhobs -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$alertmanager_configs" ]]; then
        log_info "Cleaning up AlertmanagerConfig resources (monitoring.rhobs) and their owned resources..."
        for config_name in $alertmanager_configs; do
            local config_owned_count=$(cleanup_owned_resources "AlertmanagerConfig" "$config_name" "$NAMESPACE" "$NAMESPACE")
            if [[ $config_owned_count -gt 0 ]]; then
                log_success "Cleaned up $config_owned_count resource(s) owned by AlertmanagerConfig $config_name"
            fi
        done
        
        log_info "Deleting COO AlertmanagerConfig (monitoring.rhobs)..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete alertmanagerconfig.monitoring.rhobs -n "$NAMESPACE" --all --cascade=background || true
        else
            oc delete alertmanagerconfig.monitoring.rhobs -n "$NAMESPACE" --all --cascade=background 2>/dev/null || true
        fi
    fi
    # Also check standard API group as fallback
    local alertmanager_configs_std=$(oc get alertmanagerconfig -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$alertmanager_configs_std" ]]; then
        log_info "Cleaning up AlertmanagerConfig resources (standard API group) and their owned resources..."
        for config_name in $alertmanager_configs_std; do
            local config_owned_count=$(cleanup_owned_resources "AlertmanagerConfig" "$config_name" "$NAMESPACE" "$NAMESPACE")
            if [[ $config_owned_count -gt 0 ]]; then
                log_success "Cleaned up $config_owned_count resource(s) owned by AlertmanagerConfig $config_name"
            fi
        done
        
        log_info "Deleting AlertmanagerConfig (standard API group)..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete alertmanagerconfig -n "$NAMESPACE" --all --cascade=background || true
        else
            oc delete alertmanagerconfig -n "$NAMESPACE" --all --cascade=background 2>/dev/null || true
        fi
    fi
    
    # ============================================================================
    # STEP 8: Delete ScrapeConfig
    # ============================================================================
    # ScrapeConfig is used by MonitoringStack, delete after MonitoringStack
    log_info "Step 8: Deleting ScrapeConfig (federation)..."
    if oc get scrapeconfig platform-monitoring-federation -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting COO federation ScrapeConfig..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete scrapeconfig platform-monitoring-federation -n "$NAMESPACE" --cascade=background || true
        else
            oc delete scrapeconfig platform-monitoring-federation -n "$NAMESPACE" --cascade=background 2>/dev/null || true
        fi
    fi
    
    # ============================================================================
    # STEP 9: Delete ServiceMonitor, PrometheusRule, NetworkPolicy
    # ============================================================================
    # User-created resources used by MonitoringStack, delete after MonitoringStack
    log_info "Step 9: Deleting ServiceMonitor, PrometheusRule, and NetworkPolicy resources..."
    # Delete COO manifests using label selector (safer - only deletes COO resources)
    # Check if resources exist before attempting deletion
    local coo_resources=$(oc get servicemonitor,prometheusrule,networkpolicy -n "$NAMESPACE" -l monitoring-type=coo --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$coo_resources" =~ ^[0-9]+$ ]] && [[ "$coo_resources" -gt 0 ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete servicemonitor,prometheusrule,networkpolicy -n "$NAMESPACE" -l monitoring-type=coo || true
        else
            oc delete servicemonitor,prometheusrule,networkpolicy -n "$NAMESPACE" -l monitoring-type=coo &>/dev/null || true
        fi
    fi
    
    # Also delete by name as fallback (in case labels weren't applied)
    if oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete servicemonitor eip-monitor-coo -n "$NAMESPACE" || true
        else
            oc delete servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null || true
        fi
    fi
    
    if oc get prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" || true
        else
            oc delete prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null || true
        fi
    fi
    
    if oc get networkpolicy eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" || true
        else
            oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" &>/dev/null || true
        fi
    fi
    
    # ============================================================================
    # STEP 10: Delete federation resources
    # ============================================================================
    # Federation secrets and RBAC used by MonitoringStack
    log_info "Step 10: Deleting federation resources (secrets, RBAC)..."
    if oc get secret eip-monitoring-stack-prometheus-token -n "$NAMESPACE" &>/dev/null; then
        log_info "Deleting federation token secret..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete secret eip-monitoring-stack-prometheus-token -n "$NAMESPACE" || true
        else
            oc delete secret eip-monitoring-stack-prometheus-token -n "$NAMESPACE" 2>/dev/null || true
        fi
    fi
    
    if oc get clusterrolebinding eip-monitoring-stack-prometheus-federation &>/dev/null; then
        log_info "Deleting federation RBAC ClusterRoleBinding..."
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete clusterrolebinding eip-monitoring-stack-prometheus-federation || true
        else
            oc delete clusterrolebinding eip-monitoring-stack-prometheus-federation &>/dev/null || true
        fi
    fi
    
    # Remove individual NetworkPolicies (if they exist)
    log_info "Removing individual NetworkPolicies..."
    oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" 2>/dev/null || true
    oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
    
    # Delete combined NetworkPolicy only if no monitoring resources remain
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        # Check if any monitoring resources still exist
        local has_monitoring_resources=false
        if oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
           oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
           oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
            has_monitoring_resources=true
        fi
        
        if [[ "$has_monitoring_resources" == "false" ]]; then
            log_info "Deleting combined NetworkPolicy (no monitoring resources remaining)..."
            if [[ "$VERBOSE" == "true" ]]; then
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" || true
            else
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null || true
            fi
        else
            log_info "Keeping combined NetworkPolicy (monitoring resources still exist)..."
        fi
    fi
    
    # ============================================================================
    # STEP 11: Delete COO operator subscription
    # ============================================================================
    # This deletes CSV and operator, which manages all above resources
    # Must be deleted AFTER all resources are deleted
    log_info "Step 11: Deleting COO operator subscription..."
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete subscription cluster-observability-operator -n openshift-operators || log_warn "Failed to delete COO operator subscription"
        else
            oc delete subscription cluster-observability-operator -n openshift-operators &>/dev/null || log_warn "Failed to delete COO operator subscription"
        fi
        
        # Wait a bit for operator to clean up CSVs automatically
        log_info "Waiting for operator to clean up CSVs (if supported)..."
        sleep 10
    fi
    
    # ============================================================================
    # STEP 12: Delete orphaned CSVs
    # ============================================================================
    # Orphaned CSVs can block new installations, delete after subscription
    log_info "Step 12: Checking for orphaned COO CSVs..."
    local csv_list=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("cluster-observability")) | "\(.metadata.name)|\(if .metadata.ownerReferences then (.metadata.ownerReferences[0].kind // "none") else "none" end)"' 2>/dev/null || echo "")
    
    if [[ -n "$csv_list" ]]; then
        echo "$csv_list" | while IFS='|' read -r csv_name csv_owner; do
            if [[ "$csv_owner" == "none" ]] || [[ -z "$csv_owner" ]]; then
                log_warn "Found orphaned CSV: $csv_name (not owned by subscription)"
                log_info "Deleting orphaned CSV: $csv_name..."
                
                # Remove finalizers using common function (CSVs can get stuck with finalizers)
                remove_finalizers "csv" "openshift-operators" "$csv_name" || log_warn "Failed to remove finalizers from CSV: $csv_name"
                sleep 2
                
                # Delete the CSV
                if [[ "$VERBOSE" == "true" ]]; then
                    oc delete csv "$csv_name" -n openshift-operators || log_warn "Failed to delete CSV: $csv_name"
                else
                    oc delete csv "$csv_name" -n openshift-operators &>/dev/null || log_warn "Failed to delete CSV: $csv_name"
                fi
            fi
        done
    fi
    
    # Also check for any CSVs that might be stuck (have deletionTimestamp but not deleted)
    local stuck_csvs=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("cluster-observability")) | select(.metadata.deletionTimestamp != null) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$stuck_csvs" ]]; then
        log_warn "Found CSVs stuck in deletion:"
        echo "$stuck_csvs" | while read -r csv_name; do
            log_info "  - $csv_name"
            # Remove finalizers to allow deletion using common function
            remove_finalizers "csv" "openshift-operators" "$csv_name" || true
        done
    fi
    
    # ============================================================================
    # STEP 13: Delete CRDs (optional)
    # ============================================================================
    # CRDs must be deleted AFTER all resources using them are deleted
    # Wait a bit for operator to clean up CRDs automatically
    log_info "Step 13: Waiting for operator to clean up CRDs (if supported)..."
    sleep 5
    
    # Optionally delete COO CRDs if they still exist (requires cluster-admin)
    # Note: CRDs are typically cleaned up by the operator, but may remain if operator cleanup fails
    if [[ "${DELETE_CRDS:-false}" == "true" ]]; then
        log_info "Deleting COO CRDs (requires cluster-admin permissions)..."
        local coo_crds=(
            "monitoringstacks.monitoring.rhobs"
            "thanosqueriers.monitoring.rhobs"
            "alertmanagerconfigs.monitoring.rhobs"
            "scrapeconfigs.monitoring.rhobs"
            "alertmanagers.monitoring.rhobs"
            "podmonitors.monitoring.rhobs"
            "probes.monitoring.rhobs"
            "prometheusagents.monitoring.rhobs"
            "prometheuses.monitoring.rhobs"
            "prometheusrules.monitoring.rhobs"
            "servicemonitors.monitoring.rhobs"
            "thanosrulers.monitoring.rhobs"
        )
        
        for crd in "${coo_crds[@]}"; do
            if oc get crd "$crd" &>/dev/null; then
                log_info "Deleting CRD: $crd..."
                if [[ "$VERBOSE" == "true" ]]; then
                    oc delete crd "$crd" || log_warn "Failed to delete CRD: $crd (may require cluster-admin or CRD may be in use)"
                else
                    oc delete crd "$crd" &>/dev/null || log_warn "Failed to delete CRD: $crd (may require cluster-admin or CRD may be in use)"
                fi
            fi
        done
    else
        log_info "COO CRDs will not be deleted (operator should clean them up automatically)"
        log_info "To force CRD deletion, use: $0 --remove-monitoring coo --delete-crds"
        log_info "Note: CRD deletion requires cluster-admin permissions"
    fi
    
    log_success "COO monitoring infrastructure removed"
}

# Remove UWM monitoring
# UWM Dependency Tree (deletion order):
# 1. ServiceMonitor, PrometheusRule (used by UWM Prometheus, delete before Prometheus is removed)
# 2. NetworkPolicy (user-created, used by ServiceMonitor)
# 3. user-workload-monitoring-config (configures UWM Prometheus, delete before disabling UWM)
# 4. Disable UWM in cluster-monitoring-config (disables UWM operator, must be LAST)
remove_uwm_monitoring() {
    log_info "Removing UWM monitoring infrastructure..."
    log_info "Following UWM dependency tree for proper deletion order..."
    
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
    
    # ============================================================================
    # STEP 1: Delete ServiceMonitor and PrometheusRule
    # ============================================================================
    # These are used by UWM Prometheus, must be deleted before Prometheus is removed
    log_info "Step 1: Deleting ServiceMonitor and PrometheusRule resources..."
    # Delete UWM manifests using label selector (safer - only deletes UWM resources)
    # Check if resources exist before attempting deletion
    local uwm_resources=$(oc get servicemonitor,prometheusrule -n "$NAMESPACE" -l monitoring-type=uwm --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "$uwm_resources" =~ ^[0-9]+$ ]] && [[ "$uwm_resources" -gt 0 ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete servicemonitor,prometheusrule -n "$NAMESPACE" -l monitoring-type=uwm || true
        else
            oc delete servicemonitor,prometheusrule -n "$NAMESPACE" -l monitoring-type=uwm &>/dev/null || true
        fi
    fi
    
    # Also delete by name as fallback (in case labels weren't applied)
    if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete servicemonitor eip-monitor-uwm -n "$NAMESPACE" || true
        else
            oc delete servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null || true
        fi
    fi
    
    if oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null; then
        if [[ "$VERBOSE" == "true" ]]; then
            oc delete prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" || true
        else
            oc delete prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null || true
        fi
    fi
    
    # ============================================================================
    # STEP 2: Delete NetworkPolicy
    # ============================================================================
    # User-created NetworkPolicy, used by ServiceMonitor
    log_info "Step 2: Deleting NetworkPolicy resources..."
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete networkpolicy -n "$NAMESPACE" -l monitoring-type=uwm || true
        oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
    else
        oc delete networkpolicy -n "$NAMESPACE" -l monitoring-type=uwm &>/dev/null || true
        oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
    fi
    
    # ============================================================================
    # STEP 3: Delete user-workload-monitoring-config
    # ============================================================================
    # This configures UWM Prometheus, must be deleted before disabling UWM
    log_info "Step 3: Deleting user-workload-monitoring-config..."
    if [[ "$VERBOSE" == "true" ]]; then
        oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring || true
    else
        oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring &>/dev/null || true
    fi
    
    # ============================================================================
    # STEP 4: Disable UWM in cluster-monitoring-config
    # ============================================================================
    # This disables the UWM operator, must be LAST
    log_info "Step 4: Disabling User Workload Monitoring in cluster-monitoring-config..."
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
    
    # Remove individual NetworkPolicies (if they exist)
    log_info "Removing individual NetworkPolicies..."
    oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" 2>/dev/null || true
    oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" 2>/dev/null || true
    
    # Delete combined NetworkPolicy only if no monitoring resources remain
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        # Check if any monitoring resources still exist
        local has_monitoring_resources=false
        if oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
           oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
           oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
            has_monitoring_resources=true
        fi
        
        if [[ "$has_monitoring_resources" == "false" ]]; then
            log_info "Deleting combined NetworkPolicy (no monitoring resources remaining)..."
            if [[ "$VERBOSE" == "true" ]]; then
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" || true
            else
                oc delete networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null || true
            fi
        else
            log_info "Keeping combined NetworkPolicy (monitoring resources still exist)..."
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
    
    # If removing monitoring
    if [[ "$REMOVE_MONITORING" == "true" ]]; then
        # Require explicit monitoring type specification - no defaults or auto-detection
        if [[ -z "$MONITORING_TYPE" ]]; then
            log_error "Monitoring type must be explicitly specified when removing"
            log_error "Use: --remove-monitoring --monitoring-type <coo|uwm|all>"
            log_error "Or:  --remove-monitoring <coo|uwm|all>"
            exit 1
        fi
        
        # Validate monitoring type
        if [[ "$MONITORING_TYPE" != "coo" ]] && [[ "$MONITORING_TYPE" != "uwm" ]] && [[ "$MONITORING_TYPE" != "all" ]]; then
            log_error "Invalid monitoring type: $MONITORING_TYPE"
            log_error "Must be 'coo', 'uwm', or 'all'"
            exit 1
        fi
        
        # Remove the specified type(s)
        if [[ "$MONITORING_TYPE" == "coo" ]]; then
            log_info "Removing COO monitoring..."
            remove_coo_monitoring
        elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
            log_info "Removing UWM monitoring..."
            remove_uwm_monitoring
        elif [[ "$MONITORING_TYPE" == "all" ]]; then
            log_info "Removing all monitoring (COO and UWM)..."
            remove_coo_monitoring
            remove_uwm_monitoring
        fi
        return 0
    fi
    
    # Validate monitoring type for deployment
    if [[ -z "$MONITORING_TYPE" ]]; then
        log_error "Monitoring type must be specified"
        log_error "Use: --monitoring-type <coo|uwm|all> or --all"
        exit 1
    fi
    
    if [[ "$MONITORING_TYPE" != "coo" ]] && [[ "$MONITORING_TYPE" != "uwm" ]] && [[ "$MONITORING_TYPE" != "all" ]]; then
        log_error "Invalid monitoring type: $MONITORING_TYPE. Must be 'coo', 'uwm', or 'all'"
        exit 1
    fi
    
    # Handle "all" - deploy both COO and UWM
    if [[ "$MONITORING_TYPE" == "all" ]]; then
        log_info "Deploying both COO and UWM monitoring..."
        echo ""
        
        # Deploy COO first
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "Deploying COO monitoring..."
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local original_monitoring_type="$MONITORING_TYPE"
        MONITORING_TYPE="coo"
        deploy_monitoring
        
        # Deploy UWM second
        log_info ""
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "Deploying UWM monitoring..."
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        MONITORING_TYPE="uwm"
        deploy_monitoring
        
        # Restore original type for final summary
        MONITORING_TYPE="$original_monitoring_type"
        
        log_success "Both COO and UWM monitoring are now installed!"
        return 0
    fi
    
    # Detect current monitoring type for deployment logic
    local current_type=$(detect_current_monitoring_type)
    
    # If switching types, remove current first (but allow coexistence)
    if [[ "$current_type" != "none" ]] && [[ "$current_type" != "$MONITORING_TYPE" ]] && [[ "$current_type" != "both" ]]; then
        log_warn "Detected $current_type monitoring, but requested $MONITORING_TYPE"
        log_info "Installing $MONITORING_TYPE alongside $current_type (both will coexist)..."
    fi
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        log_info "Deploying COO monitoring infrastructure..."
        
        # Install COO operator
        install_coo_operator
        
        # Configure monitoring stack
        configure_coo_monitoring_stack
        
        # Apply COO manifests (optimized: batch apply for better performance)
        log_info "Applying COO monitoring resources..."
        local coo_manifests=(
            "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml"
            "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml"
            "${project_root}/k8s/monitoring/coo/monitoring/thanosquerier-coo.yaml"
            "${project_root}/k8s/monitoring/coo/monitoring/alertmanagerconfig-coo.yaml"
            "${project_root}/k8s/monitoring/networkpolicy-combined.yaml"
        )
        if oc apply -n "$NAMESPACE" -f "${coo_manifests[@]}" &>/dev/null; then
            log_success "COO monitoring resources deployed"
        else
            # Fallback to individual applies for better error reporting
            log_warn "Batch apply failed, applying individually..."
            oc_cmd_silent apply -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml"
            oc_cmd_silent apply -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml"
            if [[ "${VERBOSE:-false}" == "true" ]]; then
                log_info "Deploying ThanosQuerier..."
            fi
            oc_cmd_silent apply -f "${project_root}/k8s/monitoring/coo/monitoring/thanosquerier-coo.yaml"
            oc_cmd_silent apply -f "${project_root}/k8s/monitoring/coo/monitoring/alertmanagerconfig-coo.yaml"
            oc_cmd_silent apply -f "${project_root}/k8s/monitoring/networkpolicy-combined.yaml"
        fi
        
        # Remove individual NetworkPolicies if they exist (to avoid conflicts)
        oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" &>/dev/null || true
        oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" &>/dev/null || true
        
        # Deploy Route for ThanosQuerier (for Inspect links in Perses dashboards)
        oc_cmd_silent apply -f "${project_root}/k8s/monitoring/coo/monitoring/route-thanos-querier-coo.yaml" || {
            log_warn "Failed to deploy ThanosQuerier route (non-critical, inspect links may not work)"
        }
        
        # Apply federation ScrapeConfig if it exists
        local scrapeconfig_file="${project_root}/k8s/monitoring/coo/monitoring/scrapeconfig-federation-coo.yaml"
        if [[ -f "$scrapeconfig_file" ]]; then
            # Apply federation RBAC first (required for authentication)
            local rbac_file="${project_root}/k8s/monitoring/coo/rbac/prometheus-federation-rbac.yaml"
            if [[ -f "$rbac_file" ]]; then
                oc_cmd_silent apply -f "$rbac_file" || log_warn "Failed to apply federation RBAC"
            else
                log_warn "Federation RBAC file not found: $rbac_file"
                log_warn "Federation may fail without proper RBAC permissions"
            fi
            
            oc_cmd_silent apply -f "$scrapeconfig_file"
            
            # Setup federation token secret
            setup_federation_token || {
                log_warn "Failed to setup federation token, but deployment continues"
                log_warn "Federation may not work until the token is created manually"
            }
            
            # Wait for Prometheus to pick up the new token
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
        
        # First, wait for ThanosQuerier CR to exist (operator needs to reconcile it)
        local max_wait_cr=30
        local waited_cr=0
        while [[ $waited_cr -lt $max_wait_cr ]]; do
            if oc get thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" &>/dev/null; then
                log_success "ThanosQuerier CR exists"
                break
            fi
            sleep 2
            waited_cr=$((waited_cr + 2))
        done
        
        if [[ $waited_cr -ge $max_wait_cr ]]; then
            log_warn "ThanosQuerier CR not found after ${max_wait_cr}s (may still be creating)"
        fi
        
        # Now wait for the pod to be created and running
        local max_wait=120
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            # Use common function to find ThanosQuerier pod
            local thanos_pod=$(find_thanosquerier_pod "$NAMESPACE")
            
            if [[ -n "$thanos_pod" ]]; then
                local pod_phase=$(oc get pod "$thanos_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [[ "$pod_phase" == "Running" ]]; then
                    log_success "ThanosQuerier pod is running: $thanos_pod"
                    break
                elif [[ -n "$pod_phase" ]]; then
                    # Pod exists but not running yet
                    if [[ $((waited % 30)) -eq 0 ]] && [[ $waited -lt $max_wait ]]; then
                        log_info "ThanosQuerier pod exists but not running yet (phase: $pod_phase, waited ${waited}s)..."
                    fi
                fi
            else
                # No pod found yet - log progress
                if [[ $((waited % 30)) -eq 0 ]] && [[ $waited -lt $max_wait ]]; then
                    log_info "Still waiting for ThanosQuerier pod... (${waited}s)"
                    # Debug: show what pods exist
                    if [[ "$VERBOSE" == "true" ]]; then
                        log_info "Available pods in namespace:"
                        oc get pods -n "$NAMESPACE" --no-headers 2>/dev/null | head -5 | sed 's/^/  /' || true
                    fi
                fi
            fi
            sleep 5
            waited=$((waited + 5))
        done
        
        if [[ $waited -ge $max_wait ]]; then
            log_warn "ThanosQuerier pod may not be ready yet (waited ${max_wait}s)"
            log_info "This is non-blocking - ThanosQuerier will continue initializing"
            log_info "Check ThanosQuerier status: oc get thanosquerier eip-monitoring-stack-querier-coo -n $NAMESPACE"
        fi
        
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
            # Install datasources (optimized: batch apply)
            if [[ -d "${project_root}/k8s/monitoring/coo/perses/datasources" ]]; then
                local datasource_files=("${project_root}"/k8s/monitoring/coo/perses/datasources/*.yaml)
                if [[ -f "${datasource_files[0]}" ]]; then
                    if oc apply -f "${datasource_files[@]}" &>/dev/null; then
                        log_success "Installed ${#datasource_files[@]} Perses datasource(s)"
                    else
                        # Fallback to individual applies
                        for datasource in "${datasource_files[@]}"; do
                            if [[ -f "$datasource" ]]; then
                                local ds_name=$(basename "$datasource" .yaml)
                                if oc apply -f "$datasource" &>/dev/null; then
                                    log_success "  ✓ Installed Perses datasource: $ds_name"
                                else
                                    log_warn "  ✗ Failed to install Perses datasource: $ds_name"
                                fi
                            fi
                        done
                    fi
                fi
            fi
            # Install dashboards (optimized: batch apply)
            if [[ -d "${project_root}/k8s/monitoring/coo/perses/dashboards" ]]; then
                local dashboard_files=("${project_root}"/k8s/monitoring/coo/perses/dashboards/*.yaml)
                if [[ -f "${dashboard_files[0]}" ]]; then
                    if oc apply -f "${dashboard_files[@]}" &>/dev/null; then
                        log_success "Installed ${#dashboard_files[@]} Perses dashboard(s)"
                    else
                        # Fallback to individual applies
                        for dashboard in "${dashboard_files[@]}"; do
                            if [[ -f "$dashboard" ]]; then
                                local db_name=$(basename "$dashboard" .yaml)
                                if oc apply -f "$dashboard" &>/dev/null; then
                                    log_success "  ✓ Installed Perses dashboard: $db_name"
                                else
                                    log_warn "  ✗ Failed to install Perses dashboard: $db_name"
                                fi
                            fi
                        done
                    fi
                fi
            fi
        else
            log_warn "Perses directory not found: ${project_root}/k8s/monitoring/coo/perses"
        fi
        
        # Install COO UI plugins (for OpenShift console integration)
        log_info "Installing COO UI plugins..."
        if [[ -d "${project_root}/k8s/monitoring/coo/ui-plugins" ]]; then
            # Get OpenShift version for troubleshooting plugin check
            local ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "")
            local ocp_major_minor=""
            if [[ -n "$ocp_version" ]]; then
                # Extract major.minor version (e.g., "4.19" from "4.19.0")
                ocp_major_minor=$(echo "$ocp_version" | cut -d. -f1,2)
            fi
            
            for ui_plugin in "${project_root}"/k8s/monitoring/coo/ui-plugins/*.yaml; do
                if [[ -f "$ui_plugin" ]]; then
                    local plugin_name=$(basename "$ui_plugin" .yaml)
                    local is_troubleshooting=false
                    if [[ "$plugin_name" == "troubleshooting-ui-plugin" ]] || [[ "$plugin_name" == "troubleshooting" ]]; then
                        is_troubleshooting=true
                    fi
                    
                    # Check if troubleshooting plugin requires OCP 4.19+
                    if [[ "$is_troubleshooting" == "true" ]]; then
                        if [[ -z "$ocp_major_minor" ]]; then
                            log_warn "  ⚠ Cannot determine OpenShift version, attempting to install troubleshooting plugin anyway"
                            log_info "    Troubleshooting UI Plugin requires OpenShift 4.19 or newer"
                        else
                            # Compare versions: 4.19+ required
                            # Extract major and minor for comparison
                            local ocp_major=$(echo "$ocp_major_minor" | cut -d. -f1)
                            local ocp_minor=$(echo "$ocp_major_minor" | cut -d. -f2)
                            local min_major=4
                            local min_minor=19
                            
                            # Check if version is >= 4.19
                            local version_ok=false
                            if [[ $ocp_major -gt $min_major ]]; then
                                version_ok=true
                            elif [[ $ocp_major -eq $min_major ]] && [[ $ocp_minor -ge $min_minor ]]; then
                                version_ok=true
                            fi
                            
                            if [[ "$version_ok" == "false" ]]; then
                                log_warn "  ⚠ Skipping troubleshooting plugin (requires OCP 4.19+, cluster is $ocp_version)"
                                continue
                            fi
                            log_info "  Installing troubleshooting UI plugin (OCP $ocp_version detected, 4.19+ required)"
                        fi
                    fi
                    
                    # Try to install the plugin
                    local apply_output
                    local apply_exit
                    apply_output=$(oc apply -f "$ui_plugin" 2>&1)
                    apply_exit=$?
                    
                    if [[ $apply_exit -eq 0 ]]; then
                        # Verify the resource actually exists (oc apply can succeed but resource might not be created)
                        # Extract the resource name from the YAML file
                        local resource_name=$(grep -E "^  name:" "$ui_plugin" | head -1 | awk '{print $2}' | tr -d '"' || echo "")
                        if [[ -z "$resource_name" ]]; then
                            # Fallback: use plugin_name without -ui-plugin suffix
                            resource_name="$plugin_name"
                            if [[ "$resource_name" == "troubleshooting-ui-plugin" ]]; then
                                resource_name="troubleshooting-panel"
                            elif [[ "$resource_name" == "monitoring-ui-plugin" ]]; then
                                resource_name="monitoring"
                            fi
                        fi
                        
                        # Wait a moment for the resource to be created, then verify it exists
                        sleep 2
                        if oc get uiplugin "$resource_name" &>/dev/null; then
                            log_success "  ✓ Installed UI plugin: $plugin_name (verified)"
                            
                            # Enable troubleshooting-panel in Console operator immediately after successful installation
                            # Note: UIPlugin creates a ConsolePlugin resource named "troubleshooting-panel-console-plugin"
                            if [[ "$is_troubleshooting" == "true" ]]; then
                                local console_plugins=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
                                # The ConsolePlugin resource created by UIPlugin is named "troubleshooting-panel-console-plugin"
                                local console_plugin_name="troubleshooting-panel-console-plugin"
                                
                                # Check if plugin is already in the list
                                if echo "$console_plugins" | grep -qE "\b${console_plugin_name}\b"; then
                                    log_info "  ✓ Troubleshooting plugin already enabled in Console operator"
                                else
                                    log_info "  Enabling troubleshooting-panel-console-plugin in Console operator..."
                                    # Get current plugins and add troubleshooting-panel-console-plugin if not present
                                    local current_plugins_json=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
                                    # Add troubleshooting-panel-console-plugin to the plugins list using jq if available, otherwise use patch
                                    if command -v jq &>/dev/null; then
                                        local updated_plugins=$(echo "$current_plugins_json" | jq '. + ["troubleshooting-panel-console-plugin"] | unique' 2>/dev/null || echo "")
                                        if [[ -n "$updated_plugins" ]]; then
                                            if oc patch console.operator.openshift.io cluster --type=json \
                                                -p "[{\"op\": \"replace\", \"path\": \"/spec/plugins\", \"value\": $updated_plugins}]" &>/dev/null; then
                                                log_success "  ✓ Enabled troubleshooting-panel-console-plugin in Console operator"
                                                log_info "  Note: Troubleshooting panel appears when viewing alerts (Observe > Alerting > select alert)"
                                                log_info "  Console pods will restart automatically to load the plugin"
                                                log_info "  If troubleshooting panel shows 'Request Failed', check:"
                                                log_info "    - Browser console for detailed error messages"
                                                log_info "    - Korrel8r pod logs: oc logs -n openshift-operators -l app.kubernetes.io/instance=korrel8r"
                                                log_info "    - Console pod logs: oc logs -n openshift-console -l app=console | grep -i korrel"
                                            else
                                                log_warn "  ⚠ Failed to enable troubleshooting-panel-console-plugin in Console operator (may require cluster-admin)"
                                            fi
                                        fi
                                    else
                                        # Fallback: use simple patch to add the plugin
                                        if oc patch console.operator.openshift.io cluster --type=json \
                                            -p '[{"op": "add", "path": "/spec/plugins/-", "value": "troubleshooting-panel-console-plugin"}]' &>/dev/null; then
                                            log_success "  ✓ Enabled troubleshooting-panel-console-plugin in Console operator"
                                            log_info "  Note: Troubleshooting panel appears when viewing alerts (Observe > Alerting > select alert)"
                                            log_info "  Console pods will restart automatically to load the plugin"
                                        else
                                            log_warn "  ⚠ Failed to enable troubleshooting-panel-console-plugin in Console operator (may require cluster-admin)"
                                        fi
                                    fi
                                fi
                            fi
                        else
                            log_warn "  ⚠ Applied UI plugin: $plugin_name but resource not found (may still be creating)"
                            if [[ "$VERBOSE" == "true" ]]; then
                                log_info "    Apply output: $apply_output"
                            fi
                            if [[ "$is_troubleshooting" == "true" ]]; then
                                log_info "    Troubleshooting plugin may require:"
                                log_info "    - OpenShift 4.19 or newer (detected: ${ocp_version:-unknown})"
                                log_info "    - Cluster Observability Operator installed"
                                log_info "    - Cluster-admin permissions"
                                log_info "    Check status: oc get uiplugin $resource_name"
                            fi
                        fi
                    else
                        log_error "  ✗ Failed to install UI plugin: $plugin_name"
                        if [[ "$VERBOSE" == "true" ]]; then
                            log_info "    Error output: $apply_output"
                        else
                            # Show first line of error even in non-verbose mode
                            log_info "    Error: $(echo "$apply_output" | head -1)"
                        fi
                        if [[ "$is_troubleshooting" == "true" ]]; then
                            log_info "    Troubleshooting plugin requires:"
                            log_info "    - OpenShift 4.19 or newer (detected: ${ocp_version:-unknown})"
                            log_info "    - Cluster Observability Operator installed"
                            log_info "    - Cluster-admin permissions"
                        fi
                    fi
                fi
            done
        else
            log_warn "UI plugins directory not found: ${project_root}/k8s/monitoring/coo/ui-plugins"
        fi
        
        # Add COO monitoring labels to deployment and service for service discovery
        if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
            # Add labels to deployment metadata and pod template
            # Ensure pods have: app=eip-monitor, service=eip-monitor (required by ServiceMonitor)
            oc_cmd_silent patch deployment eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/monitoring-coo", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/monitoring-coo", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/service", "value": "eip-monitor"}
            ]' || {
                # Fallback: use oc label
                oc_cmd_silent label deployment eip-monitor -n "$NAMESPACE" monitoring-coo="true" --overwrite || true
            }
        fi
        
        # Ensure service has correct labels for ServiceMonitor discovery
        if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
            oc_cmd_silent patch service eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/app", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/service", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/monitoring-coo", "value": "true"},
                {"op": "replace", "path": "/spec/selector/app", "value": "eip-monitor"}
            ]' || {
                # Fallback: use oc label and patch
                oc_cmd_silent label service eip-monitor -n "$NAMESPACE" app=eip-monitor service=eip-monitor monitoring-coo="true" --overwrite || true
                oc_cmd_silent patch service eip-monitor -n "$NAMESPACE" --type merge -p '{"spec":{"selector":{"app":"eip-monitor"}}}' || true
            }
        fi
        
        log_success "COO monitoring infrastructure deployed!"
        
    elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
        log_info "Deploying UWM monitoring infrastructure..."
        
        # Ensure namespace is labeled for UWM monitoring
        log_info "Ensuring namespace is labeled for UWM monitoring..."
        local namespace_label=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.openshift\.io/user-monitoring}' 2>/dev/null || echo "")
        local cluster_monitoring_label=$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.openshift\.io/cluster-monitoring}' 2>/dev/null || echo "")
        
        if [[ "$cluster_monitoring_label" == "true" ]]; then
            log_warn "Namespace has openshift.io/cluster-monitoring=true label - removing it"
            log_warn "This label excludes namespaces from UWM Prometheus discovery"
            oc label namespace "$NAMESPACE" openshift.io/cluster-monitoring- 2>/dev/null || true
        fi
        
        if [[ "$namespace_label" == "false" ]]; then
            log_warn "Namespace has openshift.io/user-monitoring=false label - removing it"
            oc label namespace "$NAMESPACE" openshift.io/user-monitoring- 2>/dev/null || true
            oc label namespace "$NAMESPACE" openshift.io/user-monitoring=true --overwrite 2>/dev/null || true
        elif [[ "$namespace_label" != "true" ]]; then
            # Label is missing or has unexpected value - set it to true
            oc label namespace "$NAMESPACE" openshift.io/user-monitoring=true --overwrite 2>/dev/null || true
        else
            log_info "Namespace already labeled for UWM monitoring"
        fi
        
        # Enable UWM
        enable_user_workload_monitoring
        enable_user_workload_alertmanager
        
        # Configure persistent storage for UWM if requested
        if [[ "${PERSISTENT_STORAGE:-false}" == "true" ]]; then
            configure_uwm_persistent_storage
        fi
        
        # Apply UWM manifests
        oc_cmd_silent apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml"
        oc_cmd_silent apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml"
        
        # Always apply combined NetworkPolicy (works for both COO and UWM)
        oc_cmd_silent apply -f "${project_root}/k8s/monitoring/networkpolicy-combined.yaml"
        
        # Remove individual NetworkPolicies if they exist (to avoid conflicts)
        oc delete networkpolicy eip-monitor-coo -n "$NAMESPACE" &>/dev/null || true
        oc delete networkpolicy eip-monitor-uwm -n "$NAMESPACE" &>/dev/null || true
        
        # Add UWM monitoring labels to deployment and service for service discovery
        if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
            # Add labels to deployment metadata and pod template
            # Ensure pods have: app=eip-monitor, service=eip-monitor (required by ServiceMonitor)
            oc_cmd_silent patch deployment eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "add", "path": "/spec/template/metadata/labels/service", "value": "eip-monitor"}
            ]' || {
                # Fallback: use oc label
                oc_cmd_silent label deployment eip-monitor -n "$NAMESPACE" monitoring-uwm="true" --overwrite || true
            }
        fi
        
        # Ensure service has correct labels for ServiceMonitor discovery
        if oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
            oc_cmd_silent patch service eip-monitor -n "$NAMESPACE" --type json -p '[
                {"op": "add", "path": "/metadata/labels/app", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/service", "value": "eip-monitor"},
                {"op": "add", "path": "/metadata/labels/monitoring-uwm", "value": "true"},
                {"op": "replace", "path": "/spec/selector/app", "value": "eip-monitor"}
            ]' || {
                # Fallback: use oc label and patch
                oc_cmd_silent label service eip-monitor -n "$NAMESPACE" app=eip-monitor service=eip-monitor monitoring-uwm="true" --overwrite || true
                oc_cmd_silent patch service eip-monitor -n "$NAMESPACE" --type merge -p '{"spec":{"selector":{"app":"eip-monitor"}}}' || true
            }
        fi
        
        log_success "UWM monitoring infrastructure deployed!"
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
                    log_error "Option $1 requires a value (coo, uwm, or all)"
                    show_usage
                    exit 1
                fi
                if [[ "$2" == "all" ]]; then
                    MONITORING_TYPE="all"
                else
                    MONITORING_TYPE="$2"
                fi
                shift 2
                ;;
            --all)
                MONITORING_TYPE="all"
                shift
                ;;
            --remove-monitoring)
                REMOVE_MONITORING="true"
                shift
                # Check if next argument is a monitoring type (coo, uwm, or all) - allow positional syntax
                if [[ $# -gt 0 ]] && [[ "$1" == "coo" || "$1" == "uwm" || "$1" == "all" ]]; then
                    MONITORING_TYPE="$1"
                    shift
                fi
                ;;
            --delete-crds)
                DELETE_CRDS="true"
                shift
                ;;
            --persistent)
                PERSISTENT_STORAGE="true"
                shift
                ;;
            --status)
                SHOW_STATUS="true"
                shift
                ;;
            --test)
                TEST_MONITORING="true"
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

# Show monitoring status
show_monitoring_status() {
    log_info "Checking monitoring infrastructure status..."
    echo ""
    
    # Check namespace
    if ! oc get namespace "$NAMESPACE" &>/dev/null; then
        log_warn "Namespace '$NAMESPACE' does not exist"
        return 1
    fi
    
    # Detect current monitoring type if not specified
    local status_type="${MONITORING_TYPE:-}"
    if [[ -z "$status_type" ]]; then
        status_type=$(detect_current_monitoring_type)
        if [[ "$status_type" == "none" ]]; then
            log_warn "No monitoring infrastructure detected in namespace '$NAMESPACE'"
            return 1
        fi
        log_info "Detected monitoring type: $status_type"
    fi
    
    # Show COO status if applicable
    if [[ "$status_type" == "coo" ]] || [[ "$status_type" == "all" ]]; then
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "COO Monitoring Status"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Check MonitoringStack
        if oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
            log_info "MonitoringStack:"
            oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o custom-columns="NAME:.metadata.name,NAMESPACE:.metadata.namespace,AGE:.metadata.creationTimestamp"
            
            # Check Prometheus pods
            log_info ""
            log_info "Prometheus Pods:"
            oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp" 2>/dev/null || log_info "  (No Prometheus pods found)"
            
            # Check ThanosQuerier
            if oc get thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" &>/dev/null; then
                log_info ""
                log_info "ThanosQuerier:"
                oc get thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" -o custom-columns="NAME:.metadata.name,NAMESPACE:.metadata.namespace,AGE:.metadata.creationTimestamp"
                
                local thanos_pod=$(find_thanosquerier_pod "$NAMESPACE")
                if [[ -n "$thanos_pod" ]]; then
                    log_info ""
                    log_info "ThanosQuerier Pod:"
                    oc get pod "$thanos_pod" -n "$NAMESPACE" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp"
                fi
            fi
        else
            log_warn "MonitoringStack not found"
        fi
        
        # Check ServiceMonitor (try both COO API group and standard API group)
        # Optimized: store result of first check to avoid duplicate calls
        local sm_output=""
        local sm_api_group=""
        if sm_output=$(oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" 2>/dev/null); then
            sm_api_group="COO API"
        elif sm_output=$(oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" 2>/dev/null); then
            sm_api_group="standard"
        fi
        
        if [[ -n "$sm_output" ]]; then
            log_info ""
            if [[ "$sm_api_group" == "COO API" ]]; then
                log_info "ServiceMonitor (COO API):"
            else
                log_info "ServiceMonitor:"
            fi
            echo "$sm_output"
        else
            log_warn "ServiceMonitor not found"
        fi
        
        # Check PrometheusRule (try both COO API group and standard API group)
        # Optimized: store result of first check to avoid duplicate calls
        local pr_output=""
        local pr_api_group=""
        if pr_output=$(oc get prometheusrule.monitoring.rhobs eip-monitor-alerts-coo -n "$NAMESPACE" 2>/dev/null); then
            pr_api_group="COO API"
        elif pr_output=$(oc get prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" 2>/dev/null); then
            pr_api_group="standard"
        fi
        
        if [[ -n "$pr_output" ]]; then
            log_info ""
            if [[ "$pr_api_group" == "COO API" ]]; then
                log_info "PrometheusRule (COO API):"
            else
                log_info "PrometheusRule:"
            fi
            echo "$pr_output"
        else
            log_warn "PrometheusRule not found"
        fi
        
        echo ""
    fi
    
    # Show UWM status if applicable
    if [[ "$status_type" == "uwm" ]] || [[ "$status_type" == "all" ]]; then
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "UWM Monitoring Status"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Check if UWM is enabled
        local uwm_enabled=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -oE "enableUserWorkload:\s*true" || echo "")
        if [[ -n "$uwm_enabled" ]]; then
            log_success "User Workload Monitoring is enabled"
        else
            log_warn "User Workload Monitoring may not be enabled"
        fi
        
        # Check Prometheus pods in openshift-user-workload-monitoring
        log_info ""
        log_info "UWM Prometheus Pods:"
        oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,AGE:.metadata.creationTimestamp" 2>/dev/null || log_info "  (No UWM Prometheus pods found)"
        
        # Check ServiceMonitor
        if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
            log_info ""
            log_info "ServiceMonitor:"
            oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE"
        fi
        
        # Check PrometheusRule
        if oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null; then
            log_info ""
            log_info "PrometheusRule:"
            oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE"
        fi
        
        echo ""
    fi
    
    # Show common resources
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Common Resources"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # NetworkPolicy
    if oc get networkpolicy eip-monitor-combined -n "$NAMESPACE" &>/dev/null; then
        log_info "NetworkPolicy:"
        oc get networkpolicy eip-monitor-combined -n "$NAMESPACE"
    fi
    
    log_success "Status check completed"
}

# Test monitoring infrastructure
test_monitoring() {
    # Save current error handling state and disable exit on error to ensure all tests run to completion
    local original_set_e
    if [[ $- == *e* ]]; then
        original_set_e=1
    else
        original_set_e=0
    fi
    set +e
    
    log_info "Testing monitoring infrastructure..."
    echo ""
    
    local tests_passed=0
    local tests_failed=0
    local total_tests=0
    
    # Test-specific logging function
    log_test() { echo -e "\n${BLUE}[TEST]${NC} $1"; }
    
    # Helper function to run a test
    run_test() {
        local test_name="$1"
        local test_command="$2"
        ((total_tests++))
        
        # Run test command, capturing exit code
        eval "$test_command" &>/dev/null
        local test_exit=$?
        
        if [[ $test_exit -eq 0 ]]; then
            log_success "$test_name"
            ((tests_passed++))
            return 0
        else
            log_error "$test_name"
            ((tests_failed++))
            return 1
        fi
    }
    
    # Detect monitoring type if not specified
    local test_type="${MONITORING_TYPE:-}"
    if [[ -z "$test_type" ]]; then
        test_type=$(detect_current_monitoring_type || echo "none")
        if [[ "$test_type" == "none" ]]; then
            log_error "No monitoring infrastructure detected"
            # Continue with tests anyway - they will fail but we'll get a complete picture
            log_warn "Continuing with tests to show what's missing..."
        else
            log_info "Testing detected monitoring type: $test_type"
        fi
    fi
    
    # Test COO if applicable
    if [[ "$test_type" == "coo" ]] || [[ "$test_type" == "all" ]]; then
        log_test "Step 1: COO Monitoring Tests"
        
        run_test "MonitoringStack exists" "oc get monitoringstack eip-monitoring-stack -n \"$NAMESPACE\" &>/dev/null"
        
        # Check ServiceMonitor (try both COO API group and standard API group)
        local sm_exists=false
        if oc get servicemonitor.monitoring.rhobs eip-monitor-coo -n "$NAMESPACE" &>/dev/null || \
           oc get servicemonitor eip-monitor-coo -n "$NAMESPACE" &>/dev/null; then
            sm_exists=true
        fi
        if [[ "$sm_exists" == "true" ]]; then
            log_success "ServiceMonitor exists"
            ((tests_passed++))
        else
            log_error "ServiceMonitor exists"
            # Show what ServiceMonitors actually exist for debugging
            local existing_sm=$(oc get servicemonitor.monitoring.rhobs -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
            if [[ -z "$existing_sm" ]]; then
                existing_sm=$(oc get servicemonitor -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
            fi
            if [[ -n "$existing_sm" ]]; then
                log_info "  Found ServiceMonitor(s): $existing_sm"
            else
                log_info "  No ServiceMonitors found in namespace $NAMESPACE"
            fi
            ((tests_failed++))
        fi
        ((total_tests++))
        
        # Check PrometheusRule (try both COO API group and standard API group)
        local pr_exists=false
        if oc get prometheusrule.monitoring.rhobs eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null || \
           oc get prometheusrule eip-monitor-alerts-coo -n "$NAMESPACE" &>/dev/null; then
            pr_exists=true
        fi
        if [[ "$pr_exists" == "true" ]]; then
            log_success "PrometheusRule exists"
            ((tests_passed++))
        else
            log_error "PrometheusRule exists"
            # Show what PrometheusRules actually exist for debugging
            local existing_pr=$(oc get prometheusrule.monitoring.rhobs -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
            if [[ -z "$existing_pr" ]]; then
                existing_pr=$(oc get prometheusrule -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' || echo "")
            fi
            if [[ -n "$existing_pr" ]]; then
                log_info "  Found PrometheusRule(s): $existing_pr"
            else
                log_info "  No PrometheusRules found in namespace $NAMESPACE"
            fi
            ((tests_failed++))
        fi
        ((total_tests++))
        
        # Check Prometheus pods
        local prom_pods=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
        if [[ "$prom_pods" -gt 0 ]]; then
            run_test "Prometheus pods running" "oc get pods -n \"$NAMESPACE\" -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q ."
        else
            log_error "Prometheus pods not found"
            ((tests_failed++))
            ((total_tests++))
        fi
        
        # Check ThanosQuerier
        if oc get thanosquerier eip-monitoring-stack-querier-coo -n "$NAMESPACE" &>/dev/null; then
            run_test "ThanosQuerier exists" "oc get thanosquerier eip-monitoring-stack-querier-coo -n \"$NAMESPACE\" &>/dev/null"
            
            local thanos_pod=$(find_thanosquerier_pod "$NAMESPACE")
            if [[ -n "$thanos_pod" ]]; then
                local thanos_phase=$(oc get pod "$thanos_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                run_test "ThanosQuerier pod running" "[[ \"$thanos_phase\" == \"Running\" ]]"
                
                # Test ThanosQuerier query endpoint
                if [[ "$thanos_phase" == "Running" ]]; then
                    local query_result=$(oc exec "$thanos_pod" -n "$NAMESPACE" -- curl -sf http://localhost:10902/api/v1/query?query=up 2>/dev/null || echo "")
                    run_test "ThanosQuerier query endpoint accessible" "[[ -n \"$query_result\" ]]"
                fi
            fi
        fi
        
        # Test UI Plugins (cluster-scoped resources)
        log_test "Step 1b: COO UI Plugins Tests"
        run_test "Monitoring UI Plugin exists" "oc get uiplugin monitoring &>/dev/null"
        
        # Troubleshooting UI Plugin is Technology Preview and may not be available
        # Check for both possible names: troubleshooting and troubleshooting-panel
        local troubleshooting_found=false
        local troubleshooting_resource_name=""
        if oc get uiplugin troubleshooting-panel &>/dev/null; then
            troubleshooting_found=true
            troubleshooting_resource_name="troubleshooting-panel"
        elif oc get uiplugin troubleshooting &>/dev/null; then
            troubleshooting_found=true
            troubleshooting_resource_name="troubleshooting"
        fi
        
        if [[ "$troubleshooting_found" == "true" ]]; then
            log_success "Troubleshooting UI Plugin exists"
            ((tests_passed++))
            
            # Verify it's enabled in Console operator
            # Note: UIPlugin creates a ConsolePlugin resource named "troubleshooting-panel-console-plugin"
            local console_plugins=$(oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
            local console_plugin_name="troubleshooting-panel-console-plugin"
            
            if echo "$console_plugins" | grep -qE "\b${console_plugin_name}\b"; then
                log_success "Troubleshooting UI Plugin enabled in Console operator"
                ((tests_passed++))
            else
                log_error "Troubleshooting UI Plugin installed but not enabled in Console operator"
                log_info "  Plugin should be in Console operator spec.plugins list"
                log_info "  Current plugins: $console_plugins"
                log_info "  Expected: troubleshooting-panel-console-plugin (ConsolePlugin resource name)"
                ((tests_failed++))
            fi
            ((total_tests++))
        else
            log_warn "Troubleshooting UI Plugin not found (Technology Preview - may not be available)"
            # Don't count as failure since it's optional/Technology Preview
            ((tests_passed++))
        fi
        ((total_tests++))
        
        # Test Perses configuration (deployed in openshift-operators namespace)
        log_test "Step 1c: COO Perses Configuration Tests"
        local perses_namespace="openshift-operators"
        
        # Check PersesDatasource
        run_test "PersesDatasource prometheus-coo exists" "oc get persesdatasource prometheus-coo -n \"$perses_namespace\" &>/dev/null"
        
        # Check PersesDashboards - verify they are loaded and have no errors
        local actual_dashboards=$(oc get persesdashboard -n "$perses_namespace" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
        if [[ "$actual_dashboards" -gt 0 ]]; then
            log_success "PersesDashboards loaded ($actual_dashboards found)"
            ((tests_passed++))
            
            # Check for errors in dashboard status/conditions
            local dashboards_with_errors=0
            local dashboard_list=$(oc get persesdashboard -n "$perses_namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
            if [[ -n "$dashboard_list" ]]; then
                for db_name in $dashboard_list; do
                    # Try to get the full dashboard resource - if this fails, there's an error
                    local dashboard_json=$(oc get persesdashboard "$db_name" -n "$perses_namespace" -o json 2>/dev/null || echo "")
                    if [[ -z "$dashboard_json" ]]; then
                        ((dashboards_with_errors++))
                        if [[ "$dashboards_with_errors" -eq 1 ]]; then
                            log_info "  Dashboard with error: $db_name (cannot retrieve resource)"
                        fi
                        continue
                    fi
                    
                    # Check status.conditions for any error conditions
                    local error_condition=$(echo "$dashboard_json" | jq -r '.status.conditions[]? | select(.type=="Error" or .type=="Failed") | .status' 2>/dev/null | head -1 || echo "")
                    local error_message=$(echo "$dashboard_json" | jq -r '.status.conditions[]? | select(.type=="Error" or .type=="Failed") | .message' 2>/dev/null | head -1 || echo "")
                    local error_reason=$(echo "$dashboard_json" | jq -r '.status.conditions[]? | select(.type=="Error" or .type=="Failed") | .reason' 2>/dev/null | head -1 || echo "")
                    
                    # Check if there are any error conditions
                    if [[ "$error_condition" == "True" ]] || [[ -n "$error_message" ]] || [[ -n "$error_reason" ]]; then
                        ((dashboards_with_errors++))
                        if [[ "$dashboards_with_errors" -eq 1 ]]; then
                            log_info "  Dashboard with error: $db_name"
                            if [[ -n "$error_message" ]]; then
                                log_info "    Error: $error_message"
                            fi
                            if [[ -n "$error_reason" ]]; then
                                log_info "    Reason: $error_reason"
                            fi
                        fi
                    fi
                done
            fi
            
            if [[ "$dashboards_with_errors" -eq 0 ]]; then
                log_success "PersesDashboards have no errors"
                ((tests_passed++))
            else
                log_error "PersesDashboards have errors ($dashboards_with_errors dashboard(s) with errors)"
                ((tests_failed++))
            fi
            ((total_tests++))
        else
            log_error "No PersesDashboards found"
            ((tests_failed++))
        fi
        ((total_tests++))
        
        # Check if Perses instance exists (may be auto-created by UIPlugin)
        # Note: Perses instance might be in openshift-operators or the monitoring namespace
        local perses_instance_found=false
        if oc get perses -n "$perses_namespace" --no-headers 2>/dev/null | grep -q .; then
            perses_instance_found=true
        elif oc get perses -n "$NAMESPACE" --no-headers 2>/dev/null | grep -q .; then
            perses_instance_found=true
        fi
        if [[ "$perses_instance_found" == "true" ]]; then
            log_success "Perses instance exists"
            ((tests_passed++))
        else
            log_error "Perses instance not found"
            log_info "  Expected in namespace: $perses_namespace or $NAMESPACE"
            log_info "  Perses instance should be auto-created by UIPlugin when Monitoring UI Plugin is installed"
            ((tests_failed++))
        fi
        ((total_tests++))
        
        echo ""
    fi
    
    # Test UWM if applicable
    if [[ "$test_type" == "uwm" ]] || [[ "$test_type" == "all" ]]; then
        log_test "Step 2: UWM Monitoring Tests"
        
        # Check if UWM is enabled
        local uwm_enabled=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -oE "enableUserWorkload:\s*true" || echo "")
        run_test "User Workload Monitoring enabled" "[[ -n \"$uwm_enabled\" ]]"
        
        # Check ServiceMonitor (UWM uses standard API group)
        local uwm_sm_exists=false
        if oc get servicemonitor eip-monitor-uwm -n "$NAMESPACE" &>/dev/null; then
            uwm_sm_exists=true
        fi
        if [[ "$uwm_sm_exists" == "true" ]]; then
            log_success "ServiceMonitor exists"
            ((tests_passed++))
        else
            log_error "ServiceMonitor exists"
            ((tests_failed++))
        fi
        ((total_tests++))
        
        # Check PrometheusRule (UWM uses standard API group)
        local uwm_pr_exists=false
        if oc get prometheusrule eip-monitor-alerts-uwm -n "$NAMESPACE" &>/dev/null; then
            uwm_pr_exists=true
        fi
        if [[ "$uwm_pr_exists" == "true" ]]; then
            log_success "PrometheusRule exists"
            ((tests_passed++))
        else
            log_error "PrometheusRule exists"
            ((tests_failed++))
        fi
        ((total_tests++))
        
        # Check UWM Prometheus pods
        local uwm_prom_pods=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
        if [[ "$uwm_prom_pods" -gt 0 ]]; then
            run_test "UWM Prometheus pods running" "oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -q ."
        else
            log_error "UWM Prometheus pods not found"
            ((tests_failed++))
            ((total_tests++))
        fi
        
        echo ""
    fi
    
    # Test common resources
    log_test "Step 3: Common Resources Tests"
    
    run_test "NetworkPolicy exists" "oc get networkpolicy eip-monitor-combined -n \"$NAMESPACE\" &>/dev/null"
    
    # Test metrics availability (if Prometheus is accessible)
    if [[ "$test_type" == "coo" ]] || [[ "$test_type" == "all" ]]; then
        local prom_pod=$(find_prometheus_pod "$NAMESPACE" "true")
        if [[ -n "$prom_pod" ]]; then
            local prom_phase=$(oc get pod "$prom_pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$prom_phase" == "Running" ]]; then
                # Test if eip-monitor metrics are being scraped
                local metrics_query=$(oc exec "$prom_pod" -n "$NAMESPACE" -- curl -sf "http://localhost:9090/api/v1/query?query=eips_configured_total" 2>/dev/null || echo "")
                run_test "EIP metrics available in Prometheus" "echo \"$metrics_query\" | grep -q \"eips_configured_total\""
            fi
        fi
    fi
    
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Test Summary: $tests_passed/$total_tests passed"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Restore original error handling state
    if [[ $original_set_e -eq 1 ]]; then
        set -e
    fi
    
    if [[ $tests_failed -eq 0 ]]; then
        log_success "All tests passed!"
        return 0
    else
        log_warn "$tests_failed test(s) failed"
        return 1
    fi
}

# Main function
main() {
    parse_args "$@"
    
    if ! check_prerequisites; then
        exit 1
    fi
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    log_info "Namespace: $NAMESPACE"
    
    # Handle status command
    if [[ "$SHOW_STATUS" == "true" ]]; then
        show_monitoring_status
        return 0
    fi
    
    # Handle test command
    if [[ "$TEST_MONITORING" == "true" ]]; then
        test_monitoring
        return $?
    fi
    
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
    
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Monitoring deployment completed successfully!"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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

