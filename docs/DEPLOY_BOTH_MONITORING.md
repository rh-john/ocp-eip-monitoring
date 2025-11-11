# Deploying Both COO and UWM Monitoring Simultaneously

This guide explains how to deploy and run both Cluster Observability Operator (COO) and User Workload Monitoring (UWM) simultaneously with the same `eip-monitor` service.

## Overview

The `eip-monitor` service is designed to support both COO and UWM monitoring stacks simultaneously. Both ServiceMonitors can discover and scrape the same service without conflicts.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│              eip-monitor Service                         │
│  Labels: app=eip-monitor, service=eip-monitor           │
│          monitoring-coo=true, monitoring-uwm=true     │
└─────────────────────────────────────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
┌───────────────┐      ┌───────────────┐
│ COO Prometheus │      │ UWM Prometheus │
│ (same ns)     │      │ (uwm ns)      │
└───────────────┘      └───────────────┘
```

## Key Points

1. **Service Labels**: The service has labels that match both ServiceMonitor selectors:
   - `app: eip-monitor` (required by both)
   - `service: eip-monitor` (required by both)
   - `monitoring-coo: "true"` (optional, for identification)
   - `monitoring-uwm: "true"` (optional, for identification)

2. **No Conflicts**: Both ServiceMonitors can scrape the same service simultaneously. Prometheus instances are independent and don't interfere with each other.

3. **NetworkPolicy**: Use the combined NetworkPolicy (`networkpolicy-combined.yaml`) when deploying both stacks to allow traffic from both Prometheus instances.

## Deployment Steps

### 1. Deploy the eip-monitor Application

```bash
oc apply -f k8s/deployment/k8s-manifests.yaml
```

This creates:
- Namespace: `eip-monitoring`
- Deployment: `eip-monitor` (1-2 replicas)
- Service: `eip-monitor` (with labels supporting both COO and UWM)

### 2. Deploy COO Monitoring Stack

```bash
# Install COO operator (if not already installed)
oc apply -f k8s/monitoring/coo/operator/coo-operator-subscription.yaml

# Deploy COO monitoring resources
oc apply -f k8s/monitoring/coo/monitoring/monitoringstack-coo.yaml
oc apply -f k8s/monitoring/coo/monitoring/servicemonitor-coo.yaml
oc apply -f k8s/monitoring/coo/monitoring/prometheusrule-coo.yaml
oc apply -f k8s/grafana/coo/grafana-rbac-coo.yaml
```

### 3. Deploy UWM Monitoring Stack

```bash
# Enable UWM (requires cluster-admin)
# This is typically done via cluster-monitoring-config ConfigMap
# See: k8s/monitoring/uwm/monitoring/ for UWM configuration

# Deploy UWM monitoring resources
oc apply -f k8s/monitoring/uwm/monitoring/servicemonitor-uwm.yaml
oc apply -f k8s/monitoring/uwm/monitoring/prometheusrule-uwm.yaml
oc apply -f k8s/grafana/uwm/grafana-rbac-uwm.yaml
```

### 4. Deploy Combined NetworkPolicy

**Important**: When deploying both COO and UWM, use the combined NetworkPolicy instead of the individual ones:

```bash
# Deploy combined NetworkPolicy (supports both COO and UWM)
oc apply -f k8s/monitoring/networkpolicy-combined.yaml

# DO NOT deploy both individual NetworkPolicies:
# - networkpolicy-coo.yaml
# - networkpolicy-uwm.yaml
# These will conflict if both are applied to the same pods
```

The combined NetworkPolicy allows:
- COO Prometheus (in `eip-monitoring` namespace)
- UWM Prometheus (in `openshift-user-workload-monitoring` namespace)
- Platform Prometheus (in `openshift-monitoring` namespace, optional)

### 5. Verify Both Stacks Are Scraping

```bash
# Check COO Prometheus targets
COO_PROM=$(oc get pods -n eip-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
oc exec -n eip-monitoring $COO_PROM -- curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job | contains("eip"))'

# Check UWM Prometheus targets
UWM_PROM=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-user-workload-monitoring $UWM_PROM -- curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job | contains("eip"))'
```

## Configuration Options

### Deployment Replicas

The deployment supports 1-2 replicas:

```yaml
spec:
  replicas: 1  # or 2 for HA
```

**Recommendations:**
- **1 replica**: Sufficient for most use cases, both Prometheus instances can scrape the same pod
- **2 replicas**: Provides redundancy and load distribution. Each Prometheus can scrape a different pod instance

### Service Labels

The service automatically includes labels for both monitoring types:

```yaml
labels:
  app: eip-monitor
  service: eip-monitor
  monitoring: "true"
  monitoring-coo: "true"    # Indicates COO support
  monitoring-uwm: "true"    # Indicates UWM support
```

## Troubleshooting

### Both ServiceMonitors Not Discovering Service

1. **Check service labels**:
   ```bash
   oc get service eip-monitor -n eip-monitoring -o yaml | grep -A 5 labels
   ```

2. **Verify ServiceMonitor selectors match**:
   ```bash
   # COO ServiceMonitor
   oc get servicemonitor eip-monitor-coo -n eip-monitoring -o yaml | grep -A 3 selector
   
   # UWM ServiceMonitor
   oc get servicemonitor eip-monitor-uwm -n eip-monitoring -o yaml | grep -A 3 selector
   ```

3. **Fix service labels if needed**:
   ```bash
   ./scripts/debug/fix-service-labels.sh
   ```

### NetworkPolicy Blocking Traffic

If Prometheus cannot scrape metrics:

1. **Check which NetworkPolicy is applied**:
   ```bash
   oc get networkpolicy -n eip-monitoring
   ```

2. **Use combined NetworkPolicy**:
   ```bash
   # Remove individual policies
   oc delete networkpolicy eip-monitor-coo eip-monitor-uwm -n eip-monitoring
   
   # Apply combined policy
   oc apply -f k8s/monitoring/networkpolicy-combined.yaml
   ```

### Prometheus Targets Show "Down"

1. **Check service endpoints**:
   ```bash
   oc get endpoints eip-monitor -n eip-monitoring
   ```

2. **Verify pods are running**:
   ```bash
   oc get pods -n eip-monitoring -l app=eip-monitor
   ```

3. **Check NetworkPolicy allows traffic**:
   ```bash
   oc describe networkpolicy eip-monitor-combined -n eip-monitoring
   ```

## Benefits of Running Both

1. **Redundancy**: If one monitoring stack fails, the other continues monitoring
2. **Comparison**: Compare metrics from both stacks to verify consistency
3. **Migration**: Gradually migrate from one stack to another
4. **Testing**: Test new monitoring configurations without affecting production

## Single Stack Deployment

If you only want to deploy one monitoring stack:

- **COO only**: Use `networkpolicy-coo.yaml`
- **UWM only**: Use `networkpolicy-uwm.yaml`
- **Both**: Use `networkpolicy-combined.yaml` (recommended)

## See Also

- [Container Deployment Guide](./CONTAINER_DEPLOYMENT.md)

