# Release Process

This document describes the release process for the OpenShift EIP Monitoring project.

## Overview

The project uses a simple 3-step release process with automated versioning and tagging.

## Release Workflow

### Step 1: Development
Work directly on component branches (`dev`, `monitoring`, `grafana`):
- Commit and push as usual
- No special process required
- Work independently on each component

### Step 2: Integration
Merge component branches to `staging` when ready:
```bash
git checkout staging
git merge dev    # or monitoring, or grafana
git push origin staging
```

**What happens automatically:**
- Version is auto-bumped (patch increment by default)
- Pre-release tag is created (`v<version>-rc<number>`)
- Container image is built and pushed to quay.io
- Integration tests run (if configured)

### Step 3: Release
Merge `staging` to `main` when validated:
```bash
git checkout main
git merge staging
git push origin main
```

**What happens automatically:**
- Release tag is created (`v<version>`)
- Container image is built and pushed with version tag
- `latest` tag is updated
- GitHub release is created with release notes

## Version Bumping

Versions are automatically bumped based on commit messages:

- **Patch** (x.x.1): Default for all merges
- **Minor** (x.1.0): If commit message contains "feat" or "feature"
- **Major** (1.0.0): If commit message contains "breaking" or "major"

Version is stored in `.version` file at repository root.

## Container Image Tags

### Release Tags
- `v<version>`: Production release (e.g., `v1.2.3`)
- `latest`: Points to most recent release
- `sha-<commit-sha>`: Traceability tag

### Pre-release Tags
- `v<version>-rc<number>`: Pre-release for testing (e.g., `v1.2.3-rc1`)

### Nightly Build Tags
- `<branch>-<date>`: Nightly builds (e.g., `dev-20241107`)
- `sha-<commit-sha>`: Commit SHA tag

## Manual Release (if needed)

If you need to manually create a release:

```bash
# Bump version manually
BUMP_TYPE=minor ./scripts/bump-version.sh

# Create release tag
./scripts/create-release.sh
```

## Best Practices

1. **Test before staging**: Ensure component works before merging to staging
2. **Validate staging**: Review staging integration results before merging to main
3. **Use meaningful commits**: Commit messages help with release notes
4. **Tag major changes**: Use "breaking" or "major" in commit messages for major version bumps

