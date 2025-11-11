#!/bin/bash
#
# Merge Feature Branches to Staging
# 
# This script merges all feature branches (eip-monitor, dev, grafana, monitoring) into staging
# and triggers the CI/CD pipeline for integration testing and container builds.
#
# Usage: ./scripts/merge-to-staging.sh [options]
#
# Options:
#   --dry-run          Show what would be merged without actually merging
#   --skip-tests       Skip running tests after merge
#   --push             Automatically push to remote (default: requires confirmation)
#   --use-local        Merge from local branches if they're ahead of remote (default: only merge from remote)
#   --strategy STRAT   Merge strategy: 'ours', 'theirs', or 'manual' (default: manual)
#   --help, -h         Show this help message
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
FEATURE_BRANCHES=("eip-monitor" "dev" "grafana" "monitoring")
TARGET_BRANCH="staging"
DRY_RUN=false
SKIP_TESTS=false
AUTO_PUSH=false
USE_LOCAL=false
MERGE_STRATEGY="manual"

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
  --use-local        Merge from local branches if they're ahead of remote (default: only merge from remote)
  --strategy STRAT   Auto-resolve conflicts: 'ours' (keep staging), 'theirs' (keep feature), 'manual' (default)
  --help, -h         Show this help message

Feature Branches:
  - eip-monitor  (EIP monitoring tool: src/, k8s-manifests.yaml, deploy-eip.sh)
  - dev          (General development and integration work)
  - grafana      (Grafana dashboards and deployment)
  - monitoring   (COO monitoring infrastructure)

Workflow:
  1. Fetch all branches
  2. Switch to staging branch
  3. Merge feature branches in order (eip-monitor → dev → grafana → monitoring)
  4. Resolve conflicts (if any) - can auto-resolve with --strategy
  5. Run tests (optional)
  6. Push to remote (triggers CI/CD pipeline)

Merge Strategy:
  Regular merges (not squash) are used for better conflict resolution.
  Use --strategy to auto-resolve conflicts:
    - 'ours': Keep staging's version for all conflicts
    - 'theirs': Keep feature branch's version for all conflicts
    - 'manual': Resolve conflicts manually (default)

Examples:
  $0                              # Interactive merge with confirmation
  $0 --dry-run                    # See what would be merged
  $0 --push                       # Auto-push after merge
  $0 --strategy ours              # Auto-resolve conflicts (keep staging)
  $0 --strategy theirs            # Auto-resolve conflicts (keep feature branch)
  $0 --skip-tests --push          # Merge and push without tests

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
        local remote_exists=false
        local local_exists=false
        local remote_ahead=0
        local local_ahead=0
        
        # Check remote branch
        if git rev-parse --verify "origin/$branch" &>/dev/null; then
            remote_exists=true
            if ! git merge-base --is-ancestor "origin/$branch" "$TARGET_BRANCH" 2>/dev/null; then
                remote_ahead=$(git rev-list --count "$TARGET_BRANCH..origin/$branch" 2>/dev/null || echo "0")
            fi
        fi
        
        # Check local branch
        if git rev-parse --verify "$branch" &>/dev/null; then
            local_exists=true
            if ! git merge-base --is-ancestor "$branch" "$TARGET_BRANCH" 2>/dev/null; then
                local_ahead=$(git rev-list --count "$TARGET_BRANCH..$branch" 2>/dev/null || echo "0")
            fi
            
            # Check if local is ahead of remote
            if [[ "$remote_exists" == "true" ]]; then
                local local_vs_remote=$(git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "0")
                if [[ "$local_vs_remote" -gt 0 ]]; then
                    log_warn "  ⚠ $branch - local branch has $local_vs_remote unpushed commit(s)"
                    if [[ "$USE_LOCAL" == "false" ]]; then
                        log_info "     (Use --use-local to merge from local branch, or push first)"
                    fi
                fi
            fi
        fi
        
        # Determine status
        if [[ "$remote_exists" == "false" ]] && [[ "$local_exists" == "false" ]]; then
            log_warn "  ✗ $branch - branch not found (remote or local)"
            continue
        elif [[ "$remote_ahead" -gt 0 ]]; then
            log_warn "  → $branch (remote) - $remote_ahead commit(s) ahead"
            needs_merge=true
        elif [[ "$local_ahead" -gt 0 ]] && [[ "$USE_LOCAL" == "true" ]]; then
            log_warn "  → $branch (local) - $local_ahead commit(s) ahead"
            needs_merge=true
        elif [[ "$remote_ahead" -eq 0 ]] && [[ "$local_ahead" -eq 0 ]]; then
            log_info "  ✓ $branch - already merged"
        else
            log_info "  ✓ $branch - up to date"
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
    local branch_ref=""
    local branch_source=""
    
    # Determine which branch to merge from
    local remote_exists=false
    local local_exists=false
    local remote_ahead=0
    local local_ahead=0
    local local_vs_remote=0
    
    # Check remote branch
    if git rev-parse --verify "origin/$branch" &>/dev/null; then
        remote_exists=true
        if ! git merge-base --is-ancestor "origin/$branch" "$TARGET_BRANCH" 2>/dev/null; then
            remote_ahead=$(git rev-list --count "$TARGET_BRANCH..origin/$branch" 2>/dev/null || echo "0")
        fi
    fi
    
    # Check local branch
    if git rev-parse --verify "$branch" &>/dev/null; then
        local_exists=true
        if ! git merge-base --is-ancestor "$branch" "$TARGET_BRANCH" 2>/dev/null; then
            local_ahead=$(git rev-list --count "$TARGET_BRANCH..$branch" 2>/dev/null || echo "0")
        fi
        
        # Check if local is ahead of remote
        if [[ "$remote_exists" == "true" ]]; then
            local_vs_remote=$(git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "0")
        fi
    fi
    
    # Determine which branch to use
    if [[ "$USE_LOCAL" == "true" ]] && [[ "$local_exists" == "true" ]] && [[ "$local_ahead" -gt 0 ]]; then
        # Use local branch if --use-local and local has commits
        branch_ref="$branch"
        branch_source="local"
    elif [[ "$remote_exists" == "true" ]] && [[ "$remote_ahead" -gt 0 ]]; then
        # Use remote branch if it has commits
        branch_ref="origin/$branch"
        branch_source="remote"
    elif [[ "$local_exists" == "true" ]] && [[ "$local_ahead" -gt 0 ]] && [[ "$remote_exists" == "false" ]]; then
        # Use local branch if remote doesn't exist
        branch_ref="$branch"
        branch_source="local"
    elif [[ "$remote_exists" == "true" ]]; then
        # Default to remote
        branch_ref="origin/$branch"
        branch_source="remote"
    else
        log_warn "Branch $branch not found (remote or local), skipping"
        return 0
    fi
    
    log_info "Merging $branch into $TARGET_BRANCH (from $branch_source)..."
    
    # Check if already merged
    if git merge-base --is-ancestor "$branch_ref" "$TARGET_BRANCH" 2>/dev/null; then
        log_info "  $branch is already merged, skipping"
        return 0
    fi
    
    # Warn if local has unpushed commits and we're merging from remote
    if [[ "$local_vs_remote" -gt 0 ]] && [[ "$branch_source" == "remote" ]]; then
        log_warn "  ⚠ Local $branch has $local_vs_remote unpushed commit(s) that will NOT be merged"
        log_info "     (Use --use-local to merge from local branch instead)"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local commits=$(git rev-list --count "$TARGET_BRANCH..$branch_ref" 2>/dev/null || echo "0")
        log_info "  [DRY RUN] Would merge $commits commit(s) from $branch ($branch_source)"
        return 0
    fi
    
    # Perform regular merge (better conflict resolution than squash)
    # Regular merges preserve merge base and make conflict resolution easier
    if git merge "$branch_ref" --no-ff -m "Merge $branch into $TARGET_BRANCH: integration" 2>&1; then
        log_success "Successfully merged $branch (from $branch_source)"
        return 0
    else
        local merge_status=$?
        log_error "Merge conflict with $branch"
        echo ""
        
        # Show which files have conflicts
        local conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
        if [[ -n "$conflicted_files" ]]; then
            log_info "Conflicted files:"
            echo "$conflicted_files" | while read -r file; do
                log_info "  - $file"
            done
            echo ""
        fi
        
        # Auto-resolve conflicts if strategy is specified
        if [[ "$MERGE_STRATEGY" != "manual" ]]; then
            log_info "Auto-resolving conflicts using '$MERGE_STRATEGY' strategy..."
            if [[ "$MERGE_STRATEGY" == "ours" ]]; then
                # Keep staging's version for all conflicts
                echo "$conflicted_files" | while read -r file; do
                    if [[ -n "$file" ]]; then
                        log_info "  Keeping staging version: $file"
                        git checkout --ours "$file" 2>/dev/null || true
                        git add "$file" 2>/dev/null || true
                    fi
                done
            elif [[ "$MERGE_STRATEGY" == "theirs" ]]; then
                # Keep feature branch's version for all conflicts
                echo "$conflicted_files" | while read -r file; do
                    if [[ -n "$file" ]]; then
                        log_info "  Keeping feature branch version: $file"
                        git checkout --theirs "$file" 2>/dev/null || true
                        git add "$file" 2>/dev/null || true
                    fi
                done
            fi
            
            # Complete the merge
            if git commit --no-edit 2>&1; then
                log_success "Auto-resolved conflicts and completed merge"
                return 0
            else
                log_error "Failed to complete auto-resolved merge"
                return 1
            fi
        else
            # Manual resolution
            log_info "Conflict resolution options:"
            echo ""
            log_info "1. Auto-resolve using staging's version (ours):"
            log_info "   git checkout --ours <file>"
            log_info "   git add <file>"
            echo ""
            log_info "2. Auto-resolve using feature branch's version (theirs):"
            log_info "   git checkout --theirs <file>"
            log_info "   git add <file>"
            echo ""
            log_info "3. Resolve all conflicts automatically:"
            log_info "   # Keep staging's version for all:"
            log_info "   git checkout --ours . && git add . && git commit --no-edit"
            log_info "   # Or keep feature branch's version for all:"
            log_info "   git checkout --theirs . && git add . && git commit --no-edit"
            echo ""
            log_info "4. Manual resolution:"
            log_info "   # Edit conflicted files, then:"
            log_info "   git add <resolved-files>"
            log_info "   git commit --no-edit"
            echo ""
            log_info "5. After resolving, run this script again to continue with remaining branches"
            echo ""
            log_info "Quick commands:"
            log_info "  git status                    # See all conflicts"
            log_info "  git diff --check              # Check for conflict markers"
            log_info "  git mergetool                 # Use merge tool (if configured)"
            echo ""
            return $merge_status
        fi
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
            --use-local)
                USE_LOCAL=true
                shift
                ;;
            --strategy)
                MERGE_STRATEGY="$2"
                if [[ "$MERGE_STRATEGY" != "ours" ]] && [[ "$MERGE_STRATEGY" != "theirs" ]] && [[ "$MERGE_STRATEGY" != "manual" ]]; then
                    log_error "Invalid strategy: $MERGE_STRATEGY. Must be 'ours', 'theirs', or 'manual'"
                    exit 1
                fi
                shift 2
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

