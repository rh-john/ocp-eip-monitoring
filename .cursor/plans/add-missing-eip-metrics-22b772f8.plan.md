<!-- 22b772f8-98a7-4dff-abae-6127a7753395 fc091716-32bd-4495-8237-c238667bdb5c -->
# Fix Cluster Health & Alerts Dashboard Duplicate Values

## Problem

Multiple panels are showing duplicate values (e.g., CPIC Status Overview showing everything x2). This is likely due to:

1. Queries returning multiple series that need aggregation
2. Incorrect `reduceOptions` configuration in pie charts and stat panels
3. Missing query aggregation functions for metrics that might have labels

## Solution Approach

1. Review all panel queries and ensure proper aggregation
2. Fix pie chart configurations to properly handle multiple targets
3. Fix stat panel configurations to show one value per target
4. Validate all queries against the actual metrics endpoint
5. Test queries through Prometheus/Thanos if available

## Files to Modify

- `k8s/grafana/grafana-dashboard-cluster-health.yaml`

## Panel Fixes Required

### Panel 4: EIP Status Overview (Pie Chart)

- **Issue**: May show duplicates if queries return multiple series
- **Fix**: Add `sum()` aggregation to queries: `sum(eips_assigned_total)` and `sum(eips_unassigned_total)`
- **Fix**: Ensure `reduceOptions.calcs` is `["lastNotNull"]` and `values: false`

### Panel 5: CPIC Status Overview (Pie Chart) 

- **Issue**: Showing everything x2
- **Fix**: Add `sum()` aggregation: `sum(cpic_success_total)`, `sum(cpic_pending_total)`, `sum(cpic_error_total)`
- **Fix**: Verify `reduceOptions` configuration

### Panel 6: Key Metrics Summary (Stat Panel)

- **Issue**: Multiple targets may show duplicates
- **Fix**: Add `sum()` or `last()` aggregation to each query
- **Fix**: Ensure each target has unique `refId` and proper `legendFormat`

### Panel 7: Node Health Summary (Stat Panel)

- **Issue**: May show duplicates
- **Fix**: Add aggregation: `sum(eip_nodes_available_total)`, `sum(eip_nodes_with_errors_total)`

### Panel 13: Health Status Metrics (Stat Panel)

- **Issue**: Multiple health metrics may show duplicates
- **Fix**: Add aggregation to each query: `sum(malfunctioning_eip_objects_count)`, etc.

### Panel 12: Multi-Stat Health Overview (Polystat)

- **Issue**: May show duplicate values
- **Fix**: Add `sum()` aggregation to all queries
- **Fix**: Verify polystat panel configuration

### Panel 11: Health Metrics Table

- **Issue**: Table with multiple targets may show duplicates
- **Fix**: Add `sum()` aggregation to all queries
- **Fix**: Ensure proper table transformations

### Other Panels

- Review all remaining panels (1, 2, 3, 8, 9, 10, 14) for proper query aggregation
- Ensure gauge panels use `last()` or `sum()` as appropriate
- Ensure timeseries panels have proper legend formats

## Validation Steps (CRITICAL - Must be done BEFORE and AFTER changes)

### Phase 1: Pre-Update Validation (BEFORE making any dashboard changes)

1. **Validate all current metric names exist**:

- Test via `oc exec` to pod: `curl http://localhost:8080/metrics | grep <metric_name>`
- Verify each metric returns expected format (single value or labeled series)
- Document current behavior of each metric

2. **Test current Prometheus queries**:

- Access Prometheus/Thanos querier via `oc port-forward` or route
- Execute each query from dashboard panels
- Identify which queries return multiple series (causing duplicates)
- Document query results and identify root cause

3. **Test queries with proposed aggregations**:

- Test `sum(<metric>)` for each metric to verify it returns single value
- Test `last(<metric>)` where appropriate
- Verify aggregation eliminates duplicates

### Phase 2: Dashboard Update

- Apply fixes based on validation findings
- Update queries with proper aggregations
- Fix panel configurations

### Phase 3: Post-Update Validation (End-to-End Testing)

1. **Validate dashboard JSON structure**:

- Verify JSON is valid
- Check all panel IDs are unique
- Verify no panel overlaps

2. **Test via Grafana API (if available)**:

- Use Grafana API to validate dashboard loads
- Check for any dashboard errors

3. **Validate queries in Grafana**:

- Access Grafana UI or API
- Test each panel query individually
- Verify no duplicate values appear
- Verify correct data is displayed

4. **End-to-end visual validation**:

- View dashboard in Grafana UI
- Verify each panel shows correct single values
- Verify pie charts show correct proportions (not doubled)
- Verify stat panels show one value per metric
- Verify table shows correct data without duplicates

## Implementation Notes

- Use `sum()` for metrics that should be aggregated across all series
- Use `last()` for metrics that are already single values but may have labels
- Ensure all pie chart targets have unique `refId` values (A, B, C, etc.)
- Verify `legendFormat` is unique and descriptive for each target
- For stat panels with multiple targets, ensure `reduceOptions` is properly configured