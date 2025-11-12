#!/bin/bash
#
# Release Creation Script
# Creates git tag and GitHub release
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions (logging)
source "${PROJECT_ROOT}/scripts/lib/common.sh"

# Note: Logging functions (log_info, log_success, log_warn, log_error) are sourced from scripts/lib/common.sh

VERSION_FILE="${PROJECT_ROOT}/.version"

if [[ ! -f "$VERSION_FILE" ]]; then
    log_error ".version file not found"
    exit 1
fi

version=$(cat "$VERSION_FILE" | tr -d '[:space:]')
tag="v${version}"

# Check if tag already exists
if git rev-parse "$tag" >/dev/null 2>&1; then
    log_error "Tag $tag already exists"
    exit 1
fi

# Create git tag
log_info "Creating git tag: $tag"
git tag -a "$tag" -m "Release $tag"

# Push tag
log_info "Pushing tag to remote..."
git push origin "$tag"

log_success "Created and pushed tag: $tag"
log_info "Version: $version"

