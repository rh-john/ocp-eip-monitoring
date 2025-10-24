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
    
    # Check if deployment exists
    if ! oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
        log_error "Deployment not found. Please deploy first."
        exit 1
    fi
    
    # Check pod status
    local pod_status=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    
    if [[ "$pod_status" != "Running" ]]; then
        log_error "Pod is not running. Status: $pod_status"
        log_info "Pod details:"
        oc describe pods -n "$NAMESPACE" -l app=eip-monitor
        exit 1
    fi
    
    log_success "Pod is running"
    
    # Test health endpoint
    log_info "Testing health endpoint..."
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}')
    
    if oc exec "$pod_name" -n "$NAMESPACE" -- curl -s http://localhost:8080/health | grep -q "healthy"; then
        log_success "Health endpoint is responding"
    else
        log_error "Health endpoint is not responding correctly"
        exit 1
    fi
    
    # Test metrics endpoint
    log_info "Testing metrics endpoint..."
    if oc exec "$pod_name" -n "$NAMESPACE" -- curl -s http://localhost:8080/metrics | grep -q "eips_configured_total"; then
        log_success "Metrics endpoint is working"
    else
        log_warn "Metrics endpoint may not be working correctly"
    fi
    
    log_success "All tests passed!"
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
