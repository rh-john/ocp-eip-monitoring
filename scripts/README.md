# Scripts Library

This directory contains operational scripts for deploying, testing, and managing the EIP monitoring solution.

## Shared Library

### `lib/common.sh`

A shared library providing reusable functions for all scripts:

#### Pod Finding Functions
- **`find_thanosquerier_pod(namespace)`**: Find ThanosQuerier pod using multiple selector strategies (COO-specific, standard, name pattern)
- **`find_prometheus_pod(namespace, prefer_coo)`**: Find Prometheus pod with optional COO preference
- **`find_query_pod(namespace, prefer_thanos)`**: Composite function that finds ThanosQuerier or Prometheus pod for metrics queries, returns `"pod_name|port"`

#### Logging Functions
- **`log_info(message)`**: Info-level logging
- **`log_success(message)`**: Success logging
- **`log_warn(message)`**: Warning logging
- **`log_error(message)`**: Error logging

#### Utility Functions
- **`check_prerequisites()`**: Check for required tools (`oc`, `jq`) and cluster connectivity
- **`wait_for_resource(type, name, namespace, timeout)`**: Wait for Kubernetes resource to be ready
- **`wait_for_pods(selector, namespace, expected_count, timeout)`**: Wait for pods matching selector to be running
- **`oc_cmd(...)`**: Run `oc` command with optional verbose output suppression
- **`oc_cmd_silent(...)`**: Run `oc` command with full output suppression in non-verbose mode

**Usage:**
```bash
# Source the library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/scripts/lib/common.sh"

# Use functions
if ! check_prerequisites; then
    exit 1
fi

PROM_POD=$(find_prometheus_pod "$NAMESPACE" "true")
QUERY_RESULT=$(find_query_pod "$NAMESPACE" "true")
```

## Deployment Scripts

### `deploy-monitoring.sh`

Deploy monitoring infrastructure (COO or UWM).

**Usage:**
```bash
# Deploy COO monitoring
./scripts/deploy-monitoring.sh --monitoring-type coo

# Deploy UWM monitoring
./scripts/deploy-monitoring.sh --monitoring-type uwm

# Deploy both
./scripts/deploy-monitoring.sh --monitoring-type all

# Remove monitoring
./scripts/deploy-monitoring.sh --remove-monitoring coo
```

**Features:**
- Deploys MonitoringStack (COO) or configures UWM
- Creates ServiceMonitors and PrometheusRules
- Applies NetworkPolicy for Prometheus access
- Sets up RBAC and federation tokens (if needed)
- Waits for ThanosQuerier/Prometheus pods to be ready
- Verifies store discovery (ThanosQuerier)

**Uses:** `scripts/lib/common.sh` for pod finding, logging, and prerequisites.

### `deploy-grafana.sh`

Deploy Grafana operator, instance, and dashboards.

**Usage:**
```bash
# Deploy Grafana for COO
./scripts/deploy-grafana.sh --monitoring-type coo

# Deploy Grafana for UWM
./scripts/deploy-grafana.sh --monitoring-type uwm

# Remove Grafana
./scripts/deploy-grafana.sh --all
```

**Features:**
- Deploys Grafana Operator
- Creates Grafana instance
- Configures DataSource (COO or UWM Prometheus)
- Installs Grafana dashboards
- Cleans up CRDs on removal

## Testing Scripts

### `test/test-monitoring-deployment.sh`

Monitoring deployment verification.

**Usage:**
```bash
# Test COO deployment
./scripts/test/test-monitoring-deployment.sh --monitoring-type coo

# Test UWM deployment
./scripts/test/test-monitoring-deployment.sh --monitoring-type uwm

# Test both
./scripts/test/test-monitoring-deployment.sh --monitoring-type all
```

**Features:**
- Verifies MonitoringStack (COO) or UWM configuration
- Checks Prometheus/ThanosQuerier pods
- Verifies ServiceMonitors and PrometheusRules
- Checks Prometheus targets API
- Verifies metrics are being scraped
- Validates ServiceMonitor discovery

**Uses:** `scripts/lib/common.sh` for pod finding and query pod selection.

### `verify-prometheus-metrics.sh`

Verify Prometheus metrics ingestion.

**Usage:**
```bash
./scripts/debug/verify-prometheus-metrics.sh
```

**Features:**
- Finds Prometheus pod automatically
- Queries Prometheus API for `eip_*` metrics
- Validates metric presence and values

### `verify-uwm-metrics.sh`

Diagnose UWM metrics collection issues.

**Usage:**
```bash
./scripts/debug/verify-uwm-metrics.sh
```

**Features:**
- Checks UWM Prometheus pod
- Verifies ServiceMonitor configuration
- Tests metrics scraping
- Provides troubleshooting information

## E2E Test Scripts

See [tests/e2e/README.md](../tests/e2e/README.md) for detailed documentation.

- **`tests/e2e/test-monitoring-e2e.sh`**: End-to-end monitoring tests
- **`tests/e2e/test-uwm-grafana-e2e.sh`**: End-to-end Grafana deployment tests

Both use `scripts/lib/common.sh` for shared functionality.

## Code Organization

### Refactoring

The scripts have been refactored to use a shared library (`scripts/lib/common.sh`) to:
- **Reduce duplication**: ~120 lines of duplicate code eliminated
- **Improve consistency**: All scripts use same pod detection logic
- **Enhance maintainability**: Single source of truth for common functions
- **Better error handling**: Consistent error handling across scripts

**Migration Status:**
- Phase 1: Functions added to `common.sh`
- Phase 2: High-priority scripts migrated (`deploy-monitoring.sh`, test scripts)
- Phase 3: Medium-priority scripts (verification scripts) - Optional

See `scripts/lib/REFACTORING_EFFECTS_ANALYSIS.md` for detailed analysis.

## Best Practices

1. **Always source `common.sh`** at the beginning of scripts:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
   source "${PROJECT_ROOT}/scripts/lib/common.sh"
   ```

2. **Use shared functions** instead of duplicating pod-finding logic:
   ```bash
   # Good: Use shared function
   PROM_POD=$(find_prometheus_pod "$NAMESPACE" "true")
   
   # Bad: Duplicate selector logic
   PROM_POD=$(oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus ...)
   ```

3. **Handle prerequisites** using shared function:
   ```bash
   if ! check_prerequisites; then
       exit 1
   fi
   ```

4. **Use consistent logging** with shared functions:
   ```bash
   log_info "Starting deployment..."
   log_success "Deployment complete"
   log_warn "Non-critical issue detected"
   log_error "Deployment failed"
   ```

## Contributing

When adding new scripts:

1. **Source `common.sh`** at the beginning
2. **Use shared functions** for pod finding, logging, prerequisites
3. **Follow existing patterns** for consistency
4. **Document script usage** in comments
5. **Test thoroughly** before committing

## Related Documentation

- [E2E Tests](../tests/e2e/README.md) - End-to-end testing guide
- [Grafana Dashboards](../k8s/grafana/README.md) - Dashboard documentation
- [Refactoring Analysis](lib/REFACTORING_EFFECTS_ANALYSIS.md) - Detailed refactoring analysis

