#!/bin/bash
#
# Version Bumping Script
# Automatically bumps version based on merge type
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source common functions (logging)
source "${PROJECT_ROOT}/scripts/lib/common.sh"

# Note: Logging functions (log_info, log_success, log_warn, log_error) are sourced from scripts/lib/common.sh

VERSION_FILE="${PROJECT_ROOT}/.version"

# Read current version
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "0.1.0" > "$VERSION_FILE"
fi

current_version=$(cat "$VERSION_FILE" | tr -d '[:space:]')

# Parse version components
IFS='.' read -r major minor patch <<< "$current_version"

# Determine bump type from commit messages or environment
BUMP_TYPE="${BUMP_TYPE:-patch}"

# Bump version
case "$BUMP_TYPE" in
    major)
        major=$((major + 1))
        minor=0
        patch=0
        ;;
    minor)
        minor=$((minor + 1))
        patch=0
        ;;
    patch)
        patch=$((patch + 1))
        ;;
    *)
        log_error "Invalid bump type: $BUMP_TYPE. Use: major, minor, or patch"
        exit 1
        ;;
esac

new_version="${major}.${minor}.${patch}"

# Write new version
echo "$new_version" > "$VERSION_FILE"

log_success "Version bumped to $new_version"
echo "$new_version"

