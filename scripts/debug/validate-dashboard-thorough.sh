#!/bin/bash
# Thorough dashboard validation - tests queries via Grafana API and checks metric availability

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

# Extract queries and test them
DASHBOARD_FILE="$DASHBOARD_FILE" GRAFANA_POD="$GRAFANA_POD" NAMESPACE="$NAMESPACE" python3 << 'PYEOF'
import sys
import os
import json
import re
import subprocess

def test_query_via_grafana(pod, namespace, query):
    """Test query via Grafana's datasource proxy"""
    try:
        # Get datasource UID first
        ds_cmd = ['oc', 'exec', pod, '-n', namespace, '--', 'curl', '-s', '-u', 'admin:admin', 'http://localhost:3000/api/datasources']
        result = subprocess.run(ds_cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return False, [], "Could not get datasource"
        
        datasources = json.loads(result.stdout)
        datasource_uid = None
        for ds in datasources:
            if ds.get('type') == 'prometheus' and ds.get('isDefault'):
                datasource_uid = ds.get('uid')
                break
        
        if not datasource_uid:
            return False, [], "No Prometheus datasource found"
        
        # Test query via Grafana datasource proxy
        # Format: POST /api/datasources/uid/{uid}/query
        url = f'http://localhost:3000/api/datasources/uid/{datasource_uid}/query'
        payload = {
            'queries': [{
                'refId': 'A',
                'expr': query,
                'datasource': {'uid': datasource_uid, 'type': 'prometheus'},
                'queryType': '',
                'model': {'expr': query}
            }],
            'from': 'now-1h',
            'to': 'now'
        }
        
        cmd = [
            'oc', 'exec', pod, '-n', namespace, '--',
            'curl', '-s', '-u', 'admin:admin',
            '-X', 'POST',
            '-H', 'Content-Type: application/json',
            url,
            '-d', json.dumps(payload)
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        
        if result.returncode == 0:
            try:
                data = json.loads(result.stdout)
                # Grafana query API returns results in different formats
                if isinstance(data, list):
                    if len(data) > 0 and 'data' in data[0]:
                        results = data[0].get('data', {}).get('result', [])
                        return True, results, None
                elif isinstance(data, dict):
                    if 'results' in data:
                        # New format
                        results_list = data.get('results', {}).get('A', {}).get('frames', [])
                        if results_list:
                            return True, results_list, None
                    elif 'data' in data:
                        results = data.get('data', {}).get('result', [])
                        return True, results, None
                    elif data.get('status') == 'success':
                        results = data.get('data', {}).get('result', [])
                        return True, results, None
                    else:
                        error = data.get('error', data.get('message', 'Unknown error'))
                        return False, [], error
                return True, [], None
            except json.JSONDecodeError as e:
                return False, [], f"Invalid JSON: {result.stdout[:200]}"
        else:
            return False, [], result.stderr or result.stdout[:200]
    except subprocess.TimeoutExpired:
        return False, [], "Query timeout"
    except Exception as e:
        return False, [], str(e)

def extract_metric_names(expr):
    """Extract metric names from PromQL expression"""
    # Simple regex to find metric names (alphanumeric + underscores)
    metrics = re.findall(r'\b([a-z_][a-z0-9_]*)\s*\{', expr, re.IGNORECASE)
    return list(set(metrics))

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
    
    print("Testing queries via Grafana datasource...")
    print("=" * 80)
    
    total_queries = 0
    failed_queries = 0
    no_data_queries = 0
    issues = []
    metric_issues = {}
    
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
            
            # Extract metric names
            metrics = extract_metric_names(expr)
            
            # Test query
            success, results, error = test_query_via_grafana(grafana_pod, namespace, expr)
            if success:
                # Check if we got results
                result_count = 0
                if isinstance(results, list):
                    result_count = len(results)
                elif isinstance(results, dict):
                    result_count = 1 if results else 0
                
                if result_count > 0:
                    print(f"    ✓ Query returns {result_count} result(s)")
                else:
                    print(f"    ⚠ Query executes but returns no data")
                    no_data_queries += 1
                    issue_msg = f"Panel {panel_id} ({panel_title}), Query {ref_id}: Returns no data"
                    if metrics:
                        issue_msg += f" (metrics: {', '.join(metrics[:3])})"
                    issues.append(issue_msg)
                    
                    # Track metric issues
                    for metric in metrics:
                        if metric not in metric_issues:
                            metric_issues[metric] = []
                        metric_issues[metric].append(f"Panel {panel_id} ({panel_title})")
            else:
                print(f"    ✗ Query failed: {error}")
                failed_queries += 1
                issue_msg = f"Panel {panel_id} ({panel_title}), Query {ref_id}: {error}"
                if metrics:
                    issue_msg += f" (metrics: {', '.join(metrics[:3])})"
                issues.append(issue_msg)
    
    print("")
    print("=" * 80)
    print(f"Summary:")
    print(f"  Total queries: {total_queries}")
    print(f"  Failed queries: {failed_queries}")
    print(f"  Queries with no data: {no_data_queries}")
    print(f"  Issues found: {len(issues)}")
    
    if metric_issues:
        print("\nMetrics with issues:")
        for metric, panels in list(metric_issues.items())[:10]:
            print(f"  {metric}: used in {len(panels)} panel(s)")
    
    if issues:
        print("\nIssues:")
        for issue in issues[:30]:  # Limit to first 30
            print(f"  - {issue}")
        if len(issues) > 30:
            print(f"  ... and {len(issues) - 30} more issues")
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

