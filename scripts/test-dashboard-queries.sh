#!/bin/bash
# Test dashboard queries against actual Prometheus via Grafana API
# This script actually executes queries and reports errors

set -euo pipefail

NAMESPACE="${NAMESPACE:-eip-monitoring}"
DASHBOARD_FILE="${1:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ -z "$DASHBOARD_FILE" ]]; then
    log_error "Usage: $0 <dashboard-file.yaml>"
    exit 1
fi

if [[ ! -f "$DASHBOARD_FILE" ]]; then
    log_error "Dashboard file not found: $DASHBOARD_FILE"
    exit 1
fi

# Check if Grafana instance exists
if ! oc get grafana -n "$NAMESPACE" &>/dev/null; then
    log_error "Grafana instance not found in namespace '$NAMESPACE'"
    exit 1
fi

# Get Grafana pod
GRAFANA_POD=$(oc get pods -n "$NAMESPACE" | grep grafana | grep -v operator | awk '{print $1}' | head -1)
if [[ -z "$GRAFANA_POD" ]]; then
    log_error "Grafana pod not found"
    exit 1
fi

log_info "Using Grafana pod: $GRAFANA_POD"
log_info "Testing dashboard: $DASHBOARD_FILE"
echo ""

# Extract and test queries
DASHBOARD_FILE="$DASHBOARD_FILE" GRAFANA_POD="$GRAFANA_POD" NAMESPACE="$NAMESPACE" python3 << 'PYEOF'
import sys
import os
import json
import re
import subprocess

def get_datasource_uid(pod, namespace):
    """Get the default Prometheus datasource UID"""
    try:
        cmd = ['oc', 'exec', pod, '-n', namespace, '--', 'curl', '-s', '-u', 'admin:admin', 'http://localhost:3000/api/datasources']
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            datasources = json.loads(result.stdout)
            if datasources and len(datasources) > 0:
                # Find Prometheus datasource
                for ds in datasources:
                    if ds.get('type') == 'prometheus':
                        return ds.get('uid')
        return None
    except Exception as e:
        return None

def test_query_via_prometheus(pod, namespace, query):
    """Test query directly via Prometheus API"""
    try:
        # URL encode the query
        import urllib.parse
        encoded_query = urllib.parse.quote(query)
        url = f'http://localhost:9090/api/v1/query?query={encoded_query}'
        
        cmd = [
            'oc', 'exec', pod, '-n', namespace, '--',
            'curl', '-s', url
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        
        if result.returncode == 0:
            try:
                data = json.loads(result.stdout)
                if data.get('status') == 'success':
                    results = data.get('data', {}).get('result', [])
                    return True, results, None
                else:
                    error_obj = data.get('error', {})
                    if isinstance(error_obj, dict):
                        error = error_obj.get('error', 'Unknown error')
                        error_type = error_obj.get('errorType', '')
                        return False, [], f"{error_type}: {error}" if error_type else error
                    else:
                        return False, [], str(error_obj) if error_obj else 'Unknown error'
            except json.JSONDecodeError:
                return False, [], f"Invalid JSON: {result.stdout[:200]}"
        else:
            return False, [], result.stderr or result.stdout
    except subprocess.TimeoutExpired:
        return False, [], "Query timeout"
    except Exception as e:
        return False, [], str(e)

def find_prometheus_pod(namespace):
    """Find Prometheus or Thanos Querier pod"""
    # Try to find Prometheus pod
    cmd = ['oc', 'get', 'pods', '-n', namespace, '-o', 'json']
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if result.returncode == 0:
        pods = json.loads(result.stdout)
        for pod in pods.get('items', []):
            name = pod.get('metadata', {}).get('name', '')
            labels = pod.get('metadata', {}).get('labels', {})
            # Look for Prometheus or Thanos Querier
            if 'prometheus' in name.lower() or 'thanos-querier' in name.lower():
                if pod.get('status', {}).get('phase') == 'Running':
                    return name
    return None

try:
    dashboard_file = os.environ.get('DASHBOARD_FILE')
    grafana_pod = os.environ.get('GRAFANA_POD')
    namespace = os.environ.get('NAMESPACE', 'eip-monitoring')
    
    with open(dashboard_file, 'r') as f:
        content = f.read()
    
    # Extract JSON from YAML
    match = re.search(r'json: \|(.*?)(?=\n---|\Z)', content, re.DOTALL)
    if not match:
        print("ERROR: Could not extract JSON from YAML")
        sys.exit(1)
    
    json_str = match.group(1).strip()
    data = json.loads(json_str)
    
    dashboard_name = data.get('title', 'Unknown')
    print(f"Dashboard: {dashboard_name}")
    print(f"Panels: {len(data.get('panels', []))}")
    print("")
    
    # Get datasource UID
    print("Getting Prometheus datasource...")
    datasource_uid = get_datasource_uid(grafana_pod, namespace)
    if not datasource_uid:
        print("WARNING: Could not get datasource UID, will test queries directly via Prometheus API")
        datasource_uid = None
    else:
        print(f"Datasource UID: {datasource_uid}")
    
    print("")
    print("Testing queries...")
    print("=" * 80)
    
    total_queries = 0
    failed_queries = 0
    no_data_queries = 0
    issues = []
    
    for panel in data.get('panels', []):
        panel_id = panel.get('id')
        panel_title = panel.get('title', 'Unknown')
        panel_type = panel.get('type', 'unknown')
        
        print(f"\nPanel {panel_id}: {panel_title} ({panel_type})")
        
        for target in panel.get('targets', []):
            expr = target.get('expr', '')
            ref_id = target.get('refId', '')
            instant = target.get('instant', False)
            
            if not expr:
                continue
            
            total_queries += 1
            print(f"  Query {ref_id}: {expr[:70]}...")
            
            # Try to find Prometheus/Thanos pod and test directly
            prom_pod = find_prometheus_pod(namespace)
            if not prom_pod:
                # Try COO namespace
                prom_pod = find_prometheus_pod('eip-monitoring')
            
            if prom_pod:
                success, results, error = test_query_via_prometheus(prom_pod, namespace, expr)
                if success:
                    result_count = len(results) if isinstance(results, list) else 0
                    if result_count > 0:
                        print(f"    ✓ Query returns {result_count} result(s)")
                    else:
                        print(f"    ⚠ Query executes but returns no data")
                        no_data_queries += 1
                        issues.append(f"Panel {panel_id} ({panel_title}), Query {ref_id}: Returns no data - {expr[:60]}")
                else:
                    print(f"    ✗ Query failed: {error}")
                    failed_queries += 1
                    issues.append(f"Panel {panel_id} ({panel_title}), Query {ref_id}: {error} - {expr[:60]}")
            else:
                print(f"    ? Could not test (no Prometheus/Thanos pod found)")
                issues.append(f"Panel {panel_id} ({panel_title}), Query {ref_id}: Cannot test - no Prometheus pod")
    
    print("")
    print("=" * 80)
    print(f"Summary:")
    print(f"  Total queries: {total_queries}")
    print(f"  Failed queries: {failed_queries}")
    print(f"  Queries with no data: {no_data_queries}")
    print(f"  Issues found: {len(issues)}")
    
    if issues:
        print("\nIssues:")
        for issue in issues[:20]:  # Limit to first 20
            print(f"  - {issue}")
        if len(issues) > 20:
            print(f"  ... and {len(issues) - 20} more issues")
        sys.exit(1)
    else:
        print("\n✓ All queries validated successfully!")
        sys.exit(0)
    
except Exception as e:
    print(f"ERROR: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYEOF

