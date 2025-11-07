# Cluster Event Correlation Dashboards

This document describes the cluster event correlation features added to the EIP monitoring dashboards.

## Overview

The dashboards have been updated to correlate EIP and CPIC events with significant cluster and node events, including:
- Node status changes (Ready/NotReady)
- Node reboots
- OVN network events
- CNCC (Cloud Controller Manager) events

## New Dashboard

### `grafana-dashboard-event-correlation.yaml`
A comprehensive correlation dashboard that shows:
- EIP events vs Node status timeline
- CPIC events vs Node status
- Node reboot detection
- EIP assignment rate vs Node status changes
- CPIC error rate vs Node conditions (MemoryPressure, DiskPressure, NetworkUnavailable)
- OVN network events timeline
- CNCC events timeline
- Correlations between EIP/CPIC events and OVN/CNCC status

## Updated Dashboards

### `grafana-dashboard-timeline-events.yaml`
- Added node status (NotReady) to EIP assignment timeline
- Added node status changes and reboots to EIP assignment rate panel
- Added CPIC error events vs OVN/CNCC degraded status
- Added node reboot detection panel
- Added OVN & CNCC status timeline panel

### `grafana-dashboard-eip-timeline.yaml`
- Added node status changes and reboots to EIP assignment/unassignment rate
- Added OVN/CNCC degraded status to EIP changes panel
- Added node status vs EIP events timeline panel

### `grafana-dashboard-cpic-health.yaml`
- Added not ready nodes count to CPIC success rate panel
- Added OVN/CNCC degraded status and node reboots to CPIC recovery rate
- Added node status & reboots timeline panel
- Added OVN & CNCC status vs CPIC events timeline panel

## Prometheus Metrics Used

### Node Metrics (from kube-state-metrics)
All node metrics are filtered to only include nodes with the label `k8s.ovn.org/egress-assignable=true`. The filtering uses a union approach to handle nodes that had the label but no longer do (or were deleted):

- `kube_node_status_condition{condition="Ready",status="false"} and on(node) (kube_node_labels{label_k8s_ovn_org_egress_assignable="true"} or node_eip_assigned_total)` - Nodes not ready (EIP-capable only)
- `kube_node_status_condition{condition="Ready",status="true"} and on(node) (kube_node_labels{label_k8s_ovn_org_egress_assignable="true"} or node_eip_assigned_total)` - Nodes ready (EIP-capable only)
- `kube_node_status_condition{condition="MemoryPressure",status="true"} and on(node) (kube_node_labels{label_k8s_ovn_org_egress_assignable="true"} or node_eip_assigned_total)` - Memory pressure (EIP-capable only)
- `kube_node_status_condition{condition="DiskPressure",status="true"} and on(node) (kube_node_labels{label_k8s_ovn_org_egress_assignable="true"} or node_eip_assigned_total)` - Disk pressure (EIP-capable only)
- `kube_node_status_condition{condition="NetworkUnavailable",status="true"} and on(node) (kube_node_labels{label_k8s_ovn_org_egress_assignable="true"} or node_eip_assigned_total)` - Network unavailable (EIP-capable only)

**Filtering Logic**: The queries use `(kube_node_labels{label_k8s_ovn_org_egress_assignable="true"} or node_eip_assigned_total)` to include:
1. Nodes that currently have the `k8s.ovn.org/egress-assignable=true` label
2. Nodes that appear in EIP metrics (which already filter by EIP-capable nodes), including historical nodes that had the label but no longer do

### Node Reboot Detection (EIP-capable nodes only)
- `node_boot_time_seconds and on(instance) group_left(node) kube_node_info{label_k8s_ovn_org_egress_assignable="true"}` - Node boot time (EIP-capable only)
- `changes((node_boot_time_seconds and on(instance) group_left(node) kube_node_info{label_k8s_ovn_org_egress_assignable="true"})[10m]) > 0` - Detects reboots (EIP-capable only)
- `changes((kube_node_status_condition{condition="Ready",status="false"} and on(node) (kube_node_labels{label_k8s_ovn_org_egress_assignable="true"} or node_eip_assigned_total))[5m]) > 0` - Alternative reboot detection (EIP-capable only)

**Note**: Node boot time queries use `kube_node_info` to join on the `instance` label, filtering by the egress-assignable label. This ensures only EIP-capable nodes are included in reboot detection.

### Cluster Operator Metrics (OpenShift)
- `cluster_operator_conditions{name="network",condition="Degraded",status="true"}` - OVN degraded
- `cluster_operator_conditions{name="network",condition="Available",status="false"}` - OVN unavailable
- `cluster_operator_conditions{name="cloud-controller-manager",condition="Degraded",status="true"}` - CNCC degraded
- `cluster_operator_conditions{name="cloud-controller-manager",condition="Available",status="false"}` - CNCC unavailable

### OVN Metrics (if available)
- `ovn_cluster_version{phase="Available"}` - OVN available
- `ovn_cluster_version{phase="Progressing"}` - OVN progressing
- `ovn_cluster_version{phase="Degraded"}` - OVN degraded

**Note**: OVN metrics may vary based on your OpenShift version and configuration. The `ovn_cluster_version` metric may not exist in all environments. The dashboards primarily use `cluster_operator_conditions` which is more universally available.

## Metric Availability Notes

1. **Node Metrics**: Standard kube-state-metrics should be available in most Kubernetes/OpenShift clusters
2. **Node Boot Time**: Requires node-exporter to be running and scraping node metrics
3. **Cluster Operator Conditions**: Standard OpenShift metrics, should be available via Thanos Querier
4. **OVN Metrics**: May need to verify exact metric names in your environment

## Verification

To verify metrics are available in your Grafana datasource:

1. Open Grafana and navigate to Explore
2. Select your Prometheus datasource
3. Try querying:
   ```promql
   kube_node_status_condition
   cluster_operator_conditions
   node_boot_time_seconds
   ```

If any metrics are not available, you may need to:
- Check if kube-state-metrics is running
- Verify node-exporter is scraping node metrics
- Confirm cluster operator metrics are being collected
- Adjust metric names in the dashboards to match your environment

## Usage

After deploying these dashboards, you can:
1. View correlations between EIP/CPIC events and cluster events
2. Identify if node issues (reboots, status changes) correlate with EIP assignment problems
3. Detect if OVN or CNCC issues coincide with CPIC errors
4. Analyze patterns between cluster health and EIP/CPIC stability

## Troubleshooting

If panels show "No data":
1. Verify the Prometheus datasource has access to cluster metrics (via Thanos Querier)
2. Check that the service account has `cluster-monitoring-view` ClusterRole
3. Verify metric names match your OpenShift version
4. Use Grafana Explore to test queries directly

