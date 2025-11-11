#!/bin/bash
#
# Release Creation Script
# Creates git tag and GitHub release
#

set -euo pipefail

VERSION_FILE=".version"

if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Error: .version file not found"
    exit 1
fi

version=$(cat "$VERSION_FILE" | tr -d '[:space:]')
tag="v${version}"

# Check if tag already exists
if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "Tag $tag already exists"
    exit 1
fi

# Create git tag
git tag -a "$tag" -m "Release $tag"

# Push tag
git push origin "$tag"

echo "Created and pushed tag: $tag"
echo "Version: $version"

