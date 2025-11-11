#!/bin/bash
#
# Convert Grafana Dashboards and Datasources to Perses format
# This script converts GrafanaDashboard and GrafanaDatasource resources
# to PersesDashboard and PersesDatasource format for use with COO
#
# Usage: ./scripts/convert-grafana-to-perses.sh [options]
#
# Options:
#   --input-dir DIR     Directory containing Grafana resources (default: k8s/grafana)
#   --output-dir DIR    Directory to write Perses resources (default: k8s/monitoring/coo/perses)
#   --datasource-only   Only convert datasources
#   --dashboard-only    Only convert dashboards
#   --help, -h          Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

INPUT_DIR="${INPUT_DIR:-$PROJECT_ROOT/k8s/grafana}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/k8s/monitoring/coo/perses}"
CONVERT_DATASOURCES=true
CONVERT_DASHBOARDS=true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_usage() {
    cat << EOF
Convert Grafana Dashboards and Datasources to Perses format

Usage: $0 [options]

Options:
  --input-dir DIR      Directory containing Grafana resources (default: k8s/grafana)
  --output-dir DIR     Directory to write Perses resources (default: k8s/monitoring/coo/perses)
  --datasource-only    Only convert datasources
  --dashboard-only     Only convert dashboards
  --help, -h           Show this help message

Note: This is a basic conversion script. Perses uses a different structure than Grafana,
so manual adjustments may be required after conversion.

EOF
}

# Convert Grafana datasource to Perses datasource
convert_datasource() {
    local grafana_file="$1"
    local output_file="$2"
    
    log_info "Converting datasource: $(basename "$grafana_file")"
    
    # Extract datasource name and namespace from Grafana resource
    local name=$(yq eval '.metadata.name' "$grafana_file" 2>/dev/null || echo "")
    local namespace=$(yq eval '.metadata.namespace' "$grafana_file" 2>/dev/null || echo "eip-monitoring")
    local url=$(yq eval '.spec.datasource.url' "$grafana_file" 2>/dev/null || echo "")
    local datasource_name=$(yq eval '.spec.name' "$grafana_file" 2>/dev/null || echo "$name")
    
    if [[ -z "$name" ]]; then
        log_error "Could not extract name from $grafana_file"
        return 1
    fi
    
    # Create Perses datasource
    cat > "$output_file" << EOF
---
# Perses DataSource converted from Grafana
# Source: $(basename "$grafana_file")
apiVersion: perses.dev/v1alpha1
kind: PersesDatasource
metadata:
  name: $name
  namespace: $namespace
  labels:
    app: eip-monitor
    monitoring: coo
    coo: eip-monitoring
spec:
  config:
    default: true
    display:
      name: "$datasource_name"
      description: "COO-managed Prometheus via ThanosQuerier"
    plugin:
      kind: PrometheusDatasource
      spec:
        directUrl: $url
        proxy:
          kind: HTTPProxy
          spec:
            allowedEndpoints:
              - endpointPattern: /api/v1/query
              - endpointPattern: /api/v1/query_range
              - endpointPattern: /api/v1/label/.*/values
              - endpointPattern: /api/v1/series
              - endpointPattern: /api/v1/metadata
        queryTimeout: 300s
        timeInterval: 15s
        httpMethod: POST
        tlsSkipVerify: true
EOF
    
    log_success "Created: $output_file"
}

# Convert Grafana dashboard to Perses dashboard (basic structure)
convert_dashboard() {
    local grafana_file="$1"
    local output_file="$2"
    
    log_info "Converting dashboard: $(basename "$grafana_file")"
    log_warn "Dashboard conversion requires manual adjustments - Perses uses different panel/query structure"
    
    # Extract dashboard info
    local name=$(yq eval '.metadata.name' "$grafana_file" 2>/dev/null || echo "")
    local namespace=$(yq eval '.metadata.namespace' "$grafana_file" 2>/dev/null || echo "eip-monitoring")
    
    if [[ -z "$name" ]]; then
        log_error "Could not extract name from $grafana_file"
        return 1
    fi
    
    # Extract JSON and parse title
    local json_content=$(yq eval '.spec.json' "$grafana_file" 2>/dev/null || echo "{}")
    local title=$(echo "$json_content" | jq -r '.title // "Dashboard"' 2>/dev/null || echo "Dashboard")
    local refresh=$(echo "$json_content" | jq -r '.refresh // "30s"' 2>/dev/null || echo "30s")
    
    # Create basic Perses dashboard structure
    # Note: Full conversion requires parsing all panels, queries, and layouts
    cat > "$output_file" << EOF
---
# Perses Dashboard converted from Grafana
# Source: $(basename "$grafana_file")
# NOTE: This is a basic conversion - manual adjustments required for panels, queries, and layouts
apiVersion: perses.dev/v1alpha1
kind: PersesDashboard
metadata:
  name: $name
  namespace: $namespace
  labels:
    app: eip-monitor
    monitoring: coo
spec:
  display:
    name: "$title"
    description: "Converted from Grafana dashboard"
  duration: 6h
  refreshInterval: $refresh
  datasources:
    prometheus-coo:
      default: true
      display:
        name: "Prometheus-COO"
      plugin:
        kind: PrometheusDatasource
        spec: {}
  variables: []
  panels: {}
  layouts: []
EOF
    
    log_warn "Created basic structure - panels, queries, and layouts need manual conversion"
    log_info "See Perses documentation for panel/query structure: https://perses.dev"
}

# Main conversion function
main() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local project_root="$(dirname "$script_dir")"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --input-dir)
                INPUT_DIR="$2"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --datasource-only)
                CONVERT_DASHBOARDS=false
                shift
                ;;
            --dashboard-only)
                CONVERT_DATASOURCES=false
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Check prerequisites
    if ! command -v yq &> /dev/null; then
        log_error "yq is required but not installed"
        exit 1
    fi
    
    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        exit 1
    fi
    
    # Create output directories
    mkdir -p "$OUTPUT_DIR/datasources"
    mkdir -p "$OUTPUT_DIR/dashboards"
    
    log_info "Converting Grafana resources to Perses format..."
    log_info "Input directory: $INPUT_DIR"
    log_info "Output directory: $OUTPUT_DIR"
    
    # Convert datasources
    if [[ "$CONVERT_DATASOURCES" == "true" ]]; then
        log_info "Converting datasources..."
        local count=0
        for file in "$INPUT_DIR"/**/grafana-datasource*.yaml; do
            if [[ -f "$file" ]]; then
                local basename=$(basename "$file" .yaml)
                convert_datasource "$file" "$OUTPUT_DIR/datasources/${basename#grafana-}.yaml"
                ((count++))
            fi
        done
        log_success "Converted $count datasource(s)"
    fi
    
    # Convert dashboards
    if [[ "$CONVERT_DASHBOARDS" == "true" ]]; then
        log_info "Converting dashboards..."
        log_warn "Dashboard conversion creates basic structure only - manual panel/query conversion required"
        local count=0
        for file in "$INPUT_DIR"/**/grafana-dashboard*.yaml; do
            if [[ -f "$file" ]]; then
                local basename=$(basename "$file" .yaml)
                convert_dashboard "$file" "$OUTPUT_DIR/dashboards/${basename#grafana-}.yaml"
                ((count++))
            fi
        done
        log_success "Converted $count dashboard(s) (basic structure)"
    fi
    
    log_success "Conversion complete!"
    log_info "Next steps:"
    log_info "  1. Review converted resources in $OUTPUT_DIR"
    log_info "  2. Manually convert panel definitions (Grafana JSON to Perses panel spec)"
    log_info "  3. Convert queries (Grafana targets to Perses TimeSeriesQuery)"
    log_info "  4. Define layouts (Grafana gridPos to Perses GridLayout)"
    log_info "  5. Test with: oc apply -f $OUTPUT_DIR"
}

main "$@"


