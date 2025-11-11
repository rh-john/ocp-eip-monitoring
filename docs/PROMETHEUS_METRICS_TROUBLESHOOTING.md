# Prometheus Metrics Ingestion Troubleshooting

## Issue: Prometheus Scrapes Metrics But They're Not Queryable

### Symptoms
- Prometheus successfully scrapes the target (status: `up`)
- Last scrape time shows recent successful scrapes
- Metrics are visible when querying the pod directly (`curl http://pod:8080/metrics`)
- **But**: Prometheus queries return no results for EIP metrics

### Root Causes

1. **Timing Issue (Most Common)**
   - Prometheus needs time to ingest metrics after scraping
   - Typically requires 1-2 scrape intervals (30-60 seconds with 30s interval)
   - Metrics may not be immediately queryable after first scrape

2. **Query Syntax**
   - Incorrect PromQL query syntax
   - Missing or incorrect label selectors
   - Job label mismatch

3. **Relabeling Issues**
   - Metrics being dropped by relabeling rules
   - Label conflicts causing metrics to be filtered

4. **ServiceMonitor Configuration**
   - ServiceMonitor labels don't match service labels
   - Endpoint configuration issues

### Solutions

#### 1. Wait for Metrics Ingestion

Prometheus typically needs 1-2 scrape intervals to ingest metrics. With a 30s scrape interval, wait at least 60-90 seconds after the first successful scrape.

```bash
# Use the verification script
./scripts/debug/verify-prometheus-metrics.sh
```

#### 2. Verify ServiceMonitor Configuration

Check that the ServiceMonitor matches the service labels:

```bash
# Check ServiceMonitor
oc get servicemonitor eip-monitor-coo -n eip-monitoring -o yaml

# Check Service labels
oc get service eip-monitor -n eip-monitoring -o yaml

# Ensure labels match:
# ServiceMonitor selector: app=eip-monitor, service=eip-monitor
# Service labels: app=eip-monitor, service=eip-monitor
```

#### 3. Check Prometheus Target Status

```bash
# Get Prometheus pod
PROM_POD=$(oc get pods -n eip-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')

# Port-forward to Prometheus
oc port-forward $PROM_POD 9090:9090 -n eip-monitoring

# In another terminal, check targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job | contains("eip"))'
```

#### 4. Query Prometheus Correctly

Try different query patterns:

```promql
# Simple metric name
eips_configured_total

# With empty label selector
eips_configured_total{}

# With job label
{__name__="eips_configured_total", job=~".*eip.*"}

# List all metrics from eip-monitor job
{job=~".*eip.*"}

# List all available metrics
{__name__=~".*eip.*"}
```

#### 5. Check Prometheus Logs

```bash
# Get Prometheus pod
PROM_POD=$(oc get pods -n eip-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')

# Check logs for errors
oc logs $PROM_POD -n eip-monitoring | grep -i error

# Check for relabeling issues
oc logs $PROM_POD -n eip-monitoring | grep -i relabel
```

#### 5. Verify Metrics Endpoint

```bash
# Get eip-monitor pod
EIP_POD=$(oc get pods -n eip-monitoring -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}')

# Check metrics directly from pod
oc exec $EIP_POD -n eip-monitoring -- curl -s http://localhost:8080/metrics | grep eips_configured_total

# Check from Prometheus pod (network connectivity)
PROM_POD=$(oc get pods -n eip-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
SERVICE_IP=$(oc get service eip-monitor -n eip-monitoring -o jsonpath='{.spec.clusterIP}')
oc exec $PROM_POD -n eip-monitoring -- curl -s http://${SERVICE_IP}:8080/metrics | grep eips_configured_total
```

### Automated Verification

Use the provided verification script:

```bash
# Run verification script
./scripts/debug/verify-prometheus-metrics.sh

# Or with custom namespace/monitoring type
MONITORING_TYPE=coo NAMESPACE=eip-monitoring ./scripts/debug/verify-prometheus-metrics.sh
```

The script will:
1. Check ServiceMonitor configuration
2. Verify service labels match
3. Check Prometheus target status
4. Wait for metrics ingestion (up to 6 minutes)
5. Query Prometheus with multiple query patterns
6. Display sample metrics if found

### Common Fixes

#### Fix 1: Wait Longer
Simply wait 2-3 minutes after deployment and try querying again.

#### Fix 2: Restart Prometheus
If metrics still don't appear after waiting:

```bash
# Get Prometheus pod
PROM_POD=$(oc get pods -n eip-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')

# Delete pod to force restart (will be recreated automatically)
oc delete pod $PROM_POD -n eip-monitoring
```

#### Fix 3: Reapply ServiceMonitor
Sometimes reapplying the ServiceMonitor helps:

```bash
# Reapply ServiceMonitor
oc apply -f k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml

# Wait for Prometheus to reload configuration (usually 30-60 seconds)
```

#### Fix 4: Check MonitoringStack Resource Selector

For COO, ensure the MonitoringStack's `resourceSelector` matches the ServiceMonitor labels:

```yaml
# In coo-monitoringstack.yaml
spec:
  resourceSelector:
    matchLabels:
      app: eip-monitor  # Must match ServiceMonitor labels
```

### Expected Behavior

After successful deployment:
1. ServiceMonitor is created
2. Prometheus discovers the target within 30-60 seconds
3. First scrape happens within 30-60 seconds
4. Metrics become queryable 30-90 seconds after first scrape
5. All EIP metrics are available in Prometheus

### Verification Queries

Once metrics are available, you should be able to query:

```promql
# Core metrics
eips_configured_total
eips_assigned_total
eips_unassigned_total
eip_utilization_percent

# CPIC metrics
cpic_success_total
cpic_pending_total
cpic_error_total

# Node metrics
node_eip_assigned_total
node_cpic_success_total

# List all EIP-related metrics
{__name__=~"eip.*|cpic.*|node_.*"}
```

### Still Having Issues?

1. Check Prometheus configuration:
   ```bash
   oc get prometheus -n eip-monitoring -o yaml
   ```

2. Check for relabeling rules that might drop metrics:
   ```bash
   # Port-forward to Prometheus
   oc port-forward <prometheus-pod> 9090:9090 -n eip-monitoring
   
   # Check configuration
   curl http://localhost:9090/api/v1/status/config | jq '.data.yaml'
   ```

3. Verify network connectivity from Prometheus to service:
   ```bash
   PROM_POD=$(oc get pods -n eip-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
   SERVICE_IP=$(oc get service eip-monitor -n eip-monitoring -o jsonpath='{.spec.clusterIP}')
   oc exec $PROM_POD -n eip-monitoring -- curl -v http://${SERVICE_IP}:8080/metrics
   ```

4. Check ServiceMonitor is selected by Prometheus:
   ```bash
   # For COO
   oc get monitoringstack eip-monitoring-stack -n eip-monitoring -o yaml
   
   # Check resourceSelector matches ServiceMonitor labels
   ```

