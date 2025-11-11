#!/bin/bash
#
# Sync Main Branch to Other Branches
# 
# This script propagates changes from main to staging and feature branches
# to keep all branches in sync with the latest release.
#
# Usage: ./scripts/sync-from-main.sh [options]
#
# Options:
#   --dry-run          Show what would be synced without actually syncing
#   --push             Automatically push to remote (default: requires confirmation)
#   --strategy STRAT   Auto-resolve conflicts: 'ours' (keep main), 'theirs' (keep branch), 'manual' (default)
#   --help, -h         Show this help message
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
SOURCE_BRANCH="main"
TARGET_BRANCHES=("staging" "dev" "eip-monitor" "grafana" "monitoring")
DRY_RUN=false
AUTO_PUSH=false
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
Sync Main Branch to Other Branches

This script propagates changes from main to staging and feature branches.

Usage: $0 [options]

Options:
  --dry-run          Show what would be synced without actually syncing
  --push             Automatically push to remote (default: requires confirmation)
  --strategy STRAT   Auto-resolve conflicts: 'ours' (keep main), 'theirs' (keep branch), 'manual' (default)
  --help, -h         Show this help message

Target Branches:
  - staging    (Integration branch)
  - dev        (General development)
  - eip-monitor (EIP monitoring tool)
  - grafana    (Grafana dashboards)
  - monitoring (COO monitoring infrastructure)

Workflow:
  1. Fetch all branches
  2. Update main from remote
  3. Merge main into each target branch in order
  4. Resolve conflicts (if any) - can auto-resolve with --strategy
  5. Push to remote (optional)

Merge Strategy:
  Regular merges are used for better conflict resolution.
  Use --strategy to auto-resolve conflicts:
    - 'ours': Keep main's version for all conflicts
    - 'theirs': Keep target branch's version for all conflicts
    - 'manual': Resolve conflicts manually (default)

Examples:
  $0                              # Interactive sync with confirmation
  $0 --dry-run                    # See what would be synced
  $0 --push                       # Auto-push after sync
  $0 --strategy ours              # Auto-resolve conflicts (keep main)
  $0 --strategy theirs            # Auto-resolve conflicts (keep branch)

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

# Merge main into a target branch
merge_main_into_branch() {
    local target_branch="$1"
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Syncing $target_branch with $SOURCE_BRANCH..."
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if branch exists
    if ! git rev-parse --verify "$target_branch" &>/dev/null; then
        log_warn "Branch $target_branch does not exist, skipping"
        return 0
    fi
    
    # Checkout target branch
    log_info "Switching to $target_branch branch..."
    git checkout "$target_branch" || {
        log_error "Failed to checkout $target_branch branch"
        return 1
    }
    
    # Update target branch from remote (use fetch + merge to avoid rebase)
    log_info "Updating $target_branch from remote..."
    git fetch origin "$target_branch" &>/dev/null || true
    if ! git merge-base --is-ancestor "origin/$target_branch" "$target_branch" 2>/dev/null; then
        git merge "origin/$target_branch" --no-ff &>/dev/null || true
    fi
    
    # Check if main is already merged
    if git merge-base --is-ancestor "$SOURCE_BRANCH" "$target_branch" 2>/dev/null; then
        log_info "$target_branch is already up to date with $SOURCE_BRANCH"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local commits=$(git rev-list --count "$target_branch..$SOURCE_BRANCH" 2>/dev/null || echo "0")
        log_info "  [DRY RUN] Would merge $commits commit(s) from $SOURCE_BRANCH"
        return 0
    fi
    
    # Merge main into target branch
    log_info "Merging $SOURCE_BRANCH into $target_branch..."
    if git merge "$SOURCE_BRANCH" --no-ff -m "Sync $target_branch with $SOURCE_BRANCH" 2>&1; then
        log_success "Successfully merged $SOURCE_BRANCH into $target_branch"
        return 0
    else
        local merge_status=$?
        log_error "Merge conflict with $target_branch"
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
                # Keep main's version for all conflicts
                echo "$conflicted_files" | while read -r file; do
                    if [[ -n "$file" ]]; then
                        log_info "  Keeping main version: $file"
                        git checkout --ours "$file" 2>/dev/null || true
                        git add "$file" 2>/dev/null || true
                    fi
                done
            elif [[ "$MERGE_STRATEGY" == "theirs" ]]; then
                # Keep target branch's version for all conflicts
                echo "$conflicted_files" | while read -r file; do
                    if [[ -n "$file" ]]; then
                        log_info "  Keeping $target_branch version: $file"
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
            log_info "1. Auto-resolve using main's version (ours):"
            log_info "   git checkout --ours <file>"
            log_info "   git add <file>"
            echo ""
            log_info "2. Auto-resolve using $target_branch's version (theirs):"
            log_info "   git checkout --theirs <file>"
            log_info "   git add <file>"
            echo ""
            log_info "3. Resolve all conflicts automatically:"
            log_info "   # Keep main's version for all:"
            log_info "   git checkout --ours . && git add . && git commit --no-edit"
            log_info "   # Or keep $target_branch's version for all:"
            log_info "   git checkout --theirs . && git add . && git commit --no-edit"
            echo ""
            log_info "4. Manual resolution:"
            log_info "   # Edit conflicted files, then:"
            log_info "   git add <resolved-files>"
            log_info "   git commit --no-edit"
            echo ""
            log_info "5. After resolving, run this script again to continue with remaining branches"
            echo ""
            return $merge_status
        fi
    fi
}

# Main sync process
perform_sync() {
    cd "$PROJECT_ROOT"
    
    # Ensure main is up to date
    log_info "Updating $SOURCE_BRANCH from remote..."
    git fetch origin "$SOURCE_BRANCH" || {
        log_warn "Could not fetch $SOURCE_BRANCH, continuing with local version"
    }
    if ! git merge-base --is-ancestor "origin/$SOURCE_BRANCH" "$SOURCE_BRANCH" 2>/dev/null; then
        log_info "Merging remote changes into $SOURCE_BRANCH..."
        git merge "origin/$SOURCE_BRANCH" --no-ff -m "Update $SOURCE_BRANCH from remote" || {
            log_warn "Could not merge remote $SOURCE_BRANCH, continuing with local version"
        }
    fi
    
    # Sync branches in order
    local sync_failed=false
    for branch in "${TARGET_BRANCHES[@]}"; do
        if ! merge_main_into_branch "$branch"; then
            sync_failed=true
            break
        fi
    done
    
    if [[ "$sync_failed" == "true" ]]; then
        log_error "Sync process incomplete. Please resolve conflicts and try again."
        exit 1
    fi
    
    log_success "All branches synced successfully"
}

# Push changes
push_changes() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would push all synced branches to remote"
        return 0
    fi
    
    log_info "Preparing to push synced branches to remote..."
    
    local branches_to_push=()
    for branch in "${TARGET_BRANCHES[@]}"; do
        if git rev-parse --verify "$branch" &>/dev/null; then
            local commits_ahead=$(git rev-list --count "origin/$branch..$branch" 2>/dev/null || echo "0")
            if [[ "$commits_ahead" -gt 0 ]]; then
                branches_to_push+=("$branch")
            fi
        fi
    done
    
    if [[ ${#branches_to_push[@]} -eq 0 ]]; then
        log_info "No branches need pushing"
        return 0
    fi
    
    log_info "Branches to push: ${branches_to_push[*]}"
    
    if [[ "$AUTO_PUSH" == "false" ]]; then
        echo ""
        read -p "Push all synced branches to remote? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Push cancelled"
            return 0
        fi
    fi
    
    for branch in "${branches_to_push[@]}"; do
        log_info "Pushing $branch to remote..."
        if git push origin "$branch"; then
            log_success "Pushed $branch"
        else
            log_error "Failed to push $branch"
        fi
    done
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --push)
                AUTO_PUSH=true
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
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Sync Main Branch to Other Branches"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    check_prerequisites
    fetch_branches
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN MODE - No changes will be made"
        echo ""
    fi
    
    perform_sync
    
    if [[ "$DRY_RUN" == "false" ]]; then
        push_changes
        
        echo ""
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_success "Sync from main completed!"
        log_success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo ""
        log_info "DRY RUN completed - no changes made"
        log_info "Run without --dry-run to perform the sync"
    fi
}

# Run main function
main "$@"

