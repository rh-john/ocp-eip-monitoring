# Grafana Dashboards for EIP Monitoring

This directory contains Grafana dashboards for visualizing EgressIP (EIP) monitoring data.

## Dashboard Overview

### Original Dashboards
1. **grafana-dashboard.yaml** - Main EIP monitoring dashboard
2. **grafana-dashboard-eip-distribution.yaml** - EIP distribution and heatmap analysis
3. **grafana-dashboard-cpic-health.yaml** - CloudPrivateIPConfig health monitoring
4. **grafana-dashboard-node-performance.yaml** - Node performance metrics
5. **grafana-dashboard-eip-timeline.yaml** - EIP assignment timeline
6. **grafana-dashboard-cluster-health.yaml** - Cluster-wide health overview

### Advanced Plugin Dashboards
7. **grafana-dashboard-state-visualization.yaml** - State visualization using discrete panels and state timeline
8. **grafana-dashboard-enhanced-tables.yaml** - Enhanced tables with multi-level thresholds
9. **grafana-dashboard-architecture-diagram.yaml** - Architecture diagrams and node graphs
10. **grafana-dashboard-custom-gauges.yaml** - Custom gauge visualizations
11. **grafana-dashboard-timeline-events.yaml** - Timeline and event visualization
12. **grafana-dashboard-node-health-grid.yaml** - Node health status grid
13. **grafana-dashboard-network-topology.yaml** - Network topology and distribution
14. **grafana-dashboard-interactive-drilldown.yaml** - Interactive drilldown navigation

## Built-in Panels Used

All dashboards use built-in Grafana panels that work out of the box:
- **State Timeline** - For state changes over time
- **Node Graph** - For network topology visualization
- **Heatmap** - For distribution analysis
- **Histogram** - For load distribution
- **Table** - Enhanced with color thresholds and transformations
- **Gauge** - Customizable gauges with thresholds
- **Stat** - Summary statistics
- **Timeseries** - Time-based metrics
- **Piechart/Donut** - Distribution visualization
- **Bargauge** - Horizontal bar gauges

## Optional Community Plugins

For even more advanced visualizations, you can install these community plugins:

### Recommended Plugins

1. **Discrete Panel** (`grafana-discrete-panel`)
   - Better discrete state visualization
   - Install: `grafana-cli plugins install natel-discrete-panel`

2. **Boom Table** (`grafana-boomtable-panel`)
   - Enhanced table with multi-level thresholds
   - Install: `grafana-cli plugins install yesoreyeram-boomtable-panel`

3. **FlowCharting** (`grafana-flowcharting-panel`)
   - Advanced diagramming with draw.io
   - Install: `grafana-cli plugins install agenty-flowcharting-panel`

4. **D3 Gauge** (`grafana-d3-gauge-panel`)
   - Customizable D3-based gauges
   - Install: `grafana-cli plugins install btplc-status-dot-panel`

5. **Diagram Panel** (`grafana-diagram-panel`)
   - Mermaid.js diagram support
   - Install: `grafana-cli plugins install jdbranham-diagram-panel`

### Installing Plugins

To install plugins in your Grafana instance:

1. **Via Grafana UI:**
   - Go to Configuration → Plugins
   - Search for the plugin name
   - Click Install

2. **Via Grafana CLI (in Grafana pod):**
   ```bash
   oc exec -it <grafana-pod> -n eip-monitoring -- grafana-cli plugins install <plugin-id>
   oc rollout restart deployment/<grafana-deployment> -n eip-monitoring
   ```

3. **Via ConfigMap (for persistent installation):**
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: grafana-plugins
     namespace: eip-monitoring
   data:
     plugins.txt: |
       natel-discrete-panel
       yesoreyeram-boomtable-panel
       agenty-flowcharting-panel
   ```

## Deployment

All dashboards are automatically deployed when you run:

```bash
./scripts/deploy-grafana.sh
```

Or they can be deployed individually:

```bash
oc apply -f k8s/grafana/grafana-dashboard-state-visualization.yaml
```

## Dashboard Features

### State Visualization Dashboard
- Discrete state changes over time
- CPIC status states by node
- EIP state distribution
- Node assignment timeline

### Enhanced Tables Dashboard
- EIP assignment table with thresholds
- Multi-column CPIC status
- Utilization summary with color coding

### Architecture Diagram Dashboard
- EIP assignment flow diagrams
- Node topology overview
- Mermaid.js lifecycle diagrams

### Custom Gauges Dashboard
- Overall EIP utilization
- CPIC success rate
- Node load balance score
- Assignment rate monitoring

### Timeline Events Dashboard
- EIP assignment timeline
- Node assignment events
- CPIC status timeline
- Event frequency analysis

### Node Health Grid Dashboard
- Comprehensive node health status
- Load distribution visualization
- CPIC status by node

### Network Topology Dashboard
- Interactive node network graph
- EIP distribution heatmap
- Load balance visualization
- Network utilization metrics

### Interactive Drilldown Dashboard
- Click-to-drill navigation
- Quick metrics overview
- Cross-dashboard links
- Node selection interface

## Customization

All dashboards use Prometheus queries that can be customized. Common variables:
- `eips_configured_total` - Total configured EIPs
- `eips_assigned_total` - Assigned EIPs
- `eips_unassigned_total` - Unassigned EIPs
- `cpic_success_total` - Successful CPICs
- `cpic_error_total` - Failed CPICs
- `cpic_pending_total` - Pending CPICs
- `node_eip_assigned_total` - EIPs per node

## Troubleshooting

If dashboards don't appear:
1. Check Grafana instance is running: `oc get grafana -n eip-monitoring`
2. Verify dashboards are created: `oc get grafanadashboard -n eip-monitoring`
3. Check Grafana logs: `oc logs -f deployment/eip-monitoring-grafana -n eip-monitoring`
4. Verify datasource is configured: `oc get grafanadatasource -n eip-monitoring`

## Notes

- All dashboards use the dark theme by default
- Refresh interval is set to 30 seconds
- Timezone is set to browser default
- Dashboards are linked together for easy navigation

