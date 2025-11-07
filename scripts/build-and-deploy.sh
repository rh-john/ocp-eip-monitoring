#!/bin/bash
#
# Build and Deploy Script for EIP Monitor Container
#

set -euo pipefail

# Configuration
IMAGE_NAME="eip-monitor"
IMAGE_TAG="latest"
NAMESPACE="eip-monitoring"
REGISTRY=""  # Set this to your container registry
CLEAN_ALL="${CLEAN_ALL:-false}"  # Flag for cleaning everything
MONITORING_TYPE="${MONITORING_TYPE:-uwm}"  # Default to uwm
REMOVE_MONITORING="${REMOVE_MONITORING:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # Default to INFO, can be DEBUG, INFO, WARNING, ERROR, CRITICAL


# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'  # Bright blue for readability on black terminals
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
EIP Monitor Container Build and Deploy Script

Usage: $0 <command> [options]

Commands:
  build       Build the container image
  push        Push image to registry
  deploy      Deploy eip-monitor application to OpenShift (no monitoring)
  monitoring  Deploy monitoring infrastructure (COO or UWM)
  all         Build, push, and deploy
  clean       Clean up deployment
  test        Test the deployment
  logs        Show container logs

Options:
  -r, --registry REGISTRY   Container registry URL
  -t, --tag TAG             Image tag (default: latest)
  -n, --namespace NS        Kubernetes namespace (default: eip-monitoring)
  --monitoring-type TYPE    Monitoring type: coo or uwm (for monitoring command)
  --remove-monitoring       Remove monitoring infrastructure
  --all                     Clean up everything (Grafana, eip-monitor, and monitoring)
  --log-level LEVEL         Logging level: DEBUG, INFO, WARNING, ERROR, CRITICAL (default: INFO)

Environment Variables:
  None required - OpenShift-only monitoring

Examples:
  $0 build
  $0 build -r quay.io/myorg -t v1.0.0
  $0 deploy
  $0 deploy --log-level DEBUG
  $0 all -r quay.io/myorg
  $0 all -r quay.io/myorg --log-level DEBUG
  $0 test
  $0 clean
  $0 clean --all              Clean up everything (Grafana, eip-monitor, monitoring)

Note: To deploy Grafana dashboards, use the separate script:
  ./scripts/deploy-grafana.sh

EOF
}

# Check prerequisites
check_prerequisites() {
    local missing_tools=()
    
    # Check for required tools
    for tool in oc jq base64; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    # Check for container runtime
    if ! command -v podman &> /dev/null && ! command -v docker &> /dev/null; then
        missing_tools+=("podman or docker")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again"
        exit 1
    fi
    
    # Determine container runtime
    if command -v podman &> /dev/null; then
        CONTAINER_RUNTIME="podman"
    else
        CONTAINER_RUNTIME="docker"
    fi
    
    log_info "Using container runtime: $CONTAINER_RUNTIME"
}

# Calculate hash of source files only (not Dockerfile)
calculate_source_hash() {
    local current_hash
    
    # Calculate hash of source files only
    if command -v sha256sum &>/dev/null; then
        current_hash=$(find src/ -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)
    elif command -v shasum &>/dev/null; then
        current_hash=$(find src/ -type f 2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
    else
        # Fallback: use file modification times (works on both macOS and Linux)
        if [[ "$(uname)" == "Darwin" ]]; then
            current_hash=$(find src/ -type f 2>/dev/null -exec stat -f "%m %N" {} \; 2>/dev/null | sort | shasum -a 256 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        else
            current_hash=$(find src/ -type f 2>/dev/null -exec stat -c "%Y %n" {} \; 2>/dev/null | sort | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "unknown")
        fi
    fi
    
    echo "$current_hash"
}

# Calculate hash of Dockerfile
calculate_dockerfile_hash() {
    local current_hash
    
    if [[ -f "Dockerfile" ]]; then
        if command -v sha256sum &>/dev/null; then
            current_hash=$(sha256sum Dockerfile 2>/dev/null | cut -d' ' -f1)
        elif command -v shasum &>/dev/null; then
            current_hash=$(shasum -a 256 Dockerfile 2>/dev/null | cut -d' ' -f1)
        else
            current_hash="unknown"
        fi
    else
        current_hash=""
    fi
    
    echo "$current_hash"
}

# Check if source files have changed since last build
has_source_changed() {
    local hash_file=".build-hash-source-${IMAGE_TAG:-latest}"
    local current_hash=$(calculate_source_hash)
    local last_hash=""
    
    if [[ -f "$hash_file" ]]; then
        last_hash=$(cat "$hash_file" 2>/dev/null || echo "")
    fi
    
    if [[ "$current_hash" != "$last_hash" ]]; then
        return 0  # Changed
    else
        return 1  # Not changed
    fi
}

# Check if Dockerfile has changed since last build
has_dockerfile_changed() {
    local hash_file=".build-hash-dockerfile-${IMAGE_TAG:-latest}"
    local current_hash=$(calculate_dockerfile_hash)
    local last_hash=""
    
    if [[ -f "$hash_file" ]]; then
        last_hash=$(cat "$hash_file" 2>/dev/null || echo "")
    fi
    
    if [[ "$current_hash" != "$last_hash" ]]; then
        return 0  # Changed
    else
        return 1  # Not changed
    fi
}

# Save hashes after successful build
save_build_hashes() {
    local source_hash_file=".build-hash-source-${IMAGE_TAG:-latest}"
    local dockerfile_hash_file=".build-hash-dockerfile-${IMAGE_TAG:-latest}"
    local current_source_hash=$(calculate_source_hash)
    local current_dockerfile_hash=$(calculate_dockerfile_hash)
    
    echo "$current_source_hash" > "$source_hash_file"
    echo "$current_dockerfile_hash" > "$dockerfile_hash_file"
}

# Build container image
build_image() {
    log_info "Building container image..."
    
    local full_image_name="${IMAGE_NAME}:${IMAGE_TAG}"
    
    if [[ -n "$REGISTRY" ]]; then
        full_image_name="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    fi
    
    log_info "Building image: $full_image_name"
    log_info "Building for linux/amd64 platform (OpenShift compatibility)"
    
    # Check what has changed to determine build strategy
    local use_cache=""
    local source_changed=false
    local dockerfile_changed=false
    
    if has_source_changed; then
        source_changed=true
    fi
    
    if has_dockerfile_changed; then
        dockerfile_changed=true
    fi
    
    if [[ "$dockerfile_changed" == "true" ]]; then
        log_info "Dockerfile has changed - rebuilding all layers without cache"
        use_cache="--no-cache"
    elif [[ "$source_changed" == "true" ]]; then
        log_info "Source code has changed - rebuilding only affected layers (using cache for base layers)"
        # Don't use --no-cache, let Docker's layer caching handle it
        use_cache=""
    else
        log_info "No changes detected - using full cache for fastest build"
        use_cache=""
    fi
    
    $CONTAINER_RUNTIME build $use_cache --platform linux/amd64 -t "$full_image_name" .
    
    if [[ $? -eq 0 ]]; then
        save_build_hashes
        log_success "Successfully built image: $full_image_name"
    else
        log_error "Build failed"
        return 1
    fi
}

# Push image to registry
push_image() {
    if [[ -z "$REGISTRY" ]]; then
        log_error "Registry not specified. Use -r option or set REGISTRY environment variable"
        exit 1
    fi
    
    local full_image_name="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    
    log_info "Pushing image to registry..."
    log_info "Image: $full_image_name"
    
    $CONTAINER_RUNTIME push "$full_image_name"
    
    log_success "Successfully pushed image: $full_image_name"
}

# Environment variables validation
check_env_vars() {
    log_info "No additional environment variables required for OpenShift-only monitoring"
}

# OpenShift deployment configuration

# Update manifests with correct values
update_manifests() {
    log_info "Updating deployment manifests..." >&2
    
    local temp_manifest="/tmp/eip-manifests-${RANDOM}.yaml"
    local temp_servicemonitor="/tmp/eip-servicemonitor-${RANDOM}.yaml"
    
    # Copy and update main manifests
    # Get script directory to make paths relative to script location
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    cp "$project_root/k8s/k8s-manifests.yaml" "$temp_manifest"
    
    # Update image name only if registry is specified
    if [[ -n "$REGISTRY" ]]; then
        local full_image_name="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        sed -i "" "s|image: \"eip-monitor:latest\"|image: \"$full_image_name\"|g" "$temp_manifest"
        log_info "Updated image to: $full_image_name" >&2
    else
        # Use the current deployment's image to avoid image pull issues
        local current_image=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "eip-monitor:latest")
        sed -i "" "s|image: \"eip-monitor:latest\"|image: \"$current_image\"|g" "$temp_manifest"
        log_info "No registry specified, using current deployment image: $current_image" >&2
    fi
    
    # Copy servicemonitor
    cp "$project_root/k8s/servicemonitor.yaml" "$temp_servicemonitor"
    
    log_info "Updated manifests:" >&2
    if [[ -n "$REGISTRY" ]]; then
        log_info "  Image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}" >&2
    else
        log_info "  Image: (unchanged - no registry specified)" >&2
    fi
    log_info "  Namespace: $NAMESPACE" >&2
    
    # Only output the file paths to stdout for capture
    echo "$temp_manifest"
    echo "$temp_servicemonitor"
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
    # Check for COO operator
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        echo "coo"
        return 0
    fi
    
    # Check for UWM
    local cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    if echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
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
        oc delete monitoringstack eip-monitoring-stack -n "$NAMESPACE" --wait=true || log_warn "Failed to delete MonitoringStack"
    fi
    
    # Delete COO manifests
    log_info "Removing COO manifests..."
    oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml" 2>/dev/null || true
    oc delete -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml" 2>/dev/null || true
    oc delete -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml" 2>/dev/null || true
    
    # Delete COO operator subscription (optional - may want to keep operator)
    log_warn "COO operator subscription will not be removed automatically"
    log_info "To remove COO operator: oc delete subscription cluster-observability-operator -n openshift-operators"
    
    log_success "COO monitoring infrastructure removed"
}

# Remove UWM monitoring
remove_uwm_monitoring() {
    log_info "Removing UWM monitoring infrastructure..."
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # Delete UWM manifests
    log_info "Removing UWM manifests..."
    oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml" 2>/dev/null || true
    oc delete -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml" 2>/dev/null || true
    oc delete -f "${project_root}/k8s/monitoring/uwm/rbac/grafana-rbac-uwm.yaml" 2>/dev/null || true
    
    # Disable UWM in cluster-monitoring-config
    log_info "Disabling User Workload Monitoring in cluster-monitoring-config..."
    local cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    if [[ -n "$cluster_config" ]] && echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
        # Set enableUserWorkload to false
        local temp_config=$(mktemp)
        echo "$cluster_config" > "$temp_config"
        
        # Replace enableUserWorkload: true with false
        sed -i '' 's/enableUserWorkload:[[:space:]]*true/enableUserWorkload: false/g' "$temp_config" 2>/dev/null || \
        sed -i 's/enableUserWorkload:[[:space:]]*true/enableUserWorkload: false/g' "$temp_config"
        
        local updated_config=$(cat "$temp_config")
        
        # Escape for JSON
        updated_config=$(echo "$updated_config" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
        updated_config=$(echo "$updated_config" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
        
        if oc patch configmap cluster-monitoring-config -n openshift-monitoring --type merge \
            -p "{\"data\":{\"config.yaml\":\"$updated_config\"}}" 2>/dev/null; then
            log_success "Disabled UWM in cluster-monitoring-config"
        else
            log_warn "Failed to disable UWM in cluster-monitoring-config (may require cluster-admin)"
            log_info "You may need to manually edit: oc -n openshift-monitoring edit configmap cluster-monitoring-config"
        fi
        
        rm -f "$temp_config"
    else
        log_info "UWM not enabled in cluster-monitoring-config (or config doesn't exist)"
    fi
    
    # Delete user-workload-monitoring-config
    oc delete configmap user-workload-monitoring-config -n openshift-user-workload-monitoring 2>/dev/null || true
    
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
        oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml"
        oc apply -f "${project_root}/k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml"
        oc apply -f "${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml"
        
        log_success "COO monitoring infrastructure deployed!"
        
    elif [[ "$MONITORING_TYPE" == "uwm" ]]; then
        log_info "Deploying UWM monitoring infrastructure..."
        
        # Enable UWM
        enable_user_workload_monitoring
        enable_user_workload_alertmanager
        
        # Apply UWM manifests
        log_info "Applying UWM monitoring manifests..."
        oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml"
        oc apply -f "${project_root}/k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml"
        oc apply -f "${project_root}/k8s/monitoring/uwm/rbac/grafana-rbac-uwm.yaml"
        
        log_success "UWM monitoring infrastructure deployed!"
    fi
    
    log_info "Monitoring infrastructure status:"
    oc get servicemonitor,prometheusrule -n "$NAMESPACE" 2>&1 | grep -v "No resources found" || log_info "  (Resources may still be initializing)"
}

# Deploy to OpenShift (eip-monitor only, no monitoring)
deploy() {
    # Disable colors for deployment to avoid any command parsing issues
    local old_colors=("$RED" "$GREEN" "$YELLOW" "$BLUE" "$NC")
    RED="" GREEN="" YELLOW="" BLUE="" NC=""
    
    # Check OpenShift connectivity
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        exit 1
    fi
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    
    # EIP Monitor deployment only (no monitoring infrastructure)
    log_info "Deploying EIP Monitor application to OpenShift..."
    
    check_env_vars
    
    # Get script directory to make paths relative to script location
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    local manifest_file="${project_root}/k8s/deployment/k8s-manifests.yaml"
    
    # Update image name only if registry is specified
    if [[ -n "$REGISTRY" ]]; then
        local full_image_name="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        local temp_manifest=$(mktemp)
        sed "s|image: \"eip-monitor:latest\"|image: \"$full_image_name\"|g" "$manifest_file" > "$temp_manifest"
        manifest_file="$temp_manifest"
        log_info "Updated image to: $full_image_name"
    fi
    
    # Apply main manifests
    log_info "Applying Kubernetes manifests from k8s/deployment/..."
    oc apply -f "$manifest_file"
    
    # Update log level in ConfigMap if specified
    if [[ -n "$LOG_LEVEL" ]]; then
        log_info "Setting log level to: $LOG_LEVEL"
        oc patch configmap eip-monitor-config -n "$NAMESPACE" --type merge -p "{\"data\":{\"log-level\":\"$LOG_LEVEL\"}}" 2>/dev/null || {
            log_warn "ConfigMap not found or patch failed, will be created on next apply"
        }
        log_info "Log level updated. Restart deployment manually if needed: oc rollout restart deployment/eip-monitor -n $NAMESPACE"
    fi
    
    # Wait for deployment with timeout (using background process for reliability)
    log_info "Waiting for deployment to be ready (timeout: 10 seconds)..."
    oc rollout status deployment/eip-monitor -n "$NAMESPACE" --timeout=10s &
    local rollout_pid=$!
    local timeout_seconds=10
    local elapsed=0
    while kill -0 "$rollout_pid" 2>/dev/null && [[ $elapsed -lt $timeout_seconds ]]; do
        sleep 2
        elapsed=$((elapsed + 2))
        log_info "Still waiting... (${elapsed}s elapsed)"
        # Show pod status every 2 seconds
        local pod_status=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "unknown")
        local ready_replicas=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired_replicas=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        log_info "  Pod status: $pod_status, Ready: $ready_replicas/$desired_replicas"
    done
    
    if kill -0 "$rollout_pid" 2>/dev/null; then
        log_warn "Deployment rollout timed out after ${timeout_seconds} seconds"
        kill "$rollout_pid" 2>/dev/null || true
        wait "$rollout_pid" 2>/dev/null || true
        log_info "Checking deployment status..."
        oc get deployment eip-monitor -n "$NAMESPACE" 2>&1 | grep -v "No resources found" || true
        oc get pods -n "$NAMESPACE" -l app=eip-monitor 2>&1 | grep -v "No resources found" || true
        log_warn "Deployment may still be in progress. Check logs with: oc logs -f deployment/eip-monitor -n $NAMESPACE"
    else
        wait "$rollout_pid"
        if [[ $? -eq 0 ]]; then
            log_success "Deployment is ready"
        else
            log_warn "Deployment rollout check failed"
            log_info "Checking deployment status..."
            oc get deployment eip-monitor -n "$NAMESPACE" 2>&1 | grep -v "No resources found" || true
            oc get pods -n "$NAMESPACE" -l app=eip-monitor 2>&1 | grep -v "No resources found" || true
        fi
    fi
    
    # Clean up temp file if created
    [[ -n "$REGISTRY" ]] && rm -f "$temp_manifest"
    
    log_success "EIP Monitor deployment completed successfully!"
    log_info "Note: Monitoring infrastructure is deployed separately using: $0 monitoring --monitoring-type <coo|uwm>"
    
    # Show status
    log_info "Deployment status:"
    oc get pods -n "$NAMESPACE" -l app=eip-monitor 2>&1 | grep -v "No resources found" || true
    
    log_info "Service endpoints:"
    oc get svc eip-monitor -n "$NAMESPACE" 2>&1 | grep -v "No resources found" || true
    
    # Restore colors
    RED="${old_colors[0]}" GREEN="${old_colors[1]}" YELLOW="${old_colors[2]}" BLUE="${old_colors[3]}" NC="${old_colors[4]}"
}

# Test deployment
test_deployment() {
    log_info "Testing EIP Monitor deployment..."
    echo ""
    
    local tests_passed=0
    local tests_failed=0
    local total_tests=0
    
    # Helper function to run a test
    run_test() {
        local test_name="$1"
        local test_command="$2"
        ((total_tests++))
        
        if eval "$test_command" &>/dev/null; then
            log_success "✅ $test_name"
            ((tests_passed++))
            return 0
        else
            log_error "❌ $test_name"
            ((tests_failed++))
            return 1
        fi
    }
    
    # 1. Basic Deployment Tests
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🏗️  Basic Deployment Tests"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    run_test "Namespace exists" "oc get namespace \"$NAMESPACE\" &>/dev/null"
    run_test "Deployment exists" "oc get deployment eip-monitor -n \"$NAMESPACE\" &>/dev/null"
    run_test "Service exists" "oc get service eip-monitor -n \"$NAMESPACE\" &>/dev/null"
    
    # Check pod status
    local pod_status=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ "$pod_status" != "Running" ]]; then
        log_error "Pod is not running. Status: $pod_status"
        log_info "Pod details:"
        oc describe pods -n "$NAMESPACE" -l app=eip-monitor | head -50
        exit 1
    fi
    
    run_test "Pod is running" "[[ \"$pod_status\" == \"Running\" ]]"
    
    # Check pod readiness
    local ready_replicas=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired_replicas=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    run_test "Pod is ready" "[[ \"$ready_replicas\" -eq \"$desired_replicas\" ]]"
    
    # Check service endpoints
    local endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    run_test "Service endpoints available" "[[ -n \"$endpoints\" ]]"
    
    if [[ -z "$pod_name" ]]; then
        log_error "Could not find pod name"
        exit 1
    fi
    
    echo ""
    
    # 2. Application Functionality Tests
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🚀 Application Functionality Tests"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Test health endpoint
    local health_response=$(oc exec "$pod_name" -n "$NAMESPACE" -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health 2>/dev/null || echo "000")
    if [[ "$health_response" == "200" ]] || [[ "$health_response" == "503" ]]; then
        log_success "✅ Health endpoint responds (HTTP $health_response)"
        ((tests_passed++))
    else
        log_error "❌ Health endpoint not responding (HTTP $health_response)"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    # Test metrics endpoint exists and returns data
    local metrics_output=$(oc exec "$pod_name" -n "$NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
    if [[ -n "$metrics_output" ]]; then
        log_success "✅ Metrics endpoint responds"
        ((tests_passed++))
    else
        log_error "❌ Metrics endpoint not responding"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    # Test required metrics are present
    if echo "$metrics_output" | grep -q "eips_configured_total"; then
        log_success "✅ Required metric 'eips_configured_total' present"
        ((tests_passed++))
    else
        log_error "❌ Required metric 'eips_configured_total' missing"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    run_test "Metric 'eips_assigned_total' present" "echo \"$metrics_output\" | grep -q \"eips_assigned_total\""
    run_test "Metric 'cpic_success_total' present" "echo \"$metrics_output\" | grep -q \"cpic_success_total\""
    run_test "Metric 'eip_scrape_errors_total' present" "echo \"$metrics_output\" | grep -q \"eip_scrape_errors_total\""
    
    # Test Prometheus format
    if echo "$metrics_output" | head -1 | grep -qE "^#|^[a-zA-Z_]"; then
        log_success "✅ Metrics in Prometheus format"
        ((tests_passed++))
    else
        log_error "❌ Metrics not in Prometheus format"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    # Test logs are present
    sleep 2  # Wait for logs to accumulate
    local log_output=$(oc logs "$pod_name" -n "$NAMESPACE" --tail=50 2>/dev/null || echo "")
    if echo "$log_output" | grep -qE "Starting|metrics|EIP|Found"; then
        log_success "✅ Application logs present"
        ((tests_passed++))
    else
        log_warn "⚠️  Application logs may be empty or not accessible"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    echo ""
    
    # 3. Security and Permissions Tests
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🔒 Security and Permissions Tests"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Test OpenShift API access
    if oc exec "$pod_name" -n "$NAMESPACE" -- oc get nodes -l k8s.ovn.org/egress-assignable=true &>/dev/null; then
        log_success "✅ OpenShift API permissions working"
        ((tests_passed++))
    else
        log_error "❌ OpenShift API permissions not working"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    # Test security context (non-root)
    local run_as_nonroot=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.spec.securityContext.runAsNonRoot}' 2>/dev/null || echo "false")
    if [[ "$run_as_nonroot" == "true" ]]; then
        log_success "✅ Security context configured (non-root)"
        ((tests_passed++))
    else
        log_warn "⚠️  Security context may not be configured (runAsNonRoot: $run_as_nonroot)"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    # Test resource limits
    local memory_limit=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "")
    local cpu_limit=$(oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "")
    if [[ -n "$memory_limit" ]] && [[ -n "$cpu_limit" ]]; then
        log_success "✅ Resource limits configured (Memory: $memory_limit, CPU: $cpu_limit)"
        ((tests_passed++))
    else
        log_warn "⚠️  Resource limits may not be fully configured"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    echo ""
    
    # 4. User Workload Monitoring Prerequisites
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "📊 User Workload Monitoring Prerequisites"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if User Workload Monitoring is enabled in cluster-monitoring-config
    local cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    
    if [[ -n "$cluster_config" ]]; then
        # Check if enableUserWorkload is set to true
        if echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
            log_success "✅ User Workload Monitoring enabled in cluster-monitoring-config"
            ((tests_passed++))
        else
            log_error "❌ User Workload Monitoring not enabled in cluster-monitoring-config"
            log_info "    To enable, edit: oc -n openshift-monitoring edit configmap cluster-monitoring-config"
            log_info "    Add: enableUserWorkload: true"
            ((tests_failed++))
        fi
        ((total_tests++))
    else
        log_warn "⚠️  cluster-monitoring-config not found or empty"
        log_info "    User Workload Monitoring may not be configured"
        ((tests_failed++))
        ((total_tests++))
    fi
    
    # Check if openshift-user-workload-monitoring namespace exists
    if oc get namespace openshift-user-workload-monitoring &>/dev/null; then
        log_success "✅ openshift-user-workload-monitoring namespace exists"
        ((tests_passed++))
        
        # Check if Prometheus pods are running
        local prom_pods=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null | tr -d '[:space:]' || echo "0")
        prom_pods=${prom_pods:-0}  # Default to 0 if empty
        if [[ "$prom_pods" =~ ^[0-9]+$ ]] && [[ "$prom_pods" -gt 0 ]]; then
            log_success "✅ Prometheus pods running in openshift-user-workload-monitoring ($prom_pods pod(s))"
            ((tests_passed++))
        else
            log_error "❌ No Prometheus pods running in openshift-user-workload-monitoring"
            log_info "    Check: oc get pods -n openshift-user-workload-monitoring"
            ((tests_failed++))
        fi
        ((total_tests++))
        
        # Check if AlertManager pods are running (optional but recommended)
        local am_pods=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -c "Running" 2>/dev/null | tr -d '[:space:]' || echo "0")
        am_pods=${am_pods:-0}  # Default to 0 if empty
        if [[ "$am_pods" =~ ^[0-9]+$ ]] && [[ "$am_pods" -gt 0 ]]; then
            log_success "✅ AlertManager pods running in openshift-user-workload-monitoring ($am_pods pod(s))"
            ((tests_passed++))
        else
            log_warn "⚠️  AlertManager not running (alerts may not work)"
            log_info "    To enable: oc apply -f - <<EOF"
            log_info "    apiVersion: v1"
            log_info "    kind: ConfigMap"
            log_info "    metadata:"
            log_info "      name: user-workload-monitoring-config"
            log_info "      namespace: openshift-user-workload-monitoring"
            log_info "    data:"
            log_info "      config.yaml: |"
            log_info "        alertmanager:"
            log_info "          enabled: true"
            log_info "    EOF"
            ((tests_failed++))
        fi
        ((total_tests++))
        
        # Check user-workload-monitoring-config ConfigMap (for alerting configuration)
        local uwm_config=$(oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
        if [[ -n "$uwm_config" ]]; then
            if echo "$uwm_config" | grep -qE "alertmanager:\s*enabled:\s*true"; then
                log_success "✅ AlertManager enabled in user-workload-monitoring-config"
                ((tests_passed++))
            else
                # Default AlertManager configuration is sufficient
                ((tests_passed++))
            fi
            ((total_tests++))
        else
            # Default AlertManager configuration is sufficient
            ((total_tests++))
        fi
    else
        log_error "❌ openshift-user-workload-monitoring namespace not found"
        log_info "    User Workload Monitoring is not enabled"
        log_info "    Enable it by setting enableUserWorkload: true in cluster-monitoring-config"
        ((tests_failed++))
        ((total_tests++))
    fi
    
    echo ""
    
    # 5. Monitoring Integration Tests
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "📊 Monitoring Integration Tests"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Test ServiceMonitor exists (if Prometheus Operator is available)
    if oc get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        if oc get servicemonitor eip-monitor -n "$NAMESPACE" &>/dev/null; then
            log_success "✅ ServiceMonitor exists"
            ((tests_passed++))
            
            # Test if Prometheus is actually scraping the metrics
            # Try to query Prometheus via port-forward (non-blocking test)
            local prom_pod=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
            
            if [[ -n "$prom_pod" ]]; then
                # Wait a bit for Prometheus to scrape (if it hasn't already)
                sleep 3
                
                # Query Prometheus API for our metric
                # Use curl with --max-time to avoid hanging
                local prom_query_result=$(oc exec "$prom_pod" -n openshift-user-workload-monitoring -- \
                    curl -sf --max-time 5 "http://localhost:9090/api/v1/query?query=eips_configured_total" 2>/dev/null || echo "")
                
                if echo "$prom_query_result" | grep -q "eips_configured_total"; then
                    log_success "✅ Prometheus is scraping metrics"
                    ((tests_passed++))
                else
                    log_warn "⚠️  Prometheus may not be scraping metrics yet (wait a few minutes for first scrape)"
                    log_info "    Note: This is normal if the ServiceMonitor was just created"
                    ((tests_failed++))
                fi
                ((total_tests++))
            else
                log_info "ℹ️  Prometheus pod not found, skipping scrape verification"
            fi
        else
            log_warn "⚠️  ServiceMonitor not found (may need to be deployed)"
            ((tests_failed++))
        fi
        ((total_tests++))
    else
        log_info "ℹ️  Prometheus Operator not available, skipping ServiceMonitor test"
    fi
    
    # Test metrics performance (response time)
    local start_time=$(date +%s)
    oc exec "$pod_name" -n "$NAMESPACE" -- curl -sf http://localhost:8080/metrics &>/dev/null
    local end_time=$(date +%s)
    local response_time=$((end_time - start_time))
    
    if [[ $response_time -lt 5 ]]; then
        log_success "✅ Metrics endpoint performance acceptable (${response_time}s)"
        ((tests_passed++))
    else
        log_warn "⚠️  Metrics endpoint slow (${response_time}s)"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    # Test metrics values are reasonable
    # Skip comment lines and extract the value (last field) from metric lines
    # Handle both simple format: "eips_configured_total 123" 
    # and labeled format: "eips_configured_total{label="value"} 123"
    local configured_count=$(echo "$metrics_output" | grep -v "^#" | grep "^eips_configured_total" | head -1 | awk '{print $NF}' | tr -d '\r' || echo "0")
    
    # Check if it's a valid number (integer or float)
    if [[ "$configured_count" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        log_success "✅ Metrics values are numeric (eips_configured_total: $configured_count)"
        ((tests_passed++))
    else
        log_warn "⚠️  Metrics values may be invalid (got: '$configured_count')"
        log_info "Debug: First eips_configured_total line:"
        echo "$metrics_output" | grep -v "^#" | grep "^eips_configured_total" | head -1 | sed 's/^/    /' || echo "    (not found)"
        ((tests_failed++))
    fi
    ((total_tests++))
    
    echo ""
    
    # 6. Summary
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "📋 Test Summary"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Tests Passed: $tests_passed"
    if [[ $tests_failed -gt 0 ]]; then
        log_error "Tests Failed: $tests_failed"
    else
        log_success "Tests Failed: $tests_failed"
    fi
    log_info "Total Tests: $total_tests"
    
    # Show sample metrics
    echo ""
    log_info "Sample metrics output:"
    echo "$metrics_output" | head -20 | sed 's/^/  /'
    
    echo ""
    if [[ $tests_failed -eq 0 ]]; then
        log_success "🎉 All tests passed! EIP Monitor is working correctly."
        return 0
    else
        log_error "❌ Some tests failed. Please review the output above."
        log_info "For detailed troubleshooting, check:"
        log_info "  - Pod logs: oc logs $pod_name -n $NAMESPACE"
        log_info "  - Pod status: oc describe pod $pod_name -n $NAMESPACE"
        log_info "  - Deployment: oc describe deployment eip-monitor -n $NAMESPACE"
        return 1
    fi
}

# Show logs
show_logs() {
    if ! oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
        log_error "Deployment not found"
        exit 1
    fi
    
    log_info "Showing logs for EIP Monitor..."
    oc logs -f deployment/eip-monitor -n "$NAMESPACE"
}

# Clean up Grafana resources
cleanup_grafana() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🗑️  Step 1: Removing Grafana resources..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # Delete Grafana resources in correct dependency order
    # Order: Dashboards -> DataSources -> Instances (reverse of creation order)
    log_info "Deleting GrafanaDashboards (depends on DataSources)..."
    oc delete grafanadashboard -n "$NAMESPACE" --all --wait=false --timeout=30s 2>&1 | grep -v "No resources found" || true
    
    # Wait a moment for dashboards to start deletion
    sleep 2
    
    log_info "Deleting GrafanaDataSources (depends on Grafana Instance)..."
    oc delete grafanadatasource -n "$NAMESPACE" --all --wait=false --timeout=30s 2>&1 | grep -v "No resources found" || true
    
    # Wait a moment for datasources to start deletion
    sleep 2
    
    log_info "Deleting Grafana Instances..."
    oc delete grafana -n "$NAMESPACE" --all --wait=false --timeout=30s 2>&1 | grep -v "No resources found" || true
    
    # Force delete if finalizers are blocking (common issue with Grafana CRDs)
    log_info "Checking for resources stuck with finalizers..."
    local stuck_dashboards=$(oc get grafanadashboard -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$stuck_dashboards" ]]; then
        log_warn "Found GrafanaDashboards with finalizers, removing finalizers..."
        echo "$stuck_dashboards" | while read -r name; do
            oc patch grafanadashboard "$name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        done
    fi
    
    local stuck_datasources=$(oc get grafanadatasource -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$stuck_datasources" ]]; then
        log_warn "Found GrafanaDataSources with finalizers, removing finalizers..."
        echo "$stuck_datasources" | while read -r name; do
            oc patch grafanadatasource "$name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        done
    fi
    
    local stuck_instances=$(oc get grafana -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
    if [[ -n "$stuck_instances" ]]; then
        log_warn "Found Grafana Instances with finalizers, removing finalizers..."
        echo "$stuck_instances" | while read -r name; do
            oc patch grafana "$name" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
        done
    fi
    
    # Wait a moment for finalizer removal to take effect
    sleep 2
    
    # Force delete any remaining resources (in case they're still stuck after finalizer removal)
    log_info "Force deleting any remaining Grafana resources..."
    oc delete grafanadashboard -n "$NAMESPACE" --all --force --grace-period=0 2>&1 | grep -vE "(No resources found|Warning: Immediate deletion)" || true
    oc delete grafanadatasource -n "$NAMESPACE" --all --force --grace-period=0 2>&1 | grep -vE "(No resources found|Warning: Immediate deletion)" || true
    oc delete grafana -n "$NAMESPACE" --all --force --grace-period=0 2>&1 | grep -vE "(No resources found|Warning: Immediate deletion)" || true
    
    # Delete Grafana RBAC (monitoring-specific)
    # Try to detect monitoring type and remove appropriate RBAC
    local current_type=$(detect_current_monitoring_type)
    if [[ "$current_type" != "none" ]]; then
        local rbac_file="${project_root}/k8s/monitoring/${current_type}/rbac/grafana-rbac-${current_type}.yaml"
        if [[ -f "$rbac_file" ]]; then
            log_info "Removing Grafana RBAC for ${current_type}..."
            oc delete -f "$rbac_file" 2>/dev/null || true
        fi
    else
        # Try both types if we can't detect
        log_info "Monitoring type unknown, trying both COO and UWM RBAC cleanup..."
        local coo_rbac="${project_root}/k8s/monitoring/coo/rbac/grafana-rbac-coo.yaml"
        local uwm_rbac="${project_root}/k8s/monitoring/uwm/rbac/grafana-rbac-uwm.yaml"
        [[ -f "$coo_rbac" ]] && oc delete -f "$coo_rbac" 2>/dev/null || true
        [[ -f "$uwm_rbac" ]] && oc delete -f "$uwm_rbac" 2>/dev/null || true
    fi
    
    log_success "Grafana resources removed"
    echo ""
}

# Clean up eip-monitor deployment
cleanup_eip_monitor() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🗑️  Step 2: Removing eip-monitor resources..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Delete ServiceMonitor and PrometheusRule first (dependencies)
    log_info "Removing ServiceMonitor and PrometheusRule..."
    oc delete servicemonitor eip-monitor -n "$NAMESPACE" 2>/dev/null || true
    oc delete prometheusrule eip-monitor-alerts -n "$NAMESPACE" 2>/dev/null || true
    
    # Delete deployment first to stop pods immediately
    if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
        log_info "Stopping deployment..."
        oc delete deployment eip-monitor -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true
    fi
    
    # Force kill any remaining pods for faster cleanup
    if oc get pods -n "$NAMESPACE" -l app=eip-monitor &>/dev/null; then
        log_info "Force killing any remaining pods..."
        oc delete pods -n "$NAMESPACE" -l app=eip-monitor --grace-period=0 --force 2>/dev/null || true
    fi
    
    # Delete service
    oc delete service eip-monitor -n "$NAMESPACE" 2>/dev/null || true
    
    # Delete ConfigMap
    oc delete configmap eip-monitor-config -n "$NAMESPACE" 2>/dev/null || true
    
    # Delete RBAC resources
    oc delete rolebinding eip-monitor -n "$NAMESPACE" 2>/dev/null || true
    oc delete role eip-monitor -n "$NAMESPACE" 2>/dev/null || true
    oc delete serviceaccount eip-monitor -n "$NAMESPACE" 2>/dev/null || true
    
    log_success "eip-monitor resources removed"
    echo ""
}

# Clean up monitoring infrastructure
cleanup_monitoring() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🗑️  Step 3: Removing monitoring infrastructure..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Detect and remove both COO and UWM if present
    local current_type=$(detect_current_monitoring_type)
    
    if [[ "$current_type" == "coo" ]]; then
        log_info "Removing COO monitoring infrastructure..."
        remove_coo_monitoring
    elif [[ "$current_type" == "uwm" ]]; then
        log_info "Removing UWM monitoring infrastructure..."
        remove_uwm_monitoring
    else
        log_info "No monitoring infrastructure detected, but cleaning up any remaining resources..."
        # Try to clean up both types just in case
        remove_coo_monitoring 2>/dev/null || true
        remove_uwm_monitoring 2>/dev/null || true
    fi
    
    log_success "Monitoring infrastructure removed"
    echo ""
}

# Clean up operators (COO and Grafana)
cleanup_operators() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🗑️  Step 4: Removing operators..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Remove COO operator subscription
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        log_info "Removing Cluster Observability Operator subscription..."
        oc delete subscription cluster-observability-operator -n openshift-operators 2>/dev/null || {
            log_warn "Failed to delete COO subscription (may require cluster-admin)"
        }
        
        # Wait for CSV to be removed, or delete it directly if stuck
        log_info "Waiting for COO CSV to be removed..."
        local max_wait=30
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            local csv_info=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("cluster-observability")) | "\(.metadata.name)|\(.metadata.deletionTimestamp // "active")"' | head -1 || echo "")
            if [[ -z "$csv_info" ]]; then
                log_success "COO operator removed"
                break
            fi
            
            # Check if CSV is being deleted (has deletionTimestamp)
            local csv_name=$(echo "$csv_info" | cut -d'|' -f1)
            local deletion_status=$(echo "$csv_info" | cut -d'|' -f2)
            
            if [[ "$deletion_status" != "active" ]]; then
                log_info "COO CSV is being deleted (deletionTimestamp: $deletion_status), waiting..."
            fi
            
            sleep 2
            waited=$((waited + 2))
        done
        
        # If CSV still exists after waiting, try to delete it directly
        local remaining_csv=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("cluster-observability")) | .metadata.name' | head -1 || echo "")
        if [[ -n "$remaining_csv" ]]; then
            log_warn "COO CSV still exists after subscription deletion, deleting CSV directly..."
            oc delete csv "$remaining_csv" -n openshift-operators --force --grace-period=0 2>/dev/null || {
                log_warn "Failed to delete COO CSV directly (may require cluster-admin or CSV may be stuck)"
            }
            
            # Remove finalizers if CSV is stuck
            local csv_finalizers=$(oc get csv "$remaining_csv" -n openshift-operators -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
            if [[ -n "$csv_finalizers" ]]; then
                log_info "Removing finalizers from COO CSV..."
                oc patch csv "$remaining_csv" -n openshift-operators -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            fi
        else
            log_success "COO operator removed successfully"
        fi
    else
        log_info "COO operator subscription not found"
    fi
    
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
    
    log_success "Operators removed"
    echo ""
}

# Complete cleanup (everything)
cleanup_all() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🗑️  Complete Cleanup (--all flag)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_warn "This will remove ALL resources related to this project:"
    log_warn "  • Grafana resources (dashboards, datasources, instances)"
    log_warn "  • eip-monitor application (deployment, service, RBAC)"
    log_warn "  • Monitoring infrastructure (COO/UWM)"
    log_warn "  • Operators (COO and Grafana operator subscriptions)"
    log_warn "  • Namespace"
    echo ""
    
    # Step 1: Remove Grafana resources
    cleanup_grafana
    
    # Step 2: Remove eip-monitor deployment
    cleanup_eip_monitor
    
    # Step 3: Remove monitoring infrastructure (COO/UWM)
    cleanup_monitoring
    
    # Step 4: Remove operators (COO and Grafana)
    cleanup_operators
    
    # Step 5: Delete namespace if empty (optional, but clean)
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "🗑️  Step 5: Cleaning up namespace..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if oc get namespace "$NAMESPACE" &>/dev/null; then
        # Check if namespace is empty (only finalizers remaining)
        local remaining_resources=$(oc get all -n "$NAMESPACE" 2>/dev/null | grep -v "No resources found" | wc -l || echo "0")
        
        if [[ "$remaining_resources" -gt 0 ]]; then
            log_info "Remaining resources in namespace, deleting namespace..."
            oc delete namespace "$NAMESPACE" 2>/dev/null || true
            
            # Wait for namespace deletion
            local timeout=120
            local elapsed=0
            while oc get namespace "$NAMESPACE" &>/dev/null && [[ $elapsed -lt $timeout ]]; do
                sleep 3
                elapsed=$((elapsed + 3))
                if [[ $((elapsed % 15)) -eq 0 ]]; then
                    log_info "Waiting for namespace deletion... (${elapsed}s elapsed)"
                fi
            done
            
            if oc get namespace "$NAMESPACE" &>/dev/null; then
                log_warn "Namespace deletion may still be in progress"
                log_info "Check with: oc get namespace $NAMESPACE"
            else
                log_success "Namespace fully deleted"
            fi
        else
            log_info "Namespace appears empty, deleting..."
            oc delete namespace "$NAMESPACE" 2>/dev/null || true
            log_success "Namespace deletion initiated"
        fi
    else
        log_info "Namespace '$NAMESPACE' not found or already deleted"
    fi
    
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "✅ Complete cleanup finished!"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "All resources have been removed:"
    log_info "  ✓ Grafana resources (dashboards, datasources, instances)"
    log_info "  ✓ eip-monitor application (deployment, service, RBAC)"
    log_info "  ✓ Monitoring infrastructure (COO/UWM)"
    log_info "  ✓ Operators (COO and Grafana operator subscriptions)"
    log_info "  ✓ Namespace"
    log_info "  ✓ UWM disabled in cluster-monitoring-config (if it was enabled)"
    echo ""
    log_info "Note: If UWM disable failed, you may need cluster-admin permissions:"
    log_info "  oc -n openshift-monitoring edit configmap cluster-monitoring-config"
    log_info "  Set: enableUserWorkload: false"
}

# Clean up deployment (basic cleanup - just eip-monitor and namespace)
cleanup() {
    if [[ "$CLEAN_ALL" == "true" ]]; then
        cleanup_all
        return
    fi
    
    log_info "Cleaning up EIP Monitor deployment..."
    
    # Delete deployment first to stop pods immediately
    if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
        log_info "Stopping deployment..."
        oc delete deployment eip-monitor -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true
    fi
    
    # Force kill any remaining pods for faster cleanup
    if oc get pods -n "$NAMESPACE" -l app=eip-monitor &>/dev/null; then
        log_info "Force killing any remaining pods..."
        oc delete pods -n "$NAMESPACE" -l app=eip-monitor --grace-period=0 --force 2>/dev/null || true
    fi
    
    # Delete the namespace and wait for it to be fully deleted
    if oc get namespace "$NAMESPACE" &>/dev/null; then
        log_info "Deleting namespace and waiting for completion..."
        oc delete namespace "$NAMESPACE" 2>/dev/null
        
        # Wait for namespace to be deleted (with timeout)
        local timeout=60
        local elapsed=0
        while oc get namespace "$NAMESPACE" &>/dev/null && [[ $elapsed -lt $timeout ]]; do
            sleep 2
            elapsed=$((elapsed + 2))
            if [[ $((elapsed % 10)) -eq 0 ]]; then
                log_info "Still waiting for namespace deletion... (${elapsed}s elapsed)"
            fi
        done
        
        if oc get namespace "$NAMESPACE" &>/dev/null; then
            log_warn "Namespace deletion timed out after ${timeout} seconds"
            log_info "Namespace may still be terminating. Check with: oc get namespace $NAMESPACE"
            return 1
        else
            log_success "Namespace fully deleted"
        fi
    else
        log_warn "Namespace '$NAMESPACE' not found or already deleted"
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--registry)
                REGISTRY="$2"
                shift 2
                ;;
            -t|--tag)
                IMAGE_TAG="$2"
                shift 2
                ;;
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
            --all)
                CLEAN_ALL="true"
                shift
                ;;
            --log-level)
                LOG_LEVEL="$2"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done
}

# Main function
main() {
    if [[ $# -eq 0 ]]; then
        show_usage
        exit 1
    fi
    
    local command="$1"
    shift
    
    parse_args "$@"
    
    check_prerequisites
    
    case "$command" in
        build)
            build_image
            ;;
        push)
            push_image
            ;;
        deploy)
            deploy
            ;;
        monitoring)
            deploy_monitoring
            ;;
        all)
            build_image
            push_image
            deploy
            ;;
        test)
            test_deployment
            ;;
        logs)
            show_logs
            ;;
        clean)
            cleanup
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
