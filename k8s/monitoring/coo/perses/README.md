# Perses Dashboards and Datasources for COO

This directory contains PersesDashboards and PersesDatasources converted from Grafana resources for use with the Cluster Observability Operator (COO).

## Structure

```
k8s/monitoring/coo/perses/
├── datasources/
│   └── prometheus-coo.yaml          # Prometheus datasource for COO
└── dashboards/
    └── eip-event-correlation.yaml   # Example converted dashboard
```

## Key Differences from Grafana

Perses uses a fundamentally different structure than Grafana:

### Datasources
- **Grafana**: `GrafanaDatasource` with `spec.datasource.url` and `spec.datasource.jsonData`
- **Perses**: `PersesDatasource` with `spec.config.plugin.kind` and `spec.config.plugin.spec`

### Dashboards
- **Grafana**: JSON embedded in `spec.json` with `panels` array and `gridPos`
- **Perses**: Structured YAML with:
  - `spec.panels` map (key-value pairs, not array)
  - `spec.queries` array within each panel
  - `spec.layouts` array with GridLayout and `$ref` to panels
  - Datasources referenced by name in queries

### Panel Structure
- **Grafana**: `targets` array with `expr` and `legendFormat`
- **Perses**: `queries` array with `TimeSeriesQuery` and `PrometheusTimeSeriesQuery` plugin structure

## Conversion Process

1. **Datasources**: Relatively straightforward - map URL and configuration to Perses plugin structure
2. **Dashboards**: Complex - requires:
   - Converting each panel to Perses panel spec
   - Converting Grafana `targets` to Perses `queries` with plugin structure
   - Converting `gridPos` to GridLayout items
   - Mapping panel types (Grafana types → Perses plugin kinds)

## Usage

### Deploy Datasource
**Important**: PersesDatasources must be in the `openshift-operators` namespace to be visible in the OpenShift web console. The datasource URL can still reference services in other namespaces (e.g., `eip-monitoring`).

```bash
oc apply -f k8s/monitoring/coo/perses/datasources/prometheus-coo.yaml
```

### Deploy Dashboard
**Important**: PersesDashboards must be in the `openshift-operators` namespace to be visible in the OpenShift web console.

```bash
oc apply -f k8s/monitoring/coo/perses/dashboards/eip-event-correlation.yaml
```

### Verify
```bash
oc get perses -n openshift-operators
oc get persesdatasource -n openshift-operators
oc get persesdashboard -n openshift-operators
```

## Namespace Architecture

**For Console Integration**:
- **Perses in `openshift-operators`**: Created automatically by UIPlugin when `spec.monitoring.perses.enabled: true`
- **PersesDashboards in `openshift-operators`**: Required for dashboards to appear in OpenShift web console
- **PersesDatasources in `openshift-operators`**: Required for datasources to be available to console dashboards

**Why `openshift-operators` namespace?**
- The UIPlugin creates the Perses instance in `openshift-operators` for console integration
- The console only shows dashboards from the Perses instance in that namespace
- Datasources can still reference services in other namespaces (e.g., `thanos-querier-eip-monitoring-stack-querier-coo.eip-monitoring.svc.cluster.local`)

## Conversion Script

A basic conversion script is available:
```bash
./scripts/convert-grafana-to-perses.sh
```

**Note**: The script creates basic structure only. Full conversion requires manual work for:
- Panel type mapping (Grafana panel types → Perses plugin kinds)
- Query conversion (Grafana targets → Perses TimeSeriesQuery)
- Layout conversion (Grafana gridPos → Perses GridLayout)

## Perses Plugin Types

Common Perses panel plugins:
- `TimeSeriesChart` - for time-series data
- `StatChart` - for single value displays
- `GaugeChart` - for gauge visualizations
- `TableChart` - for tabular data

Query plugins:
- `PrometheusTimeSeriesQuery` - for Prometheus queries
- `PrometheusLabelNamesQuery` - for label names
- `PrometheusLabelValuesQuery` - for label values

## References

- [Perses Documentation](https://perses.dev)
- [COO Perses Support](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/)

