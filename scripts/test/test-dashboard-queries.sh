#!/bin/bash
# Test dashboard queries against actual Prometheus via Grafana API
# This script actually executes queries and reports errors

set -euo pipefail

# Source common functions (logging, prerequisites)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go up from scripts/test to get project root
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "${PROJECT_ROOT}/scripts/lib/common.sh"

NAMESPACE="${NAMESPACE:-eip-monitoring}"
DASHBOARD_FILE="${1:-}"

if [[ -z "$DASHBOARD_FILE" ]]; then
    log_error "Usage: $0 <dashboard-file.yaml>"
    exit 1
fi

if [[ ! -f "$DASHBOARD_FILE" ]]; then
    log_error "Dashboard file not found: $DASHBOARD_FILE"
    exit 1
fi

# Check prerequisites
if ! check_prerequisites; then
    log_error "Prerequisites check failed"
    exit 1
fi

# Check if Grafana instance exists
if ! oc get grafana -n "$NAMESPACE" &>/dev/null; then
    log_error "Grafana instance not found in namespace '$NAMESPACE'"
    exit 1
fi

# Get Grafana pod using common function
GRAFANA_POD=$(find_grafana_pod "$NAMESPACE" "true")  # Only return running pods

if [[ -z "$GRAFANA_POD" ]]; then
    log_error "Grafana pod not found (or not running)"
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
    """Find Prometheus or Thanos Querier pod using common.sh logic"""
    # Try COO-specific labels first (most reliable for COO)
    cmd = ['oc', 'get', 'pods', '-n', namespace, '-l', 
           'app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier',
           '-o', 'jsonpath={.items[0].metadata.name}']
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if result.returncode == 0 and result.stdout.strip():
        pod_name = result.stdout.strip()
        # Verify pod is running
        phase_cmd = ['oc', 'get', 'pod', pod_name, '-n', namespace, '-o', 'jsonpath={.status.phase}']
        phase_result = subprocess.run(phase_cmd, capture_output=True, text=True, timeout=10)
        if phase_result.returncode == 0 and phase_result.stdout.strip() == 'Running':
            return pod_name
    
    # Fallback: standard Thanos label
    cmd = ['oc', 'get', 'pods', '-n', namespace, '-l', 
           'app.kubernetes.io/name=thanos-query',
           '-o', 'jsonpath={.items[0].metadata.name}']
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if result.returncode == 0 and result.stdout.strip():
        pod_name = result.stdout.strip()
        phase_cmd = ['oc', 'get', 'pod', pod_name, '-n', namespace, '-o', 'jsonpath={.status.phase}']
        phase_result = subprocess.run(phase_cmd, capture_output=True, text=True, timeout=10)
        if phase_result.returncode == 0 and phase_result.stdout.strip() == 'Running':
            return pod_name
    
    # Fallback: Prometheus pod (COO-specific labels)
    cmd = ['oc', 'get', 'pods', '-n', namespace, '-l',
           'app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/name=prometheus',
           '-o', 'jsonpath={.items[0].metadata.name}']
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if result.returncode == 0 and result.stdout.strip():
        pod_name = result.stdout.strip()
        phase_cmd = ['oc', 'get', 'pod', pod_name, '-n', namespace, '-o', 'jsonpath={.status.phase}']
        phase_result = subprocess.run(phase_cmd, capture_output=True, text=True, timeout=10)
        if phase_result.returncode == 0 and phase_result.stdout.strip() == 'Running':
            return pod_name
    
    # Fallback: standard Prometheus label
    cmd = ['oc', 'get', 'pods', '-n', namespace, '-l',
           'app.kubernetes.io/name=prometheus',
           '-o', 'jsonpath={.items[0].metadata.name}']
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if result.returncode == 0 and result.stdout.strip():
        pod_name = result.stdout.strip()
        phase_cmd = ['oc', 'get', 'pod', pod_name, '-n', namespace, '-o', 'jsonpath={.status.phase}']
        phase_result = subprocess.run(phase_cmd, capture_output=True, text=True, timeout=10)
        if phase_result.returncode == 0 and phase_result.stdout.strip() == 'Running':
            return pod_name
    
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
                # Determine port based on pod name (ThanosQuerier uses 10902, Prometheus uses 9090)
                port = '10902' if 'thanos' in prom_pod.lower() or 'querier' in prom_pod.lower() else '9090'
                success, results, error = test_query_via_prometheus(prom_pod, namespace, expr, port)
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

