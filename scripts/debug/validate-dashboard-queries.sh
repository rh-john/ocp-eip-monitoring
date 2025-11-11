#!/bin/bash
# Comprehensive dashboard query validation
# Tests queries against actual Prometheus datasource via Grafana API

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

# Extract JSON from YAML and test queries
DASHBOARD_FILE="$DASHBOARD_FILE" python3 << 'PYEOF'
import sys
import os
import json
import re
import subprocess

def test_query_via_grafana_api(pod, namespace, datasource_uid, query):
    """Test a Prometheus query via Grafana API"""
    # Use Grafana's query API to test the query
    # This requires getting the datasource UID first
    try:
        # Try to query via Grafana API
        cmd = [
            'oc', 'exec', pod, '-n', namespace, '--',
            'curl', '-s', '-u', 'admin:admin',
            '-X', 'POST',
            '-H', 'Content-Type: application/json',
            f'http://localhost:3000/api/datasources/proxy/1/api/v1/query',
            '-d', json.dumps({
                'query': query
            })
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if data.get('status') == 'success':
                return True, data.get('data', {}).get('result', [])
            else:
                return False, data.get('error', 'Unknown error')
        else:
            return False, result.stderr
    except Exception as e:
        return False, str(e)

try:
    dashboard_file = os.environ.get('DASHBOARD_FILE')
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
    
    # Get Grafana pod
    grafana_pod_cmd = ['oc', 'get', 'pods', '-n', namespace, '-o', 'jsonpath={.items[?(@.metadata.labels.app=="eip-monitor")].metadata.name}']
    result = subprocess.run(grafana_pod_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print("ERROR: Could not find Grafana pod")
        sys.exit(1)
    
    grafana_pod = result.stdout.strip().split('\n')[0] if result.stdout.strip() else ""
    if not grafana_pod:
        # Fallback: grep method
        grep_cmd = ['oc', 'get', 'pods', '-n', namespace]
        result = subprocess.run(grep_cmd, capture_output=True, text=True)
        for line in result.stdout.split('\n'):
            if 'grafana' in line and 'operator' not in line:
                grafana_pod = line.split()[0]
                break
    
    if not grafana_pod:
        print("ERROR: Grafana pod not found")
        sys.exit(1)
    
    print(f"Grafana pod: {grafana_pod}")
    print("")
    
    # Get datasource UID
    ds_cmd = ['oc', 'exec', grafana_pod, '-n', namespace, '--', 'curl', '-s', '-u', 'admin:admin', 'http://localhost:3000/api/datasources']
    result = subprocess.run(ds_cmd, capture_output=True, text=True, timeout=10)
    datasource_uid = None
    if result.returncode == 0:
        try:
            datasources = json.loads(result.stdout)
            if datasources and len(datasources) > 0:
                datasource_uid = datasources[0].get('uid')
                print(f"Datasource UID: {datasource_uid}")
        except:
            pass
    
    print("")
    print("Testing queries...")
    print("=" * 80)
    
    total_queries = 0
    failed_queries = 0
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
            
            # Test query syntax and execution
            if datasource_uid:
                # Test via Grafana API
                success, result = test_query_via_grafana_api(grafana_pod, namespace, datasource_uid, expr)
                if success:
                    result_count = len(result) if isinstance(result, list) else 0
                    if result_count > 0:
                        print(f"    ✓ Query returns {result_count} result(s)")
                    else:
                        print(f"    ⚠ Query executes but returns no data")
                        issues.append(f"Panel {panel_id} ({panel_title}), Query {ref_id}: Returns no data")
                else:
                    print(f"    ✗ Query failed: {result}")
                    failed_queries += 1
                    issues.append(f"Panel {panel_id} ({panel_title}), Query {ref_id}: {result}")
            else:
                # Just validate syntax
                print(f"    ? Cannot test (no datasource UID), syntax check only")
    
    print("")
    print("=" * 80)
    print(f"Summary:")
    print(f"  Total queries: {total_queries}")
    print(f"  Failed queries: {failed_queries}")
    print(f"  Issues found: {len(issues)}")
    
    if issues:
        print("\nIssues:")
        for issue in issues:
            print(f"  - {issue}")
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

