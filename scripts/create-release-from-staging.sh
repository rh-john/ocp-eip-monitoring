#!/bin/bash
#
# Create Release: Merge staging to main and create release tag
# Creates a release by merging staging to main, bumping version, and creating tags
#
# Usage: ./scripts/create-release.sh [version]
#   version: Optional version number (e.g., 0.2.0). If not provided, will prompt.
#
# Example:
#   ./scripts/create-release.sh 0.2.0
#   ./scripts/create-release.sh    # Will prompt for version
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="${PROJECT_ROOT}/.version"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v git &>/dev/null; then
        log_error "git command not found"
        exit 1
    fi
    
    if ! git rev-parse --git-dir &>/dev/null; then
        log_error "Not in a git repository"
        exit 1
    fi
    
    # Check for uncommitted changes
    if [[ -n "$(git status --porcelain)" ]]; then
        log_error "You have uncommitted changes. Please commit or stash them first."
        git status --short
        exit 1
    fi
}

# Get current version
get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE" | tr -d '[:space:]'
    else
        echo "0.1.0"
    fi
}

# Validate version format
validate_version() {
    local version=$1
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid version format: $version (expected: x.y.z)"
        return 1
    fi
    return 0
}

# Set version in .version file
set_version() {
    local version=$1
    echo "$version" > "$VERSION_FILE"
    log_success "Version set to $version"
}

# Merge staging to main
merge_staging_to_main() {
    log_info "Switching to main branch..."
    git checkout main || {
        log_error "Failed to checkout main branch"
        return 1
    }
    
    log_info "Pulling latest main..."
    git pull origin main || {
        log_warn "Could not pull main, continuing with local version"
    }
    
    log_info "Merging staging into main..."
    if git merge staging --no-edit; then
        log_success "Successfully merged staging into main"
        return 0
    else
        log_error "Merge conflict detected!"
        log_info "Please resolve conflicts and run:"
        log_info "  git add ."
        log_info "  git commit"
        log_info "  git push origin main"
        log_info "Then run this script again to create the tag"
        return 1
    fi
}

# Create release tag
create_release_tag() {
    local version=$1
    local tag="v${version}"
    
    # Check if tag already exists
    if git rev-parse "$tag" >/dev/null 2>&1; then
        log_error "Tag $tag already exists"
        log_info "If you want to recreate it, delete it first:"
        log_info "  git tag -d $tag"
        log_info "  git push origin :refs/tags/$tag"
        return 1
    fi
    
    log_info "Creating release tag: $tag"
    git tag -a "$tag" -m "Release $tag

Merged from staging branch.
Version: $version"
    
    log_success "Created tag: $tag"
}

# Push changes
push_release() {
    local version=$1
    local tag="v${version}"
    
    log_info "Pushing main branch..."
    git push origin main || {
        log_error "Failed to push main branch"
        return 1
    }
    
    log_info "Pushing release tag: $tag"
    git push origin "$tag" || {
        log_error "Failed to push tag"
        return 1
    }
    
    log_success "Pushed main branch and tag $tag"
}

# Main function
main() {
    local target_version="${1:-}"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Create Release: Merge staging to main"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_prerequisites
    
    # Get current version
    local current_version=$(get_current_version)
    log_info "Current version: $current_version"
    
    # Get target version
    if [[ -z "$target_version" ]]; then
        echo ""
        read -p "Enter release version (e.g., 0.2.0): " target_version
        echo ""
    fi
    
    if [[ -z "$target_version" ]]; then
        log_error "Version is required"
        exit 1
    fi
    
    # Validate version
    if ! validate_version "$target_version"; then
        exit 1
    fi
    
    # Confirm
    echo ""
    log_warn "This will:"
    log_warn "  1. Merge staging → main"
    log_warn "  2. Set version to $target_version"
    log_warn "  3. Create tag v$target_version"
    log_warn "  4. Push main and tag to origin"
    echo ""
    read -p "Continue? (y/N): " confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        log_info "Cancelled"
        exit 0
    fi
    echo ""
    
    # Merge staging to main
    if ! merge_staging_to_main; then
        exit 1
    fi
    
    # Set version
    set_version "$target_version"
    git add "$VERSION_FILE"
    git commit -m "Bump version to $target_version" || {
        log_warn "Version file unchanged or commit failed"
    }
    
    # Create tag
    if ! create_release_tag "$target_version"; then
        exit 1
    fi
    
    # Push
    echo ""
    read -p "Push changes to origin? (y/N): " push_confirm
    if [[ "$push_confirm" == "y" ]] || [[ "$push_confirm" == "Y" ]]; then
        push_release "$target_version"
    else
        log_info "Skipping push. You can push manually with:"
        log_info "  git push origin main"
        log_info "  git push origin v$target_version"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_success "Release $target_version created successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_info "Release tag: v$target_version"
    log_info "Version file updated: .version"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Verify the release: git log --oneline -10"
    log_info "  2. Check tags: git tag -l 'v*'"
    log_info "  3. Create GitHub release (if using GitHub):"
    log_info "     https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/releases/new"
    log_info "  4. Monitor CI/CD pipeline for container builds"
}

# Run main function
main "$@"

