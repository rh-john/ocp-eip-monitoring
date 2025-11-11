#!/bin/bash
#
# Merge Feature Branches to Staging
# 
# This script merges all feature branches (dev, grafana, monitoring) into staging
# and triggers the CI/CD pipeline for integration testing and container builds.
#
# Usage: ./scripts/merge-to-staging.sh [options]
#
# Options:
#   --dry-run          Show what would be merged without actually merging
#   --skip-tests       Skip running tests after merge
#   --push             Automatically push to remote (default: requires confirmation)
#   --help, -h         Show this help message
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
FEATURE_BRANCHES=("dev" "grafana" "monitoring")
TARGET_BRANCH="staging"
DRY_RUN=false
SKIP_TESTS=false
AUTO_PUSH=false

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

# Show usage
show_usage() {
    cat << EOF
Merge Feature Branches to Staging

This script merges feature branches into staging and triggers CI/CD pipeline.

Usage: $0 [options]

Options:
  --dry-run          Show what would be merged without actually merging
  --skip-tests       Skip running tests after merge
  --push             Automatically push to remote (default: requires confirmation)
  --help, -h         Show this help message

Feature Branches:
  - dev       (EIP monitoring application + COO/UWM support)
  - grafana   (Grafana dashboards and deployment)
  - monitoring  (COO monitoring infrastructure - may be in dev)

Workflow:
  1. Fetch all branches
  2. Switch to staging branch
  3. Merge feature branches in order (dev → grafana → monitoring)
  4. Resolve conflicts (if any)
  5. Run tests (optional)
  6. Push to remote (triggers CI/CD pipeline)

Examples:
  $0                    # Interactive merge with confirmation
  $0 --dry-run          # See what would be merged
  $0 --push             # Auto-push after merge
  $0 --skip-tests --push # Merge and push without tests

EOF
}

# Check prerequisites
check_prerequisites() {
    local missing_tools=()
    
    for tool in git; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    # Check if we're in a git repository
    if ! git rev-parse --git-dir &>/dev/null; then
        log_error "Not in a git repository"
        exit 1
    fi
}

# Fetch all branches
fetch_branches() {
    log_info "Fetching all branches from remote..."
    git fetch --all --prune
    log_success "Branches fetched"
}

# Check what needs to be merged
check_merge_status() {
    log_info "Checking merge status..."
    
    cd "$PROJECT_ROOT"
    git checkout "$TARGET_BRANCH" &>/dev/null || {
        log_error "Cannot checkout $TARGET_BRANCH branch"
        exit 1
    }
    git pull origin "$TARGET_BRANCH" &>/dev/null || true
    
    echo ""
    log_info "Branches to merge into $TARGET_BRANCH:"
    echo ""
    
    local needs_merge=false
    for branch in "${FEATURE_BRANCHES[@]}"; do
        if ! git rev-parse --verify "origin/$branch" &>/dev/null; then
            log_warn "Branch origin/$branch not found, skipping"
            continue
        fi
        
        # Check if branch is already merged
        if git merge-base --is-ancestor "origin/$branch" "$TARGET_BRANCH" 2>/dev/null; then
            log_info "  ✓ $branch - already merged"
        else
            local commits_ahead=$(git rev-list --count "$TARGET_BRANCH..origin/$branch" 2>/dev/null || echo "0")
            if [[ "$commits_ahead" -gt 0 ]]; then
                log_warn "  → $branch - $commits_ahead commit(s) ahead"
                needs_merge=true
            else
                log_info "  ✓ $branch - up to date"
            fi
        fi
    done
    
    echo ""
    
    if [[ "$needs_merge" == "false" ]] && [[ "$DRY_RUN" == "false" ]]; then
        log_success "All branches are already merged into $TARGET_BRANCH"
        return 1
    fi
    
    return 0
}

# Merge a branch
merge_branch() {
    local branch="$1"
    local branch_ref="origin/$branch"
    
    log_info "Merging $branch into $TARGET_BRANCH..."
    
    # Check if branch exists
    if ! git rev-parse --verify "$branch_ref" &>/dev/null; then
        log_warn "Branch $branch_ref not found, skipping"
        return 0
    fi
    
    # Check if already merged
    if git merge-base --is-ancestor "$branch_ref" "$TARGET_BRANCH" 2>/dev/null; then
        log_info "  $branch is already merged, skipping"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local commits=$(git rev-list --count "$TARGET_BRANCH..$branch_ref" 2>/dev/null || echo "0")
        log_info "  [DRY RUN] Would merge $commits commit(s) from $branch"
        return 0
    fi
    
    # Perform merge
    if git merge "$branch_ref" --no-ff -m "Merge $branch into $TARGET_BRANCH: integration" 2>&1; then
        log_success "Successfully merged $branch"
        return 0
    else
        local merge_status=$?
        log_error "Merge conflict with $branch"
        echo ""
        log_info "Conflicts detected. Please resolve manually:"
        echo ""
        log_info "1. Review conflicts:"
        log_info "   git status"
        echo ""
        log_info "2. Resolve conflicts in the files listed above"
        echo ""
        log_info "3. Stage resolved files:"
        log_info "   git add <resolved-files>"
        echo ""
        log_info "4. Complete the merge:"
        log_info "   git commit"
        echo ""
        log_info "5. Then run this script again to continue with remaining branches"
        echo ""
        return $merge_status
    fi
}

# Main merge process
perform_merge() {
    cd "$PROJECT_ROOT"
    
    # Ensure we're on staging
    if [[ "$(git branch --show-current)" != "$TARGET_BRANCH" ]]; then
        log_info "Switching to $TARGET_BRANCH branch..."
        git checkout "$TARGET_BRANCH"
    fi
    
    # Ensure staging is up to date
    log_info "Updating $TARGET_BRANCH from remote..."
    git pull origin "$TARGET_BRANCH" || {
        log_warn "Could not pull $TARGET_BRANCH, continuing with local version"
    }
    
    # Merge branches in order
    local merge_failed=false
    for branch in "${FEATURE_BRANCHES[@]}"; do
        if ! merge_branch "$branch"; then
            merge_failed=true
            break
        fi
    done
    
    if [[ "$merge_failed" == "true" ]]; then
        log_error "Merge process incomplete. Please resolve conflicts and try again."
        exit 1
    fi
    
    log_success "All branches merged successfully"
}

# Run tests
run_tests() {
    if [[ "$SKIP_TESTS" == "true" ]]; then
        log_info "Skipping tests (--skip-tests flag)"
        return 0
    fi
    
    log_info "Running tests..."
    
    if [[ -f "$PROJECT_ROOT/scripts/test/test-deployment.sh" ]]; then
        if "$PROJECT_ROOT/scripts/test/test-deployment.sh"; then
            log_success "Tests passed"
            return 0
        else
            log_warn "Some tests failed, but continuing..."
            return 0
        fi
    else
        log_warn "Test script not found, skipping tests"
        return 0
    fi
}

# Push to remote
push_to_remote() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would push to origin/$TARGET_BRANCH"
        return 0
    fi
    
    log_info "Preparing to push to origin/$TARGET_BRANCH..."
    
    # Show what will be pushed
    local commits_ahead=$(git rev-list --count "origin/$TARGET_BRANCH..$TARGET_BRANCH" 2>/dev/null || echo "0")
    if [[ "$commits_ahead" -eq 0 ]]; then
        log_info "No new commits to push"
        return 0
    fi
    
    log_info "Will push $commits_ahead new commit(s)"
    git log --oneline "origin/$TARGET_BRANCH..$TARGET_BRANCH" | head -5
    
    if [[ "$AUTO_PUSH" == "false" ]]; then
        echo ""
        read -p "Push to origin/$TARGET_BRANCH? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Push cancelled"
            return 0
        fi
    fi
    
    log_info "Pushing to origin/$TARGET_BRANCH..."
    if git push origin "$TARGET_BRANCH"; then
        log_success "Pushed to origin/$TARGET_BRANCH"
        log_info "CI/CD pipeline will be triggered automatically"
        return 0
    else
        log_error "Failed to push to remote"
        return 1
    fi
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --skip-tests)
                SKIP_TESTS=true
                shift
                ;;
            --push)
                AUTO_PUSH=true
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
}

# Main function
main() {
    parse_args "$@"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Merge Feature Branches to Staging"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_prerequisites
    fetch_branches
    
    if ! check_merge_status; then
        exit 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN MODE - No changes will be made"
        echo ""
    fi
    
    perform_merge
    
    if [[ "$DRY_RUN" == "false" ]]; then
        run_tests
        push_to_remote
        
        echo ""
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "Merge to staging completed!"
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        log_info "Next steps:"
        log_info "1. Monitor CI/CD pipeline: https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\(.*\)\.git/\1/')/actions"
        log_info "2. Check container builds: quay.io/<your-repo>/eip-monitor"
        log_info "3. Review pre-release tags: git tag -l 'v*-rc*'"
    else
        echo ""
        log_info "DRY RUN completed - no changes made"
        log_info "Run without --dry-run to perform the merge"
    fi
}

# Run main function
main "$@"

