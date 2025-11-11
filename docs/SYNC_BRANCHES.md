# Syncing Directory Structure Across Branches

This guide explains how to sync the new directory structure (`scripts/test/`, `scripts/debug/`) across all branches.

## Current Status

The reorganization happened in these commits (in staging):
1. `3ba5087` - Move validate, test, and add-perses scripts to debug folder
2. `e2f01a4` - Move test scripts from debug/ to scripts/test/
3. `34a1983` - Move test scripts from debug/ to scripts/test/ (tracked)
4. `87ccba7` - Move test-monitoring-deployment.sh to scripts/test/
5. `cfce4eb` - Fix broken references after moving scripts
6. `65fe9f9` - Optimize test scripts to use common.sh functions

## Method 1: Merge staging into each branch (Recommended)

This is the simplest approach - merge staging into each component branch:

```bash
# For each component branch
for branch in eip-monitor dev monitoring grafana; do
    echo "=== Syncing $branch ==="
    git checkout $branch
    git merge staging
    # Resolve any conflicts if needed
    git push origin $branch
done

git checkout staging
```

**Pros:**
- Simple and straightforward
- Gets all changes, not just reorganization
- Maintains branch history

**Cons:**
- May bring in unrelated changes
- May have conflicts to resolve

## Method 2: Cherry-pick specific commits

If you only want the reorganization commits:

```bash
# Identify the commits
REORG_COMMITS=(
    "3ba5087"  # Move to debug folder
    "e2f01a4"  # Move test scripts
    "34a1983"  # Move test scripts (tracked)
    "87ccba7"  # Move test-monitoring-deployment.sh
    "cfce4eb"  # Fix references
    "65fe9f9"  # Optimize test scripts
)

# For each branch
for branch in eip-monitor dev monitoring grafana; do
    git checkout $branch
    for commit in "${REORG_COMMITS[@]}"; do
        git cherry-pick $commit || echo "Commit $commit may already be applied"
    done
    git push origin $branch
done
```

**Pros:**
- Only brings reorganization changes
- More selective

**Cons:**
- More complex
- May miss dependencies
- Cherry-pick conflicts can be tricky

## Method 3: Manual file operations

If merges cause too many conflicts, manually recreate the structure:

```bash
# For each branch
for branch in eip-monitor dev monitoring grafana; do
    git checkout $branch
    
    # Create directories
    mkdir -p scripts/test scripts/debug
    
    # Move files (adjust paths as needed)
    # This requires knowing which files moved where
    
    git add scripts/test scripts/debug
    git commit -m "Sync directory structure: add scripts/test/ and scripts/debug/"
    
    git push origin $branch
done
```

**Pros:**
- Full control
- No merge conflicts

**Cons:**
- Time-consuming
- Easy to miss files
- Doesn't preserve history

## Recommended Approach

**Use Method 1 (merge staging)** because:
1. It's the simplest
2. It ensures all branches stay in sync
3. It preserves full history
4. Any conflicts are usually easy to resolve

## Conflict Resolution

If you encounter conflicts during merge:

1. **File location conflicts**: Usually just need to accept the new location
2. **Reference conflicts**: Update paths to new locations
3. **Content conflicts**: Resolve based on which branch has the correct content

## Verification

After syncing, verify each branch has the new structure:

```bash
for branch in eip-monitor dev monitoring grafana staging; do
    echo "=== $branch ==="
    git checkout $branch
    ls -d scripts/test scripts/debug 2>/dev/null || echo "  Missing directories"
    echo ""
done
```

## Quick Sync Script

```bash
#!/bin/bash
# Quick sync script

STAGING="staging"
BRANCHES=("eip-monitor" "dev" "monitoring" "grafana")

for branch in "${BRANCHES[@]}"; do
    echo "Syncing $branch..."
    git checkout $branch
    git merge $STAGING --no-edit || {
        echo "⚠ Conflicts in $branch - resolve manually"
        continue
    }
    echo "✓ $branch synced"
done

git checkout $STAGING
echo "Done!"
```

