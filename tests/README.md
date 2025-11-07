# EIP Monitoring Test Suite

This directory contains end-to-end tests for the EIP monitoring solution.

## Overview

The test suite includes:
- **test-monitoring-deployment.sh**: Tests monitoring infrastructure (COO/UWM) - does NOT require eip-monitor
- **test-eip-monitoring.sh**: Tests eip-monitor integration with monitoring - requires eip-monitor deployment
- **helpers.sh**: Common test helper functions
- **config.sh**: Test configuration that loads `~/aro-current-config.env`

## Prerequisites

1. OpenShift CLI (`oc`) installed and configured
2. Connected to an OpenShift cluster (`oc login`)
3. (Optional) `~/aro-current-config.env` file with test environment variables

## Test Environment Configuration

The tests use `~/aro-current-config.env` to load test environment variables **in-flight only** (at runtime). No variables are persisted or committed to the repository.

### Setting up `~/aro-current-config.env`

Create `~/aro-current-config.env` with variables needed for your test environment:

```bash
# Example ~/aro-current-config.env
# OpenShift cluster connection (if needed)
# OPENSHIFT_API_SERVER=https://api.example.com:6443
# OPENSHIFT_USERNAME=admin
# OPENSHIFT_TOKEN=your-token-here

# Test configuration
TEST_NAMESPACE=eip-monitoring
TEST_TIMEOUT=300

# Skip specific tests (optional)
# TEST_SKIP_UWM=false
# TEST_SKIP_COO=false
# TEST_SKIP_GRAFANA=false
```

**Important Security Note**: 
- The file path `~/aro-current-config.env` is only referenced in source commands within test scripts
- No variable values are hardcoded, stored, or committed to the repository
- No paths, credentials, or sensitive values are persisted in version control
- The config file is only read at runtime during test script execution

## Running Tests

### Test Monitoring Infrastructure

Tests monitoring deployment (COO or UWM) without requiring eip-monitor:

```bash
# Test UWM deployment
./scripts/test-monitoring-deployment.sh

# Test with custom namespace
TEST_NAMESPACE=my-namespace ./scripts/test-monitoring-deployment.sh

# Skip specific tests
TEST_SKIP_COO=true ./scripts/test-monitoring-deployment.sh
```

### Test EIP Monitor Integration

Tests eip-monitor deployment and integration with monitoring (requires eip-monitor to be deployed):

```bash
# Test eip-monitor integration
./scripts/test-eip-monitoring.sh

# Test with custom namespace
TEST_NAMESPACE=my-namespace ./scripts/test-eip-monitoring.sh
```

## Test Scenarios

### Monitoring Infrastructure Tests (test-monitoring-deployment.sh)

**UWM Tests:**
- Verify UWM is enabled in cluster-monitoring-config
- Verify user-workload-monitoring-config exists
- Verify openshift-user-workload-monitoring namespace exists
- Verify Prometheus pods are running
- Verify ServiceMonitor is created
- Verify PrometheusRule is applied

**COO Tests:**
- Verify COO operator is installed
- Verify MonitoringStack CR is created
- Verify Prometheus pods are running (COO-managed)
- Verify ServiceMonitor is created
- Verify PrometheusRule is applied

**Grafana Tests:**
- Verify Grafana operator is installed
- Verify Grafana instance is running
- Verify Grafana datasource is configured
- Verify Grafana dashboards are deployed
- Verify Grafana route is accessible

### EIP Monitor Integration Tests (test-eip-monitoring.sh)

**Deployment Tests:**
- Verify eip-monitor pod is running
- Verify Service exists and has endpoints
- Verify metrics endpoint is accessible
- Verify required metrics are present

**Integration Tests:**
- Verify metrics are scraped by Prometheus (UWM or COO)
- Verify metrics appear in Grafana datasource

**Accuracy Tests:**
- Verify metric values are numeric
- Verify metric labels are correct
- Verify metric timestamps are current

## Test Helper Functions

The `helpers.sh` file provides common functions:

- `wait_for_resource()`: Wait for a Kubernetes resource to be ready
- `verify_pod_running()`: Verify a pod is in Running state
- `verify_metrics_available()`: Query Prometheus for metrics
- `verify_grafana_accessible()`: Test Grafana route access
- `cleanup_test_resources()`: Clean up test resources
- `run_test()`: Run a test and track results

## Environment Variables

### Test Configuration Variables

- `TEST_NAMESPACE`: Kubernetes namespace for tests (default: `eip-monitoring`)
- `TEST_TIMEOUT`: Timeout for resource waits in seconds (default: `300`)
- `TEST_SKIP_UWM`: Skip UWM tests (default: `false`)
- `TEST_SKIP_COO`: Skip COO tests (default: `false`)
- `TEST_SKIP_GRAFANA`: Skip Grafana tests (default: `false`)

### Variables from ~/aro-current-config.env

These should be set in your `~/aro-current-config.env` file if needed:
- `OPENSHIFT_API_SERVER`: OpenShift API server URL
- `OPENSHIFT_USERNAME`: OpenShift username
- `OPENSHIFT_PASSWORD` or `OPENSHIFT_TOKEN`: Authentication credentials
- `REGISTRY_URL`: Container registry URL (if needed)

## Exit Codes

- `0`: All tests passed
- `1`: One or more tests failed

## Troubleshooting

### Tests fail with "Not connected to OpenShift cluster"

```bash
oc login <your-cluster-url>
```

### Tests fail with "pod not found"

Ensure eip-monitor is deployed:
```bash
./scripts/build-and-deploy.sh deploy
```

### Tests fail with "Prometheus not scraping"

Wait a few minutes after creating ServiceMonitor for Prometheus to discover and scrape it.

### Tests fail with "Grafana route not accessible"

Check if Grafana is deployed:
```bash
./scripts/deploy-grafana.sh --monitoring-type <coo|uwm>
```

## CI/CD Integration

The test scripts exit with appropriate codes for CI/CD integration:

```bash
# In CI/CD pipeline
if ./scripts/test-monitoring-deployment.sh; then
    echo "Monitoring tests passed"
else
    echo "Monitoring tests failed"
    exit 1
fi
```

