#!/bin/bash
#
# Add Prometheus inspect links to Perses dashboard panels
# Uses yq to modify YAML files and add inspect links to each panel
#

set -euo pipefail

# Get the route URL (automatically includes namespace in hostname)
# Fallback to service URL if route doesn't exist
PROMETHEUS_BASE_URL=$(oc get route thanos-querier-coo -n eip-monitoring -o jsonpath='https://{.spec.host}/graph' 2>/dev/null || echo "http://thanos-querier-eip-monitoring-stack-querier-coo.eip-monitoring.svc.cluster.local:10902/graph")

# Function to URL encode a string
url_encode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Function to add inspect link to a panel
add_inspect_link() {
    local file="$1"
    local panel_path="$2"
    local query="$3"
    
    # URL encode the query
    local encoded_query=$(url_encode "$query")
    local inspect_url="${PROMETHEUS_BASE_URL}?g0.expr=${encoded_query}&g0.tab=0"
    
    # Check if links already exist for this panel
    local has_link=$(yq eval "${panel_path}.spec.links" "$file" 2>/dev/null || echo "null")
    
    if [[ "$has_link" != "null" ]]; then
        # Check if inspect link already exists
        local link_count=$(yq eval "${panel_path}.spec.links | length" "$file" 2>/dev/null || echo "0")
        local i=0
        local found=false
        while [[ $i -lt $link_count ]]; do
            local title=$(yq eval "${panel_path}.spec.links[$i].title" "$file" 2>/dev/null || echo "")
            if [[ "$title" == "Inspect" ]] || [[ "$title" == "Inspect in Prometheus" ]]; then
                found=true
                break
            fi
            i=$((i + 1))
        done
        
        if [[ "$found" == "true" ]]; then
            return 0  # Link already exists
        fi
    fi
    
    # Add the inspect link (matching system dashboard style)
    yq eval -i "${panel_path}.spec.links += [{\"title\": \"Inspect\", \"url\": \"${inspect_url}\", \"tooltip\": \"Inspect query in Prometheus\"}]" "$file" 2>/dev/null || {
        # If links array doesn't exist, create it
        yq eval -i "${panel_path}.spec.links = [{\"title\": \"Inspect\", \"url\": \"${inspect_url}\", \"tooltip\": \"Inspect query in Prometheus\"}]" "$file"
    }
}

# Main function
main() {
    local dashboard_dir="${1:-k8s/monitoring/coo/perses/dashboards}"
    
    if [[ ! -d "$dashboard_dir" ]]; then
        echo "Error: Dashboard directory not found: $dashboard_dir"
        exit 1
    fi
    
    echo "Processing dashboards in: $dashboard_dir"
    echo "Prometheus URL: $PROMETHEUS_BASE_URL"
    echo ""
    
    local updated_count=0
    
    for dashboard_file in "$dashboard_dir"/*.yaml; do
        [[ -f "$dashboard_file" ]] || continue
        
        local basename=$(basename "$dashboard_file")
        echo "Processing: $basename"
        
        # Get all panel keys
        local panels=$(yq eval '.spec.panels | keys | .[]' "$dashboard_file" 2>/dev/null || echo "")
        
        if [[ -z "$panels" ]]; then
            echo "  ⚠️  No panels found"
            continue
        fi
        
        local panel_updated=false
        while IFS= read -r panel_key; do
            [[ -z "$panel_key" ]] && continue
            
            # Get the first Prometheus query from this panel
            local query=$(yq eval ".spec.panels[\"${panel_key}\"].spec.queries[] | select(.spec.plugin.kind == \"PrometheusTimeSeriesQuery\") | .spec.plugin.spec.query" "$dashboard_file" 2>/dev/null | head -1)
            
            if [[ -n "$query" ]] && [[ "$query" != "null" ]]; then
                local panel_path=".spec.panels[\"${panel_key}\"]"
                add_inspect_link "$dashboard_file" "$panel_path" "$query"
                panel_updated=true
                echo "  ✓ Added inspect link to panel: $panel_key"
            fi
        done <<< "$panels"
        
        if [[ "$panel_updated" == "true" ]]; then
            updated_count=$((updated_count + 1))
        else
            echo "  ⊘ No Prometheus queries found in panels"
        fi
        echo ""
    done
    
    if [[ $updated_count -gt 0 ]]; then
        echo "✓ Successfully updated $updated_count dashboard file(s)"
    else
        echo "No dashboards needed updates"
    fi
}

main "$@"

