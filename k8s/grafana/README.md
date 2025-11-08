# Grafana Dashboards for EIP Monitoring

This directory contains comprehensive Grafana dashboards for visualizing EgressIP (EIP) monitoring data in OpenShift clusters.

## 📸 Dashboard Screenshots

> **Note:** Screenshots can be added by deploying the dashboards, taking screenshots, and placing them in a `screenshots/` directory. Update the image paths below once screenshots are available.

### Main Dashboard
![Main EIP Monitoring Dashboard](screenshots/main-dashboard.png)
*Overview of all EIP metrics, CPIC status, and node assignments*

### Distribution & Heatmap
![EIP Distribution Dashboard](screenshots/distribution-heatmap.png)
*Heatmap visualization showing EIP distribution across nodes over time*

### State Visualization
![State Visualization Dashboard](screenshots/state-visualization.png)
*Discrete state changes and timeline visualization of EIP assignments*

### Enhanced Tables
![Enhanced Tables Dashboard](screenshots/enhanced-tables.png)
*Advanced table views with multi-level thresholds and color coding*

### Network Topology
![Network Topology Dashboard](screenshots/network-topology.png)
*Interactive node graph showing network topology and EIP distribution*

---

## 📊 Dashboard Overview

### Original Dashboards

#### 1. Main EIP Monitoring Dashboard
**File:** `grafana-dashboard.yaml`

**Description:**  
The primary dashboard providing a comprehensive overview of EIP monitoring metrics. Displays key statistics, trends, and status information.

**Key Panels:**
- EIP Overview (Configured, Assigned, Unassigned counts)
- EIP Utilization Gauge
- CPIC Status Summary
- EIP Assignment Trends (Time Series)
- Node Distribution
- Error Rate Monitoring

**Use Cases:**
- Quick health check of EIP system
- Overview of current EIP utilization
- Monitoring assignment trends over time

**Screenshot Location:** `screenshots/main-dashboard.png`

---

#### 2. EIP Distribution & Heatmap
**File:** `grafana-dashboard-eip-distribution.yaml`

**Description:**  
Advanced heatmap and distribution analysis showing how EIPs are distributed across nodes and over time.

**Key Panels:**
- EIP Distribution Heatmap by Node
- Node Load Distribution (Bar Chart)
- EIP Assignment Patterns
- Load Balance Score
- Distribution Statistics

**Use Cases:**
- Identifying load imbalance across nodes
- Analyzing assignment patterns
- Capacity planning
- Troubleshooting distribution issues

**Screenshot Location:** `screenshots/distribution-heatmap.png`

---

#### 3. CPIC Health Dashboard
**File:** `grafana-dashboard-cpic-health.yaml`

**Description:**  
Focused monitoring of CloudPrivateIPConfig (CPIC) health, success rates, and error tracking.

**Key Panels:**
- CPIC Success Rate Gauge
- CPIC Status by Node
- Error Breakdown
- Pending Assignments
- CPIC Health Trends

**Use Cases:**
- Monitoring CPIC assignment success
- Identifying nodes with CPIC errors
- Tracking pending assignments
- Health trend analysis

**Screenshot Location:** `screenshots/cpic-health.png`

---

#### 4. Node Performance Dashboard
**File:** `grafana-dashboard-node-performance.yaml`

**Description:**  
Performance metrics and utilization statistics for individual nodes in the cluster.

**Key Panels:**
- Node EIP Assignment Count
- Node Utilization Percentage
- Performance Trends
- Node Comparison Charts
- Resource Usage

**Use Cases:**
- Node-level performance analysis
- Identifying overloaded nodes
- Capacity planning per node
- Performance optimization

**Screenshot Location:** `screenshots/node-performance.png`

---

#### 5. EIP Timeline Dashboard
**File:** `grafana-dashboard-eip-timeline.yaml`

**Description:**  
Timeline visualization showing EIP assignment events, changes, and historical trends.

**Key Panels:**
- Assignment Timeline
- Event History
- Change Frequency
- Historical Trends
- Event Correlation

**Use Cases:**
- Tracking assignment history
- Analyzing change patterns
- Troubleshooting assignment issues
- Historical analysis

**Screenshot Location:** `screenshots/eip-timeline.png`

---

#### 6. Cluster Health Dashboard
**File:** `grafana-dashboard-cluster-health.yaml`

**Description:**  
Cluster-wide health overview with aggregated metrics and system status.

**Key Panels:**
- Overall Cluster Health Score
- Aggregate Metrics
- System Status Indicators
- Health Trends
- Alert Summary

**Use Cases:**
- Cluster-level health monitoring
- System-wide status overview
- Alert management
- Health trend tracking

**Screenshot Location:** `screenshots/cluster-health.png`

---

### Advanced Plugin Dashboards

#### 7. State Visualization Dashboard
**File:** `grafana-dashboard-state-visualization.yaml`

**Description:**  
Advanced state visualization using discrete panels and state timeline to show EIP assignment states over time.

**Key Panels:**
- EIP Assignment States Over Time (Discrete Panel)
- CPIC Status States by Node
- EIP State Distribution (Pie Chart)
- Node EIP Assignment Timeline (State Timeline)

**Visual Features:**
- Color-coded state bands showing transitions
- Discrete value visualization for state changes
- Timeline view of state history
- Distribution analysis

**Use Cases:**
- Visualizing state transitions
- Identifying state change patterns
- Monitoring assignment stability
- Troubleshooting state issues

**Screenshot Location:** `screenshots/state-visualization.png`

---

#### 8. Enhanced Tables Dashboard
**File:** `grafana-dashboard-enhanced-tables.yaml`

**Description:**  
Advanced table visualizations with multi-level thresholds, color coding, and enhanced data presentation.

**Key Panels:**
- EIP Assignment Table with Thresholds
- CPIC Status by Node (Multi-Column)
- EIP Utilization Summary Table

**Visual Features:**
- Color-coded cells based on thresholds
- Multi-column data presentation
- Sortable and filterable tables
- Threshold-based highlighting

**Use Cases:**
- Detailed EIP assignment analysis
- Node-by-node status comparison
- Quick identification of issues
- Data export and analysis

**Screenshot Location:** `screenshots/enhanced-tables.png`

---

#### 9. Architecture Diagram Dashboard
**File:** `grafana-dashboard-architecture-diagram.yaml`

**Description:**  
Visual architecture diagrams showing EIP assignment flow, node topology, and system relationships.

**Key Panels:**
- EIP Assignment Flow (Diagram Panel)
- Node Topology Overview (Node Graph)
- EIP Status Summary Stats
- Mermaid.js Lifecycle Diagram

**Visual Features:**
- Interactive node graphs
- Flow diagram visualization
- Topology mapping
- Lifecycle documentation

**Use Cases:**
- Understanding system architecture
- Visualizing node relationships
- Documenting assignment flow
- System design reference

**Screenshot Location:** `screenshots/architecture-diagram.png`

---

#### 10. Custom Gauges Dashboard
**File:** `grafana-dashboard-custom-gauges.yaml`

**Description:**  
Custom gauge visualizations for key metrics with advanced threshold configuration and visual styling.

**Key Panels:**
- Overall EIP Utilization Gauge
- CPIC Success Rate Gauge
- Node Load Balance Score Gauge
- EIP Assignment Rate Gauge
- Error Rate Gauge
- Pending Assignments Gauge

**Visual Features:**
- Multiple gauge styles
- Custom threshold zones
- Color-coded indicators
- Real-time value updates

**Use Cases:**
- Quick metric visualization
- Threshold monitoring
- At-a-glance status checks
- Performance indicators

**Screenshot Location:** `screenshots/custom-gauges.png`

---

#### 11. Timeline Events Dashboard
**File:** `grafana-dashboard-timeline-events.yaml`

**Description:**  
Comprehensive timeline and event visualization for tracking EIP assignment events and state changes.

**Key Panels:**
- EIP Assignment Timeline (State Timeline)
- Node Assignment Events
- CPIC Status Timeline
- EIP Assignment Rate Over Time
- Event Frequency Histogram
- CPIC Error Events Log

**Visual Features:**
- Multi-state timeline visualization
- Event frequency analysis
- Historical event tracking
- Correlation analysis

**Use Cases:**
- Event timeline analysis
- Historical event tracking
- Pattern identification
- Troubleshooting event sequences

**Screenshot Location:** `screenshots/timeline-events.png`

---

#### 12. Node Health Grid Dashboard
**File:** `grafana-dashboard-node-health-grid.yaml`

**Description:**  
Comprehensive node health status grid with detailed metrics and visual indicators.

**Key Panels:**
- Node Health Status Grid (Table)
- Node Health Summary Stats
- Node Load Distribution (Bar Gauge)
- CPIC Status by Node (Bar Gauge)

**Visual Features:**
- Color-coded health indicators
- Grid-based status overview
- Load distribution visualization
- Quick health assessment

**Use Cases:**
- Node health monitoring
- Quick status overview
- Load distribution analysis
- Health trend tracking

**Screenshot Location:** `screenshots/node-health-grid.png`

---

#### 13. Network Topology Dashboard
**File:** `grafana-dashboard-network-topology.yaml`

**Description:**  
Interactive network topology visualization showing node relationships, EIP distribution, and network structure.

**Key Panels:**
- Node Network Graph (Interactive)
- EIP Distribution Heatmap
- Node Connection Matrix
- Load Balance Visualization (Histogram)
- Network Topology Summary Stats
- Network Utilization Gauge
- Balance Score Indicator

**Visual Features:**
- Interactive node graph
- Heatmap visualization
- Connection matrix
- Distribution analysis

**Use Cases:**
- Network topology understanding
- Distribution analysis
- Load balance monitoring
- Network optimization

**Screenshot Location:** `screenshots/network-topology.png`

---

#### 14. Interactive Drilldown Dashboard
**File:** `grafana-dashboard-interactive-drilldown.yaml`

**Description:**  
Interactive navigation dashboard with click-to-drill functionality and cross-dashboard links.

**Key Panels:**
- EIP Overview (Click to Drill Down)
- Assigned EIPs (Click for Node Details)
- CPIC Success (Click for Health Details)
- CPIC Errors (Click for Timeline)
- Node Selection Table
- Quick Metrics Overview
- Navigation Links

**Visual Features:**
- Clickable stat panels
- Cross-dashboard navigation
- Quick access links
- Interactive exploration

**Use Cases:**
- Quick navigation between dashboards
- Interactive data exploration
- Drill-down analysis
- Dashboard navigation hub

**Screenshot Location:** `screenshots/interactive-drilldown.png`

---

## 🚀 Quick Start

### Deployment

Deploy all dashboards with a single command:

```bash
# For COO monitoring
./scripts/deploy-grafana.sh --monitoring-type coo

# For UWM monitoring
./scripts/deploy-grafana.sh --monitoring-type uwm
```

Or deploy individual dashboards:

```bash
oc apply -f k8s/grafana/grafana-dashboard-state-visualization.yaml
```

### Accessing Dashboards

1. Get the Grafana route:
   ```bash
   oc get route -n eip-monitoring | grep grafana
   ```

2. Open the URL in your browser

3. Login with default credentials (configured in `grafana-instance.yaml`)

4. Navigate to Dashboards → Browse

---

## 📸 Adding Screenshots

To add screenshots to this README:

1. **Deploy the dashboards:**
   ```bash
   # For COO monitoring
   ./scripts/deploy-grafana.sh --monitoring-type coo
   
   # For UWM monitoring
   ./scripts/deploy-grafana.sh --monitoring-type uwm
   ```

2. **Create screenshots directory:**
   ```bash
   mkdir -p k8s/grafana/screenshots
   ```

3. **Take screenshots:**
   - Open each dashboard in Grafana
   - Take full-page screenshots (recommended: 1920x1080 or higher)
   - Save as PNG format
   - Name files according to dashboard (e.g., `main-dashboard.png`)

4. **Screenshot naming convention:**
   - `main-dashboard.png` - Main EIP Monitoring Dashboard
   - `distribution-heatmap.png` - EIP Distribution & Heatmap
   - `cpic-health.png` - CPIC Health Dashboard
   - `node-performance.png` - Node Performance Dashboard
   - `eip-timeline.png` - EIP Timeline Dashboard
   - `cluster-health.png` - Cluster Health Dashboard
   - `state-visualization.png` - State Visualization Dashboard
   - `enhanced-tables.png` - Enhanced Tables Dashboard
   - `architecture-diagram.png` - Architecture Diagram Dashboard
   - `custom-gauges.png` - Custom Gauges Dashboard
   - `timeline-events.png` - Timeline Events Dashboard
   - `node-health-grid.png` - Node Health Grid Dashboard
   - `network-topology.png` - Network Topology Dashboard
   - `interactive-drilldown.png` - Interactive Drilldown Dashboard

5. **Update README:**
   - Screenshots are already referenced in this README
   - Just add the image files to `k8s/grafana/screenshots/`
   - Images will automatically display once files are present

---

## 🔧 Built-in Panels Used

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

---

## 🎨 Optional Community Plugins

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

Plugins are automatically installed via the `GF_INSTALL_PLUGINS` environment variable configured in `grafana-instance.yaml`. The format is: `plugin1:version1,plugin2:version2,...`

**Current plugins installed:**
- jdbranham-diagram-panel:1.0.0
- natel-discrete-panel:0.0.9
- yesoreyeram-boomtable-panel:1.0.0
- vonage-status-panel:1.0.7
- agenty-flowcharting-panel:1.0.0
- grafana-clock-panel:2.1.0
- grafana-worldmap-panel:0.3.5

**To add more plugins:**

1. **Edit `grafana-instance.yaml`:**
   ```yaml
   spec:
     deployment:
       spec:
         template:
           spec:
             containers:
               - name: grafana
                 env:
                   - name: GF_INSTALL_PLUGINS
                     value: "existing-plugins,new-plugin-id:x.x.x"
   ```

2. **Apply the changes:**
   ```bash
   oc apply -f k8s/grafana/grafana-instance.yaml
   ```

3. **Grafana will restart and install the plugins automatically**

**Alternative: Manual installation (not persistent):**

1. **Via Grafana UI:**
   - Go to Configuration → Plugins
   - Search for the plugin name
   - Click Install

2. **Via Grafana CLI (in Grafana pod):**
   ```bash
   oc exec -it <grafana-pod> -n eip-monitoring -- grafana-cli plugins install <plugin-id>
   oc delete pod <grafana-pod> -n eip-monitoring  # Restart to load plugin
   ```

**Note:** Manual installations are not persistent across pod restarts. Use the environment variable method for persistent plugin installation.

---

## 📊 Dashboard Features

### Common Features Across All Dashboards

- **Dark Theme** - All dashboards use dark theme by default
- **Auto Refresh** - 30-second refresh interval
- **Browser Timezone** - Timezone set to browser default
- **Interactive** - Click panels to drill down or explore
- **Responsive** - Adapts to different screen sizes
- **Color Coding** - Consistent color scheme for status indicators

### Navigation

Dashboards are linked together for easy navigation:
- Use the **Interactive Drilldown Dashboard** as a navigation hub
- Click stat panels to navigate to related dashboards
- Use dashboard links in panel descriptions

---

## 🔍 Customization

All dashboards use Prometheus queries that can be customized. Common variables:

- `eips_configured_total` - Total configured EIPs
- `eips_assigned_total` - Assigned EIPs
- `eips_unassigned_total` - Unassigned EIPs
- `cpic_success_total` - Successful CPICs
- `cpic_error_total` - Failed CPICs
- `cpic_pending_total` - Pending CPICs
- `node_eip_assigned_total` - EIPs per node

### Customizing Queries

1. Open dashboard in Grafana
2. Click panel title → Edit
3. Modify the Prometheus query in the Query tab
4. Click Save

### Customizing Visualizations

1. Edit panel → Visualization tab
2. Adjust colors, thresholds, and display options
3. Configure field overrides for specific fields
4. Save changes

---

## 🐛 Troubleshooting

### Dashboards Don't Appear

1. **Check Grafana instance:**
   ```bash
   oc get grafana -n eip-monitoring
   ```

2. **Verify dashboards are created:**
   ```bash
   oc get grafanadashboard -n eip-monitoring
   ```

3. **Check Grafana logs:**
   ```bash
   oc logs -f deployment/eip-monitoring-grafana -n eip-monitoring
   ```

4. **Verify datasource:**
   ```bash
   oc get grafanadatasource -n eip-monitoring
   ```

### No Data in Dashboards

1. **Check Prometheus metrics:**
   ```bash
   oc exec -it <eip-monitor-pod> -n eip-monitoring -- curl http://localhost:8080/metrics | grep eips_
   ```

2. **Verify ServiceMonitor:**
   ```bash
   oc get servicemonitor -n eip-monitoring
   ```

3. **Check Prometheus scraping:**
   - Open Prometheus UI
   - Check Targets → Service Discovery
   - Verify EIP monitor is being scraped

### Panels Show "No Data"

1. **Verify metric names match:**
   - Check actual metric names from `/metrics` endpoint
   - Update queries in dashboard if needed

2. **Check time range:**
   - Ensure time range includes data points
   - Try "Last 5 minutes" or "Last 1 hour"

3. **Verify label matching:**
   - Check if labels in queries match actual labels
   - Use Prometheus query browser to test queries

---

## 📚 Additional Resources

- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Prometheus Query Language](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Grafana Panel Types](https://grafana.com/docs/grafana/latest/panels-visualizations/)
- [OpenShift Monitoring Guide](https://docs.openshift.com/container-platform/latest/monitoring/)

---

## 📝 Notes

- All dashboards use the dark theme by default
- Refresh interval is set to 30 seconds
- Timezone is set to browser default
- Dashboards are linked together for easy navigation
- Screenshots can be added to the `screenshots/` directory
- Community plugins are optional and can enhance visualizations

---

## 🤝 Contributing

To add new dashboards or improve existing ones:

1. Create new dashboard YAML file in `k8s/grafana/`
2. Add dashboard to `deploy-grafana.sh` script
3. Update this README with dashboard description
4. Add screenshot (optional but recommended)
5. Test dashboard deployment
6. Submit pull request

---

**Last Updated:** 2024  
**Total Dashboards:** 14 (6 original + 8 advanced)  
**Grafana Version:** Compatible with Grafana 8.0+
