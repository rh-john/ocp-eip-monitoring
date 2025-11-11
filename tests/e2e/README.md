# E2E Tests for Monitoring Deployment

This directory contains end-to-end (E2E) tests for the monitoring infrastructure.

## Overview

E2E tests verify the complete lifecycle of monitoring deployment:
1. **Deployment**: Deploy monitoring infrastructure (COO/UWM)
2. **Verification**: Verify all resources are created and operational
3. **Metrics Collection**: Verify metrics are being scraped
4. **Cleanup**: Remove resources (optional)

## Test Scripts

### `test-monitoring-e2e.sh`

Comprehensive E2E test that:
- Deploys monitoring infrastructure using `deploy-monitoring.sh`
- Waits for resources to become ready using shared `common.sh` functions
- Verifies all components (ServiceMonitors, PrometheusRules, NetworkPolicies, etc.)
- Checks that metrics are being scraped (uses `find_query_pod()` from `common.sh`)
- Optionally cleans up resources after test

**Uses shared library:** `scripts/lib/common.sh` for pod finding, logging, and resource waiting.

### `test-uwm-grafana-e2e.sh`

E2E test specifically for UWM monitoring with Grafana dashboards:
- Deploys UWM monitoring infrastructure using `deploy-monitoring.sh`
- Deploys Grafana operator and instance using `deploy-grafana.sh`
- Configures Grafana DataSource for UWM Prometheus
- Installs and verifies Grafana dashboards
- Verifies metrics are accessible through Grafana
- Optionally cleans up resources after test

**Uses shared library:** `scripts/lib/common.sh` for pod finding, logging, and resource waiting.

## Usage

### Basic Usage

```bash
# Test COO monitoring
./tests/e2e/test-monitoring-e2e.sh

# Test UWM monitoring
MONITORING_TYPE=uwm ./tests/e2e/test-monitoring-e2e.sh

# Test both COO and UWM
MONITORING_TYPE=all ./tests/e2e/test-monitoring-e2e.sh

# Test UWM with Grafana dashboards
./tests/e2e/test-uwm-grafana-e2e.sh
```

### With Custom Namespace

```bash
NAMESPACE=my-namespace ./tests/e2e/test-monitoring-e2e.sh
```

### Keep Resources After Test

```bash
CLEANUP=false ./tests/e2e/test-monitoring-e2e.sh
```

### Custom Timeout

```bash
TIMEOUT=600 ./tests/e2e/test-monitoring-e2e.sh  # 10 minutes
```

## Environment Variables

- `NAMESPACE`: Kubernetes namespace (default: `eip-monitoring`)
- `MONITORING_TYPE`: Type of monitoring to test (`coo`, `uwm`, or `all`) (default: `coo`)
- `CLEANUP`: Whether to clean up resources after test (`true` or `false`) (default: `true`)
- `TIMEOUT`: Timeout in seconds for resource readiness (default: `300`)

## Test Flow

### COO Monitoring Test

1. **Deploy COO monitoring** using `deploy-monitoring.sh`
2. **Wait for MonitoringStack** to be ready
3. **Wait for Prometheus pods** to be running
4. **Verify ServiceMonitor** exists
5. **Verify PrometheusRule** exists
6. **Verify NetworkPolicy** (combined) exists
7. **Verify ThanosQuerier** and its pods
8. **Verify AlertmanagerConfig** exists
9. **Verify metrics** are being scraped (query Prometheus API)
10. **Run comprehensive test** using `test-monitoring-deployment.sh`

### UWM with Grafana Test Flow

1. **Deploy UWM monitoring** using `deploy-monitoring.sh`
2. **Wait for UWM Prometheus pods** to be running
3. **Verify ServiceMonitor** exists
4. **Verify PrometheusRule** exists
5. **Verify NetworkPolicy** (combined) exists
6. **Verify namespace label** for UWM discovery
7. **Verify metrics** are being scraped (query Prometheus API)
8. **Deploy Grafana** using `deploy-grafana.sh` with UWM datasource
9. **Wait for Grafana Operator** CSV to be ready
10. **Wait for Grafana instance pod** to be running
11. **Verify Grafana instance** exists
12. **Verify Grafana DataSource** (prometheus-uwm) exists and is ready
13. **Verify Grafana RBAC** (ClusterRoleBinding) exists
14. **Verify Grafana dashboards** are deployed
15. **Verify dashboard status** (ready/initializing)
16. **Verify Grafana API** is accessible
17. **Print access information** (Grafana route URL)

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: E2E Monitoring Tests

on:
  pull_request:
    paths:
      - 'scripts/deploy-monitoring.sh'
      - 'k8s/monitoring/**'
      - 'tests/e2e/**'

jobs:
  test-coo:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup OpenShift CLI
        run: |
          # Install oc CLI
      - name: Login to OpenShift
        run: |
          oc login --token=${{ secrets.OCP_TOKEN }} --server=${{ secrets.OCP_SERVER }}
      - name: Run COO E2E Test
        run: |
          MONITORING_TYPE=coo ./tests/e2e/test-monitoring-e2e.sh
      - name: Run UWM E2E Test
        run: |
          MONITORING_TYPE=uwm ./tests/e2e/test-monitoring-e2e.sh
```

### Tekton Pipeline Example

```yaml
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: monitoring-e2e-test
spec:
  params:
    - name: monitoring-type
      description: Type of monitoring to test
      default: coo
  tasks:
    - name: test-monitoring
      taskRef:
        name: bash
      params:
        - name: script
          value: |
            ./tests/e2e/test-monitoring-e2e.sh
      env:
        - name: MONITORING_TYPE
          value: $(params.monitoring-type)
```

## Expected Test Results

### Success Criteria

- All resources are created successfully
- Prometheus pods are running
- ServiceMonitors and PrometheusRules exist
- NetworkPolicy is applied
- Metrics are being scraped (at least some `eip_*` metrics exist)
- Comprehensive test script passes

### Common Issues

1. **Timeout waiting for resources**: Increase `TIMEOUT` environment variable
2. **Metrics not found**: Wait longer or check ServiceMonitor configuration
3. **NetworkPolicy missing**: Ensure combined NetworkPolicy is applied
4. **Namespace label incorrect**: Check UWM namespace labeling

## Debugging

### Verbose Output

The test script uses the underlying `deploy-monitoring.sh` and `test-monitoring-deployment.sh` scripts. To get verbose output:

```bash
# Enable verbose mode in deploy script
VERBOSE=true MONITORING_TYPE=coo ./tests/e2e/test-monitoring-e2e.sh
```

### Manual Verification

If tests fail, you can manually verify:

```bash
# Check monitoring deployment
./scripts/test-monitoring-deployment.sh --monitoring-type coo

# Check specific resources
oc get servicemonitor,prometheusrule,networkpolicy -n eip-monitoring

# Check Prometheus pods (using common.sh functions)
source scripts/lib/common.sh
PROM_POD=$(find_prometheus_pod eip-monitoring true)
if [[ -n "$PROM_POD" ]]; then
    oc exec -n eip-monitoring $PROM_POD -- wget -qO- 'http://localhost:9090/api/v1/query?query=count({__name__=~"eip_.*"})'
fi

# Or use find_query_pod() for automatic pod selection (ThanosQuerier or Prometheus)
QUERY_RESULT=$(find_query_pod eip-monitoring true)
if [[ -n "$QUERY_RESULT" ]]; then
    QUERY_POD=$(echo "$QUERY_RESULT" | cut -d'|' -f1)
    QUERY_PORT=$(echo "$QUERY_RESULT" | cut -d'|' -f2)
    oc exec -n eip-monitoring $QUERY_POD -- wget -qO- "http://localhost:${QUERY_PORT}/api/v1/query?query=count({__name__=~\"eip_.*\"})"
fi
```

## Best Practices

1. **Run tests in isolated namespaces** to avoid conflicts
2. **Use CLEANUP=true** in CI/CD to avoid resource leaks
3. **Set appropriate timeouts** based on cluster performance
4. **Run tests sequentially** for COO and UWM if testing both
5. **Check test logs** for detailed failure information

