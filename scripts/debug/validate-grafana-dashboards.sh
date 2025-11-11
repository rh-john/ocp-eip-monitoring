#!/bin/bash
# Validate all Grafana dashboards via API
# Checks for panel errors and validates queries

set -e

NAMESPACE="${NAMESPACE:-eip-monitoring}"

# Check if Grafana instance exists
if ! oc get grafana -n "$NAMESPACE" &>/dev/null; then
    echo "ERROR: Grafana instance not found in namespace '$NAMESPACE'"
    echo ""
    echo "Please deploy Grafana first:"
    echo "  ./scripts/deploy-grafana.sh --monitoring-type coo"
    echo "  or"
    echo "  ./scripts/deploy-grafana.sh --monitoring-type uwm"
    exit 1
fi

# Wait for Grafana pod to be ready
echo "Waiting for Grafana pod to be ready..."
MAX_WAIT=60
WAITED=0
GRAFANA_POD=""

while [[ $WAITED -lt $MAX_WAIT ]]; do
    GRAFANA_POD=$(oc get pods -n "$NAMESPACE" | grep grafana | grep -v operator | awk '{print $1}' | head -1)
    if [[ -n "$GRAFANA_POD" ]]; then
        POD_STATUS=$(oc get pod "$GRAFANA_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$POD_STATUS" == "Running" ]]; then
            READY=$(oc get pod "$GRAFANA_POD" -n "$NAMESPACE" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
            if [[ "$READY" == "true" ]]; then
                break
            fi
        fi
    fi
    sleep 2
    WAITED=$((WAITED + 2))
done

if [[ -z "$GRAFANA_POD" ]]; then
    echo "ERROR: Grafana pod not found in namespace '$NAMESPACE'"
    echo ""
    echo "Current pods:"
    oc get pods -n "$NAMESPACE" | grep grafana || echo "  (none found)"
    echo ""
    echo "Grafana instance status:"
    oc get grafana -n "$NAMESPACE" -o yaml | grep -A 5 "status:" || echo "  (no status available)"
    exit 1
fi

echo "=== Grafana Dashboard Validation ==="
echo "Using pod: $GRAFANA_POD"
echo ""

# Get Grafana instance name
GRAFANA_INSTANCE=$(oc get grafana -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$GRAFANA_INSTANCE" ]]; then
    echo "ERROR: Could not find Grafana instance name"
    exit 1
fi

echo "Grafana instance: $GRAFANA_INSTANCE"
echo ""

# Get all dashboard UIDs
UIDS=$(oc get grafana "$GRAFANA_INSTANCE" -n "$NAMESPACE" -o jsonpath='{.status.dashboards}' 2>/dev/null | jq -r '.[]' 2>/dev/null | cut -d'/' -f3 2>/dev/null || echo "")

if [[ -z "$UIDS" ]]; then
    echo "⚠️  No dashboards found in Grafana instance status"
    echo "   This may mean dashboards are still being processed or not yet deployed"
    echo ""
    echo "Check dashboard resources:"
    oc get grafanadashboard -n "$NAMESPACE" 2>/dev/null || echo "  (none found)"
    exit 0
fi

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

