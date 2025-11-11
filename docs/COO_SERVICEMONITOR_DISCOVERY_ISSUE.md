# COO ServiceMonitor Discovery Issue

## Problem

Prometheus managed by COO (Cluster Observability Operator) is not discovering ServiceMonitors, even though:
- ServiceMonitor exists with correct labels
- Prometheus `serviceMonitorSelector` matches ServiceMonitor labels
- Both are in the same namespace
- Service has endpoints
- Configuration appears correct

## Current Status

- ✅ ServiceMonitor `eip-monitor-coo` exists in `eip-monitoring` namespace
- ✅ ServiceMonitor has label `app: eip-monitor` (matches selector)
- ✅ Prometheus has `serviceMonitorSelector: {app: eip-monitor}`
- ✅ Service `eip-monitor` exists with endpoints
- ✅ MonitoringStack `resourceSelector` matches ServiceMonitor labels
- ❌ Prometheus only shows `prometheus-self` and `alertmanager-self` jobs
- ❌ No `eip-monitor` scrape job created

## Configuration Details

### MonitoringStack
```yaml
spec:
  resourceSelector:
    matchLabels:
      app: eip-monitor
```

### Prometheus Resource (created by COO)
```yaml
spec:
  serviceMonitorSelector:
    matchLabels:
      app: eip-monitor
  serviceMonitorNamespaceSelector: null  # Only same namespace
```

### ServiceMonitor
```yaml
metadata:
  labels:
    app: eip-monitor
    coo: eip-monitoring
    monitoring: "true"
spec:
  selector:
    matchLabels:
      app: eip-monitor
      service: eip-monitor
  namespaceSelector:
    matchNames:
    - eip-monitoring
```

## Troubleshooting Attempted

1. ✅ Verified ServiceMonitor labels match Prometheus selector
2. ✅ Verified service has endpoints
3. ✅ Restarted Prometheus pods multiple times
4. ✅ Annotated ServiceMonitor with `prometheus.io/scrape: true`
5. ✅ Patched MonitoringStack to force reconciliation
6. ✅ Patched Prometheus resource to force reload
7. ✅ Checked OBO operator logs (no errors found)
8. ✅ Verified Prometheus operator is syncing

## Possible Causes

1. **COO/OBO Bug**: There may be a bug in how COO's MonitoringStack `resourceSelector` is propagated to the Prometheus resource's `serviceMonitorSelector`
2. **Timing Issue**: ServiceMonitor may have been created after Prometheus, and operator hasn't re-evaluated
3. **Namespace Selector**: May need explicit `serviceMonitorNamespaceSelector` on Prometheus
4. **Operator Cache**: Prometheus operator may have stale cache

## Potential Solutions

### Solution 1: Add Explicit Namespace Selector

Try adding `serviceMonitorNamespaceSelector` to the Prometheus resource (if COO allows):

```yaml
spec:
  serviceMonitorNamespaceSelector:
    matchLabels:
      name: eip-monitoring
```

### Solution 2: Recreate MonitoringStack

Delete and recreate the MonitoringStack to force full reconciliation:

```bash
oc delete monitoringstack eip-monitoring-stack -n eip-monitoring
# Wait for cleanup
oc apply -f k8s/monitoring/coo/monitoring/monitoringstack-coo.yaml
```

### Solution 3: Use Direct Prometheus Resource

Instead of relying on MonitoringStack, create Prometheus resource directly with explicit selectors.

### Solution 4: Check COO Version

This may be a known issue in the COO version. Check:
- COO operator version
- Known issues in release notes
- Consider upgrading/downgrading COO

### Solution 5: Use UWM Instead

If COO continues to have issues, consider switching to User Workload Monitoring (UWM) which is more mature and widely used.

## Workaround: Manual Scrape Config

As a temporary workaround, you could add a manual scrape config via `additionalScrapeConfigs`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: eip-monitor-scrape-config
  namespace: eip-monitoring
type: Opaque
stringData:
  scrape-config.yaml: |
    - job_name: 'eip-monitor'
      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - eip-monitoring
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_label_app]
        regex: eip-monitor
        action: keep
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        regex: metrics
        action: keep
```

Then reference in MonitoringStack or Prometheus resource.

## Next Steps

1. Check COO GitHub issues for similar problems
2. Contact Red Hat support if using supported version
3. Consider switching to UWM if COO issues persist
4. Monitor COO operator logs more closely for ServiceMonitor evaluation

## References

- [COO Documentation](https://github.com/rhobs/observability-operator)
- [Prometheus Operator ServiceMonitor Discovery](https://github.com/prometheus-operator/prometheus-operator/blob/main/Documentation/user-guides/getting-started.md)

