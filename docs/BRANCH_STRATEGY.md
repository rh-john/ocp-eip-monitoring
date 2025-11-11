# Branch Strategy

This document describes the git branch strategy for the OpenShift EIP Monitoring project.

## Core Branches

### `main`
- **Purpose**: Production-ready releases only
- **Protection**: Should be protected (recommended)
- **Merges**: Only from `staging` branch
- **Releases**: Creates release tags automatically

### `staging`
- **Purpose**: Integration branch for testing before main
- **Merges**: From component branches (`eip-monitor`, `dev`, `monitoring`, `grafana`)
- **Automation**: Auto-bumps version, creates pre-release tags
- **Testing**: Integration tests run here

### `eip-monitor`
- **Purpose**: EIP monitoring tool development (src/ directory, k8s-manifests.yaml, deploy-eip.sh)
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready
- **Scope**: Core application code, deployment manifests, build scripts

### `dev`
- **Purpose**: General development and integration work
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready

### `monitoring`
- **Purpose**: Monitoring infrastructure (COO/UWM) development
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready

### `grafana`
- **Purpose**: Grafana dashboards and visualization development
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready

## Workflow

### Daily Development
1. Work directly on `eip-monitor`, `dev`, `monitoring`, or `grafana` branches
2. Commit and push as usual
3. No feature branches required (but optional for larger features)

### Integration
1. Merge component branch to `staging`
2. Automated version bump and pre-release tag creation
3. Review integration test results

### Release
1. Merge `staging` to `main`
2. Automated release tag creation
3. Container images pushed to quay.io

## Feature Branches (Optional)

For larger features or collaboration:
- Format: `feature/<component>/<description>`
- Examples:
  - `feature/eip-monitor/new-metric`
  - `feature/monitoring/coo-improvements`
  - `feature/grafana/new-dashboard`
- Merge to respective component branch when complete

## Branch Protection

Recommended GitHub branch protection rules:

### `main`
- Require pull request reviews
- Require status checks to pass
- Require branches to be up to date
- Do not allow force pushes

### `staging`
- Require status checks to pass
- Allow force pushes (for hotfixes if needed)

## Best Practices

1. **Keep branches in sync**: Regularly merge `main` into component branches
2. **Test before staging**: Ensure component works before merging to staging
3. **Review staging**: Check integration results before merging to main
4. **Use clear commits**: Meaningful commit messages help with release notes

