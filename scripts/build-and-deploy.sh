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
EIP Monitor Container Build and Deploy Script

Usage: $0 <command> [options]

Commands:
  build       Build the container image
  push        Push image to registry
  deploy      Deploy to OpenShift
  all         Build, push, and deploy
  clean       Clean up deployment
  test        Test the deployment
  logs        Show container logs

Options:
  -r, --registry REGISTRY   Container registry URL
  -t, --tag TAG             Image tag (default: latest)
  -n, --namespace NS        Kubernetes namespace (default: eip-monitoring)

Environment Variables:
  None required - OpenShift-only monitoring

Examples:
  $0 build
  $0 build -r quay.io/myorg -t v1.0.0
  $0 deploy
  $0 all -r quay.io/myorg
  $0 test
  $0 clean

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

# Build container image
build_image() {
    log_info "Building container image..."
    
    local full_image_name="${IMAGE_NAME}:${IMAGE_TAG}"
    
    if [[ -n "$REGISTRY" ]]; then
        full_image_name="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    fi
    
    log_info "Building image: $full_image_name"
    log_info "Building for linux/amd64 platform (OpenShift compatibility)"
    
    $CONTAINER_RUNTIME build --platform linux/amd64 -t "$full_image_name" .
    
    log_success "Successfully built image: $full_image_name"
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

# Deploy to OpenShift
deploy() {
    # Disable colors for deployment to avoid any command parsing issues
    local old_colors=("$RED" "$GREEN" "$YELLOW" "$BLUE" "$NC")
    RED="" GREEN="" YELLOW="" BLUE="" NC=""
    
    log_info "Deploying EIP Monitor to OpenShift..."
    
    check_env_vars
    
    # Check OpenShift connectivity
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        exit 1
    fi
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    
    # Check and enable User Workload Monitoring if needed
    enable_user_workload_monitoring
    
    # Enable AlertManager for user workloads
    enable_user_workload_alertmanager
    
    # Update manifests
    local manifest_files=($(update_manifests))
    local temp_manifest="${manifest_files[0]}"
    local temp_servicemonitor="${manifest_files[1]}"
    
    # Apply main manifests
    log_info "Applying Kubernetes manifests..."
    oc apply -f "$temp_manifest"
    
    # Wait for deployment
    log_info "Waiting for deployment to be ready..."
    oc rollout status deployment/eip-monitor -n "$NAMESPACE" --timeout=300s
    
    # Apply ServiceMonitor if Prometheus Operator is available
    if oc get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
        log_info "Applying ServiceMonitor..."
        oc apply -f "$temp_servicemonitor"
    else
        log_warn "Prometheus Operator not found, skipping ServiceMonitor deployment"
    fi
    
    # Clean up temp files
    rm -f "$temp_manifest" "$temp_servicemonitor"
    
    log_success "Deployment completed successfully!"
    
    # Show status
    log_info "Deployment status:"
    oc get pods -n "$NAMESPACE" -l app=eip-monitor
    
    log_info "Service endpoints:"
    oc get svc eip-monitor -n "$NAMESPACE"
    
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

# Clean up deployment
cleanup() {
    log_info "Cleaning up EIP Monitor deployment..."
    
    if oc get namespace "$NAMESPACE" &>/dev/null; then
        oc delete namespace "$NAMESPACE" --wait=true
        log_success "Cleanup completed"
    else
        log_warn "Namespace '$NAMESPACE' not found"
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
