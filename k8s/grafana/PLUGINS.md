# Grafana Community Plugins for EIP Monitoring

This document describes the community plugins installed for EIP monitoring dashboards and how they enhance the visualizations.

## Installed Plugins

### 1. Diagram Panel (`jdbranham-diagram-panel`)
**Version:** 1.0.0  
**Used In:** Architecture Diagram Dashboard

**Purpose:**  
Renders Mermaid.js diagrams including flowcharts, sequence diagrams, and Gantt charts.

**Benefits:**
- Visual EIP assignment flow diagrams
- Sequence diagrams for lifecycle visualization
- No external dependencies
- Works with dark theme

**Example Use:**
- EIP Assignment Flow diagram
- EIP Lifecycle sequence diagram

---

### 2. Discrete Panel (`natel-discrete-panel`)
**Version:** 0.0.9  
**Used In:** State Visualization Dashboard

**Purpose:**  
Displays discrete values in a horizontal graph, perfect for visualizing state changes over time.

**Benefits:**
- Better than standard graphs for discrete states
- Color-coded state bands
- Shows state transitions clearly
- Ideal for EIP assignment states (assigned/unassigned/pending)

**Example Use:**
- EIP Assignment States Over Time
- CPIC Status States by Node

---

### 3. Boom Table (`yesoreyeram-boomtable-panel`)
**Version:** 1.0.0  
**Used In:** Enhanced Tables Dashboard

**Purpose:**  
Advanced table visualization with multi-level thresholds, cell-level customization, and enhanced data presentation.

**Benefits:**
- Individual cell thresholds
- Multi-level threshold support
- Time-based thresholds
- Cell value transformations
- Better than standard table panels

**Example Use:**
- EIP Assignment Table with per-cell thresholds
- CPIC Status by Node (multi-column)
- Utilization summary with color coding

---

### 4. Status Panel (`vonage-status-panel`)
**Version:** 1.0.7  
**Used In:** Node Health Grid Dashboard

**Purpose:**  
Displays status indicators for multiple items (nodes) with customizable status levels and visual indicators.

**Benefits:**
- Grid-based status overview
- Color-coded health indicators
- Quick visual assessment
- Perfect for node health monitoring

**Example Use:**
- Node Health Status Grid
- Quick node health overview

---

### 5. FlowCharting (`agenty-flowcharting-panel`)
**Version:** 1.0.0  
**Used In:** Architecture Diagram Dashboard (alternative)

**Purpose:**  
Advanced diagramming using draw.io library for complex technical architecture diagrams.

**Benefits:**
- Professional architecture diagrams
- Technical schema visualization
- Workflow charts
- More advanced than Mermaid diagrams

**Example Use:**
- Complex EIP architecture diagrams
- Node relationship diagrams
- System workflow visualization

---

### 6. Clock Panel (`grafana-clock-panel`)
**Version:** 2.1.0  
**Used In:** All dashboards (optional)

**Purpose:**  
Displays current time, timezone information, and can show last update timestamps.

**Benefits:**
- Shows dashboard refresh status
- Multiple timezone support
- Custom time formats
- Useful for monitoring sync status

**Example Use:**
- Last update timestamp
- Timezone display
- Refresh indicator

---

### 7. Worldmap Panel (`grafana-worldmap-panel`)
**Version:** 0.3.5  
**Used In:** Network Topology Dashboard (if geo-distributed)

**Purpose:**  
Displays metrics on a world map, useful if nodes are geographically distributed.

**Benefits:**
- Geographic visualization
- Node location mapping
- Regional distribution analysis
- Useful for multi-region deployments

**Example Use:**
- Geographic distribution of EIP assignments
- Regional node health mapping
- Multi-region topology visualization

---

## Plugin Installation

All plugins are automatically installed by the Grafana Operator when deploying the Grafana instance. They are configured in `grafana-instance.yaml`:

```yaml
spec:
  plugins:
    - name: jdbranham-diagram-panel
      version: "1.0.0"
    # ... more plugins
```

## Adding More Plugins

To add additional plugins:

1. **Find the plugin ID and version:**
   - Visit [Grafana Plugins Catalog](https://grafana.com/plugins)
   - Search for the plugin
   - Note the plugin ID and latest version

2. **Add to `grafana-instance.yaml`:**
   ```yaml
   plugins:
     - name: plugin-id
       version: "x.x.x"
   ```

3. **Redeploy:**
   ```bash
   oc apply -f k8s/grafana/grafana-instance.yaml
   ```

4. **Verify installation:**
   - Check Grafana UI: Configuration → Plugins
   - Or check pod logs: `oc logs <grafana-pod> -n eip-monitoring`

## Plugin Compatibility

All plugins listed are:
- ✅ Compatible with Grafana 8.0+
- ✅ Actively maintained
- ✅ Open source
- ✅ No additional dependencies required
- ✅ Work with Prometheus data source

## Recommended Additional Plugins (Optional)

If you want even more advanced features, consider:

- **Candlestick Panel** - For EIP assignment patterns (min/max/avg)
- **Histogram Panel** - Enhanced histogram visualizations
- **Trend Panel** - Trend indicators and forecasts
- **Alert Groups Panel** - Advanced alert grouping
- **Logs Panel** - Enhanced log visualization
- **Node Graph Panel** - Already built-in, but can be enhanced

## Troubleshooting

### Plugin Not Appearing

1. **Check plugin installation:**
   ```bash
   oc exec <grafana-pod> -n eip-monitoring -- ls /var/lib/grafana/plugins
   ```

2. **Check Grafana logs:**
   ```bash
   oc logs <grafana-pod> -n eip-monitoring | grep -i plugin
   ```

3. **Verify plugin version:**
   - Some plugins may have version compatibility issues
   - Try latest stable version from Grafana catalog

### Plugin Not Working

1. **Restart Grafana:**
   ```bash
   oc delete pod <grafana-pod> -n eip-monitoring
   ```

2. **Check plugin compatibility:**
   - Verify plugin supports your Grafana version
   - Check plugin documentation

3. **Clear browser cache:**
   - Sometimes browser cache causes issues
   - Try incognito/private mode

## Plugin Updates

To update plugins:

1. **Check for updates:**
   - Visit plugin page on Grafana catalog
   - Check changelog for breaking changes

2. **Update version in YAML:**
   ```yaml
   plugins:
     - name: plugin-id
       version: "new-version"
   ```

3. **Apply changes:**
   ```bash
   oc apply -f k8s/grafana/grafana-instance.yaml
   ```

4. **Restart Grafana:**
   ```bash
   oc delete pod <grafana-pod> -n eip-monitoring
   ```

---

**Last Updated:** 2024  
**Total Plugins:** 7  
**Grafana Version:** Compatible with 8.0+

