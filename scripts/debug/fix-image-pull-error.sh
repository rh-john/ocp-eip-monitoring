#!/bin/bash
#
# Fix Image Pull Error
# 
# This script helps resolve the "Failed to pull image" error by either:
# 1. Building and pushing the missing image
# 2. Updating the deployment to use an existing image
#
# Usage: ./scripts/fix-image-pull-error.sh [options]
#
# Options:
#   --image IMAGE        The image that's failing (default: auto-detect from deployment)
#   --registry REGISTRY  Registry to use for building/pushing (default: quay.io/rh_ee_jjohanss)
#   --tag TAG           Tag to use (default: auto-detect from image or use latest)
#   --build             Build and push the image
#   --update            Update deployment to use a different image
#   --check             Just check if image exists (no changes)
#   --help, -h          Show this help message

set -euo pipefail

# Configuration
NAMESPACE="eip-monitoring"
REGISTRY="quay.io/rh_ee_jjohanss"
IMAGE_NAME="eip-monitor"
ACTION="check"  # check, build, update

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

show_usage() {
    cat << EOF
Fix Image Pull Error

This script helps resolve "Failed to pull image" errors.

Usage: $0 [options]

Options:
  --image IMAGE        The image that's failing (default: auto-detect from deployment)
  --registry REGISTRY  Registry to use (default: quay.io/rh_ee_jjohanss)
  --tag TAG           Tag to use (default: auto-detect or latest)
  --build             Build and push the missing image
  --update            Update deployment to use a different image
  --check             Just check if image exists (default)
  --help, -h          Show this help message

Examples:
  $0 --check                                    # Check current deployment image
  $0 --build --tag staging-20251107              # Build and push with specific tag
  $0 --update --image quay.io/org/eip-monitor:latest  # Update to use different image

EOF
}

# Detect container runtime
detect_runtime() {
    if command -v podman &> /dev/null; then
        echo "podman"
    elif command -v docker &> /dev/null; then
        echo "docker"
    else
        log_error "No container runtime found (podman or docker required)"
        exit 1
    fi
}

# Get current deployment image
get_current_image() {
    if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
        oc get deployment eip-monitor -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Check if image exists in registry
check_image_exists() {
    local image="$1"
    local runtime=$(detect_runtime)
    
    log_info "Checking if image exists: $image"
    
    # Try to pull the image (dry-run if possible)
    if $runtime manifest inspect "$image" &>/dev/null; then
        log_success "Image exists: $image"
        return 0
    else
        log_error "Image not found: $image"
        return 1
    fi
}

# Build and push image
build_and_push() {
    local full_image="$1"
    local runtime=$(detect_runtime)
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    log_info "Building image: $full_image"
    log_info "Using container runtime: $runtime"
    
    cd "$project_root"
    
    # Build the image
    log_info "Building container image..."
    $runtime build --platform linux/amd64 -t "$full_image" .
    
    if [[ $? -eq 0 ]]; then
        log_success "Image built successfully"
    else
        log_error "Build failed"
        return 1
    fi
    
    # Push the image
    log_info "Pushing image to registry..."
    $runtime push "$full_image"
    
    if [[ $? -eq 0 ]]; then
        log_success "Image pushed successfully: $full_image"
        return 0
    else
        log_error "Push failed"
        log_info "Make sure you're logged in to the registry:"
        log_info "  $runtime login quay.io"
        return 1
    fi
}

# Update deployment image
update_deployment() {
    local new_image="$1"
    
    log_info "Updating deployment to use image: $new_image"
    
    oc set image deployment/eip-monitor -n "$NAMESPACE" eip-monitor="$new_image"
    
    if [[ $? -eq 0 ]]; then
        log_success "Deployment updated"
        log_info "Waiting for rollout..."
        oc rollout status deployment/eip-monitor -n "$NAMESPACE" --timeout=120s || {
            log_warn "Rollout may still be in progress"
        }
        return 0
    else
        log_error "Failed to update deployment"
        return 1
    fi
}

# Parse arguments
parse_args() {
    local provided_image=""
    local provided_tag=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --image)
                provided_image="$2"
                shift 2
                ;;
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --tag)
                provided_tag="$2"
                shift 2
                ;;
            --build)
                ACTION="build"
                shift
                ;;
            --update)
                ACTION="update"
                shift
                ;;
            --check)
                ACTION="check"
                shift
                ;;
            --help|-h)
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
    
    # Determine image to work with
    if [[ -n "$provided_image" ]]; then
        TARGET_IMAGE="$provided_image"
    else
        # Auto-detect from deployment
        local current_image=$(get_current_image)
        if [[ -n "$current_image" ]]; then
            TARGET_IMAGE="$current_image"
            log_info "Detected image from deployment: $current_image"
        else
            # Construct from registry and tag
            if [[ -n "$provided_tag" ]]; then
                TARGET_IMAGE="${REGISTRY}/${IMAGE_NAME}:${provided_tag}"
            else
                TARGET_IMAGE="${REGISTRY}/${IMAGE_NAME}:latest"
            fi
        fi
    fi
}

# Main function
main() {
    parse_args "$@"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Fix Image Pull Error"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check OpenShift connectivity
    if ! oc whoami &>/dev/null; then
        log_error "Not connected to OpenShift cluster. Please login with 'oc login'"
        exit 1
    fi
    
    log_info "Connected to OpenShift as: $(oc whoami)"
    echo ""
    
    # Show current deployment status
    if oc get deployment eip-monitor -n "$NAMESPACE" &>/dev/null; then
        local current_image=$(get_current_image)
        log_info "Current deployment image: ${current_image:-not set}"
        
        local pod_status=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "not found")
        log_info "Pod status: $pod_status"
        
        if [[ "$pod_status" != "Running" ]]; then
            local waiting_reason=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")
            if [[ -n "$waiting_reason" ]]; then
                log_warn "Pod waiting reason: $waiting_reason"
            fi
        fi
        echo ""
    else
        log_warn "Deployment not found in namespace $NAMESPACE"
        echo ""
    fi
    
    # Perform action
    case "$ACTION" in
        check)
            log_info "Checking image: $TARGET_IMAGE"
            if check_image_exists "$TARGET_IMAGE"; then
                log_success "Image exists and should be accessible"
            else
                log_error "Image does not exist or is not accessible"
                echo ""
                log_info "Solutions:"
                log_info "1. Build and push the image:"
                log_info "   $0 --build --image $TARGET_IMAGE"
                log_info ""
                log_info "2. Update deployment to use an existing image:"
                log_info "   $0 --update --image quay.io/your-org/eip-monitor:latest"
                log_info ""
                log_info "3. Check registry authentication:"
                log_info "   podman login quay.io"
                log_info "   # or"
                log_info "   docker login quay.io"
            fi
            ;;
        build)
            log_info "Building and pushing image: $TARGET_IMAGE"
            if build_and_push "$TARGET_IMAGE"; then
                log_success "Image built and pushed successfully"
                log_info "Updating deployment to use new image..."
                update_deployment "$TARGET_IMAGE"
            else
                log_error "Failed to build/push image"
                exit 1
            fi
            ;;
        update)
            log_info "Updating deployment to use image: $TARGET_IMAGE"
            if check_image_exists "$TARGET_IMAGE"; then
                update_deployment "$TARGET_IMAGE"
            else
                log_error "Cannot update: image does not exist"
                log_info "Build the image first:"
                log_info "  $0 --build --image $TARGET_IMAGE"
                exit 1
            fi
            ;;
    esac
}

# Run main function
main "$@"

