# Test Scripts

This directory contains test scripts that are **tracked by git** and may be called by other scripts.

## Available Scripts

- **`test-deployment.sh`**: Deployment validation and health check
  - Called by `scripts/merge-to-staging.sh` during merge operations
  - Validates deployment health and configuration
  
- **`test-dashboard-queries.sh`**: Test dashboard Prometheus queries
  - Validates that dashboard queries work correctly against Prometheus
  - Can be run manually or integrated into CI/CD pipelines

## Usage

```bash
# Test deployment
./scripts/test/test-deployment.sh

# Test dashboard queries
./scripts/test/test-dashboard-queries.sh
```

## Note

These scripts are **tracked by git** because they are dependencies of other tracked scripts. Unlike scripts in `scripts/debug/`, these are part of the standard workflow and should be available to all developers.

