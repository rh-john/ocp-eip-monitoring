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
- **Purpose**: EIP monitoring tool development
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready
- **Scope**: `src/`, `k8s/deployment/k8s-manifests.yaml`, `scripts/deploy-eip.sh` (or `build-and-deploy.sh`)

### `dev`
- **Purpose**: Cross-cutting development work and shared infrastructure
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready
- **Scope**:
  - **E2E Tests**: `tests/e2e/` - Tests that verify integration of multiple components
  - **Test Scripts**: `scripts/test/` - Test scripts that work across components (`test-deployment.sh`, `test-monitoring-deployment.sh`, `test-dashboard-queries.sh`)
  - **Shared Library**: `scripts/lib/common.sh` - Shared functions used by deploy and test scripts
  - **Debug/Validation Scripts**: `scripts/debug/` - Debugging, validation, and troubleshooting scripts (not tracked by git)
  - **CI/CD**: `.github/workflows/` - GitHub Actions workflows
  - **Cross-Component Docs**: Documentation covering multiple components
  - **Integration Scripts**: Scripts that coordinate between components (e.g., `merge-to-staging.sh`, `create-release.sh`, `bump-version.sh`)
  - **Component Scripts (for testing)**: Component-specific deploy scripts may exist here for integration testing, but primary development happens in component branches

### `monitoring`
- **Purpose**: Monitoring infrastructure (COO/UWM) development
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready
- **Scope**: `k8s/monitoring/`, `scripts/deploy-monitoring.sh`

### `grafana`
- **Purpose**: Grafana dashboards and visualization development
- **Workflow**: Work directly on this branch
- **Merges**: To `staging` when ready
- **Scope**: `k8s/grafana/`, `scripts/deploy-grafana.sh`

## Workflow

### Daily Development
1. Work directly on component branches:
   - `eip-monitor` - Core application changes
   - `monitoring` - Monitoring infrastructure changes
   - `grafana` - Dashboard and visualization changes
   - `dev` - E2E tests, shared scripts, cross-cutting concerns
2. Commit and push as usual
3. No feature branches required (but optional for larger features)

### Integration
1. Merge component branch to `staging`
2. Automated version bump and pre-release tag creation
3. Review integration test results
4. **Note**: `staging` is NOT for active development - only merges and testing

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

## What Goes Where?

### Component Branches (Specific Work)
- **`eip-monitor`**: `src/`, `k8s/deployment/k8s-manifests.yaml`, `scripts/deploy-eip.sh` (or `build-and-deploy.sh`)
- **`monitoring`**: `k8s/monitoring/`, `scripts/deploy-monitoring.sh`
- **`grafana`**: `k8s/grafana/`, `scripts/deploy-grafana.sh`

### `dev` Branch (Cross-Cutting Work)
- **E2E Tests**: `tests/e2e/` - Tests that verify integration of multiple components
- **Test Scripts**: `scripts/test/` - Test scripts that work across components
- **Shared Library**: `scripts/lib/common.sh` - Functions used by multiple deploy/test scripts
- **Debug Scripts**: `scripts/debug/` - Debugging and troubleshooting scripts (not tracked by git)
- **CI/CD**: `.github/workflows/` - GitHub Actions workflows
- **Cross-Component Docs**: Documentation covering multiple components
- **Integration Scripts**: Scripts that coordinate between components (e.g., `merge-to-staging.sh`)

### `staging` Branch (Integration Only)
- **NOT for active development**
- **Only merges** from component branches
- **Integration testing** happens here
- **Pre-release validation** before merging to `main`

## Best Practices

1. **Keep branches in sync**: Regularly merge `main` into component branches
2. **Test before staging**: Ensure component works before merging to staging
3. **Review staging**: Check integration results before merging to main
4. **Use clear commits**: Meaningful commit messages help with release notes
5. **Don't develop in staging**: `staging` is for integration, not active development
6. **E2E tests in dev**: Integration tests belong in `dev` branch, not `staging`

