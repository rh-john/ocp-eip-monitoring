# Cleanup Safety Guide

This guide explains how the cleanup scripts safely handle selective deletion when both COO and UWM monitoring stacks are deployed simultaneously.

## Label Strategy

All monitoring resources are labeled with `monitoring-type` to enable selective deletion:

- **COO resources**: `monitoring-type: coo`
- **UWM resources**: `monitoring-type: uwm`
- **Combined resources**: `monitoring-type: both` (e.g., combined NetworkPolicy)

## Safe Deletion Methods

### 1. Using Label Selectors (Recommended)

The cleanup scripts use label selectors to ensure only the intended resources are deleted:

```bash
# Delete only COO resources
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=coo

# Delete only UWM resources
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=uwm

# Delete all monitoring resources (both COO and UWM)
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring=true
```

### 2. Using Resource Names (Fallback)

The cleanup scripts also delete by name as a fallback:

```bash
# COO resources
oc delete servicemonitor eip-monitor-coo -n eip-monitoring
oc delete prometheusrule eip-monitor-alerts-coo -n eip-monitoring
oc delete networkpolicy eip-monitor-coo -n eip-monitoring

# UWM resources
oc delete servicemonitor eip-monitor-uwm -n eip-monitoring
oc delete prometheusrule eip-monitor-alerts-uwm -n eip-monitoring
oc delete networkpolicy eip-monitor-uwm -n eip-monitoring
```

## Combined NetworkPolicy Handling

The combined NetworkPolicy (`eip-monitor-combined`) is handled intelligently:

- **When removing COO only**: The combined NetworkPolicy is kept if UWM is still deployed
- **When removing UWM only**: The combined NetworkPolicy is kept if COO is still deployed
- **When removing both**: The combined NetworkPolicy is deleted

## Resource Labels Reference

### COO Resources

All COO resources have these labels:
```yaml
labels:
  app: eip-monitor
  monitoring: "true"
  monitoring-type: "coo"
  coo: eip-monitoring  # Additional COO-specific label
```

Resources:
- `servicemonitor/eip-monitor-coo`
- `prometheusrule/eip-monitor-alerts-coo`
- `networkpolicy/eip-monitor-coo`
- `serviceaccount/grafana-prometheus-coo`
- `rolebinding/grafana-prometheus-coo`

### UWM Resources

All UWM resources have these labels:
```yaml
labels:
  app: eip-monitor
  monitoring: "true"
  monitoring-type: "uwm"
  uwm: eip-monitoring  # Additional UWM-specific label
```

Resources:
- `servicemonitor/eip-monitor-uwm`
- `prometheusrule/eip-monitor-alerts-uwm`
- `networkpolicy/eip-monitor-uwm`
- `serviceaccount/grafana-prometheus`
- `clusterrolebinding/grafana-prometheus-eip-monitoring`

### Combined Resources

```yaml
labels:
  app: eip-monitor
  monitoring: "true"
  monitoring-type: "both"
```

Resources:
- `networkpolicy/eip-monitor-combined`

## Manual Cleanup Examples

### Remove Only COO

```bash
# Using label selector (safest)
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=coo

# Delete COO-specific resources
oc delete monitoringstack eip-monitoring-stack -n eip-monitoring
oc delete subscription cluster-observability-operator -n openshift-operators
oc delete thanosquerier eip-monitoring-stack-querier-coo -n eip-monitoring
```

### Remove Only UWM

```bash
# Using label selector (safest)
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=uwm

# Disable UWM in cluster config (requires cluster-admin)
# Edit cluster-monitoring-config ConfigMap
```

### Remove Both

```bash
# Remove COO
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=coo
oc delete monitoringstack eip-monitoring-stack -n eip-monitoring

# Remove UWM
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=uwm

# Remove combined NetworkPolicy
oc delete networkpolicy eip-monitor-combined -n eip-monitoring

# Or remove all monitoring resources at once
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring=true
```

## Common Mistakes to Avoid

### ❌ Don't Use Generic Labels for Deletion

```bash
# BAD: This deletes both COO and UWM resources
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring=true

# GOOD: Use specific monitoring-type label
oc delete servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=coo
```

### ❌ Don't Delete Combined NetworkPolicy When One Stack Remains

```bash
# BAD: If UWM is still deployed, this breaks UWM access
oc delete networkpolicy eip-monitor-combined -n eip-monitoring

# GOOD: Let the cleanup script handle it automatically
./scripts/deploy-monitoring.sh --remove-monitoring --monitoring-type coo
```

## Verification

After cleanup, verify resources are correctly removed:

```bash
# Check remaining COO resources
oc get servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=coo

# Check remaining UWM resources
oc get servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring-type=uwm

# Check all monitoring resources
oc get servicemonitor,prometheusrule,networkpolicy -n eip-monitoring -l monitoring=true
```

## Using the Deployment Script

The deployment script handles cleanup safely:

```bash
# Remove COO only (keeps UWM if deployed)
./scripts/deploy-monitoring.sh --remove-monitoring --monitoring-type coo

# Remove UWM only (keeps COO if deployed)
./scripts/deploy-monitoring.sh --remove-monitoring --monitoring-type uwm
```

The script automatically:
1. Uses label selectors for safe deletion
2. Handles combined NetworkPolicy intelligently
3. Falls back to name-based deletion if labels aren't present
4. Verifies resources before deletion

## See Also

- [Deploy Both Monitoring Stacks](./DEPLOY_BOTH_MONITORING.md)
- [Prometheus Metrics Troubleshooting](./PROMETHEUS_METRICS_TROUBLESHOOTING.md)

