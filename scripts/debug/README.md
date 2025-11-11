# Debug Scripts

This directory contains debugging, troubleshooting, fix, validation, and test scripts that are **not tracked by git**.

These scripts are for:
- **Troubleshooting**: Diagnosing issues with metrics collection, Prometheus discovery, etc.
- **Fixing**: One-off fixes for dashboard issues, service labels, etc.
- **Verification**: Verifying metrics are being scraped correctly
- **Validation**: Validating dashboard configurations and queries
- **Testing**: Testing dashboard queries and deployment health
- **Utilities**: Helper scripts for Perses dashboard management

## Available Scripts

### Verification Scripts

- **`verify-prometheus-metrics.sh`**: Verify Prometheus metrics ingestion
- **`verify-uwm-metrics.sh`**: Diagnose UWM metrics collection issues

### Fix Scripts

- **`fix-prometheus-discovery.sh`**: Fix Prometheus ServiceMonitor discovery issues
- **`fix-service-labels.sh`**: Fix service label issues
- **`fix-image-pull-error.sh`**: Fix container image pull errors
- **`fix-all-dashboards.py`**: Fix dashboard configuration issues
- **`fix-all-dashboards-safe.py`**: Safe version of dashboard fix script
- **`fix-table-panels.py`**: Fix table panel configuration

### Diagnostic Scripts

- **`diagnose-uwm-metrics.sh`**: Comprehensive UWM metrics diagnosis

### Validation Scripts

- **`validate-all-dashboards.sh`**: Validate all Grafana dashboards
- **`validate-dashboard-queries.sh`**: Validate dashboard Prometheus queries
- **`validate-dashboard-thorough.sh`**: Thorough dashboard validation
- **`validate-grafana-dashboards.sh`**: Validate Grafana dashboard configurations

### Test Scripts

- **`test-dashboard-queries.sh`**: Test dashboard queries against Prometheus (moved to `scripts/test/`)

**Note:** Test scripts that are called by other tracked scripts have been moved to `scripts/test/` to ensure they're available as dependencies.

### Utility Scripts

- **`add-perses-inspect-links.sh`**: Add inspect links to Perses dashboards
- **`add-perses-inspect-links.py`**: Python version of Perses inspect links script

## Usage

These scripts are typically run manually when troubleshooting issues:

```bash
# Verify metrics are being scraped
./scripts/debug/verify-prometheus-metrics.sh

# Diagnose UWM metrics issues
./scripts/debug/diagnose-uwm-metrics.sh

# Fix Prometheus discovery
./scripts/debug/fix-prometheus-discovery.sh

# Validate dashboards
./scripts/debug/validate-all-dashboards.sh

# Test deployment
./scripts/test/test-deployment.sh

# Test dashboard queries
./scripts/test/test-dashboard-queries.sh

# Add Perses inspect links
./scripts/debug/add-perses-inspect-links.sh
```

## Note

This directory is **not tracked by git** (see `.gitignore`). Scripts here are:
- **Local development tools**: Not part of the main codebase
- **Temporary fixes**: May be removed or modified without affecting the repository
- **Personal utilities**: Can be customized per developer

If you need to share a debug script with the team, consider:
1. Moving it to the main `scripts/` directory if it's generally useful
2. Documenting it in the main `scripts/README.md`
3. Adding it to version control if it's part of the standard workflow

