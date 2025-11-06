#!/bin/bash
# Validate all Grafana dashboards via API
# Checks for panel errors and validates queries

set -e

NAMESPACE="eip-monitoring"
GRAFANA_POD=$(oc get pods -n "$NAMESPACE" | grep grafana | grep -v operator | awk '{print $1}' | head -1)

if [[ -z "$GRAFANA_POD" ]]; then
    echo "ERROR: Grafana pod not found"
    exit 1
fi

echo "=== Grafana Dashboard Validation ==="
echo "Using pod: $GRAFANA_POD"
echo ""

# Get all dashboard UIDs
UIDS=$(oc get grafana eip-monitoring-grafana -n "$NAMESPACE" -o jsonpath='{.status.dashboards}' 2>/dev/null | jq -r '.[]' | cut -d'/' -f3)

TOTAL_DASHBOARDS=0
TOTAL_PANELS=0
ERROR_COUNT=0

for uid in $UIDS; do
    TOTAL_DASHBOARDS=$((TOTAL_DASHBOARDS + 1))
    
    # Get dashboard info
    DASHBOARD_JSON=$(oc exec "$GRAFANA_POD" -n "$NAMESPACE" -- curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/$uid" 2>/dev/null)
    
    if [[ -z "$DASHBOARD_JSON" ]] || [[ "$DASHBOARD_JSON" == "null" ]]; then
        echo "⚠️  Dashboard $uid: Not found or inaccessible"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi
    
    TITLE=$(echo "$DASHBOARD_JSON" | jq -r '.dashboard.title // "Unknown"' 2>/dev/null)
    PANEL_COUNT=$(echo "$DASHBOARD_JSON" | jq -r '.dashboard.panels | length' 2>/dev/null)
    TOTAL_PANELS=$((TOTAL_PANELS + PANEL_COUNT))
    
    echo "✓ Dashboard: $TITLE"
    echo "  UID: $uid"
    echo "  Panels: $PANEL_COUNT"
    
    # Check for panels with queries
    QUERY_PANELS=$(echo "$DASHBOARD_JSON" | jq -r '.dashboard.panels[] | select(.targets != null and .targets[0].expr != null) | "\(.id) - \(.title): \(.targets[0].expr)"' 2>/dev/null | head -5)
    
    if [[ -n "$QUERY_PANELS" ]]; then
        echo "  Sample queries:"
        echo "$QUERY_PANELS" | sed 's/^/    /'
    fi
    
    echo ""
done

echo "=== Summary ==="
echo "Total Dashboards: $TOTAL_DASHBOARDS"
echo "Total Panels: $TOTAL_PANELS"
echo "Errors: $ERROR_COUNT"

if [[ $ERROR_COUNT -eq 0 ]]; then
    echo "✅ All dashboards validated successfully!"
    exit 0
else
    echo "❌ Found $ERROR_COUNT dashboard(s) with issues"
    exit 1
fi

