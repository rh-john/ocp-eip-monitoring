# E2E Test Deployment Analysis

## Current State

### How E2E Tests Deploy Resources

1. **test-monitoring-e2e.sh**:
   - Calls `deploy-monitoring.sh --monitoring-type coo/uwm` ✅ (correct)
   - Then manually waits for resources using custom `wait_for_resource()` and `wait_for_pods()` functions
   - Manually verifies resources exist (ServiceMonitor, PrometheusRule, etc.)

2. **test-uwm-grafana-e2e.sh**:
   - Calls `deploy-monitoring.sh --monitoring-type uwm` ✅ (correct)
   - Calls `deploy-grafana.sh --monitoring-type uwm` ✅ (correct)
   - Then manually waits for resources using custom `wait_for_resource()` and `wait_for_pods()` functions
   - Manually verifies resources exist

### Duplication Issues

1. **Wait Functions**: Both e2e tests have their own `wait_for_resource()` and `wait_for_pods()` functions that duplicate logic already in deploy scripts
2. **Verification Logic**: E2e tests manually verify resources that deploy scripts already handle internally
3. **Logging Functions**: E2e tests define their own logging functions instead of reusing from deploy scripts

### Functions Available in Deploy Scripts

**deploy-monitoring.sh**:
- `log_info()`, `log_success()`, `log_warn()`, `log_error()` - Logging functions
- `verify_thanosquerier_stores()` - Verifies ThanosQuerier store discovery
- `verify_federation()` - Verifies Prometheus federation
- `configure_coo_monitoring_stack()` - Configures and waits for COO monitoring stack
- `install_coo_operator()` - Installs COO operator with wait logic
- Embedded wait logic in various functions (Prometheus pods, operator CSV, etc.)

**deploy-grafana.sh**:
- `log_info()`, `log_success()`, `log_warn()`, `log_error()` - Logging functions
- `deploy_grafana()` - Deploys Grafana with wait logic
- Embedded wait logic for Grafana operator and pods

## Recommended Solution

### Option 1: Create Shared Library (Recommended)

Create `scripts/lib/common.sh` with reusable functions:
- `wait_for_resource()` - Generic resource wait function
- `wait_for_pods()` - Generic pod wait function
- `log_info()`, `log_success()`, `log_warn()`, `log_error()` - Logging functions
- `check_prerequisites()` - Prerequisite checks

Then:
1. Source `lib/common.sh` in deploy scripts
2. Source `lib/common.sh` in e2e tests
3. Remove duplicate functions from e2e tests

### Option 2: Source Functions from Deploy Scripts

Extract reusable functions from deploy scripts into a separate file that can be sourced:
- Create `scripts/lib/deploy-functions.sh` with exported functions
- Source it in deploy scripts
- Source it in e2e tests

### Option 3: Keep Current Approach but Reduce Duplication

Keep e2e tests calling deploy scripts, but:
- Extract common wait/verification functions to a shared file
- Have e2e tests source the shared file
- Deploy scripts continue to work independently

## Implementation Plan

1. ✅ Analyze current deployment approach
2. Create `scripts/lib/common.sh` with shared functions
3. Refactor deploy scripts to source and use shared functions
4. Refactor e2e tests to source and use shared functions
5. Remove duplicate code from e2e tests
6. Test that both deploy scripts and e2e tests still work correctly

