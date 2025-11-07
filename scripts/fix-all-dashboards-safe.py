#!/usr/bin/env python3
"""
Safe dashboard fix script using proper JSON manipulation
Fixes all dashboards by:
1. Adding instant: true to current-value panels (gauge, stat, piechart, table, polystat)
2. Adding sum() aggregation to simple metric queries
3. Adding sum() to division queries
"""

import json
import re
import sys
import glob
import os
from pathlib import Path

CURRENT_VALUE_PANELS = ['gauge', 'stat', 'piechart', 'table', 'grafana-polystat-panel']
METRIC_PATTERN = r'\b([a-z_][a-z0-9_]*(?:_total|_count|_percent|_score))\b'

def extract_json_from_yaml(filepath):
    """Extract JSON from YAML file"""
    with open(filepath, 'r') as f:
        content = f.read()
    
    match = re.search(r'json: \|(.*?)(?=\n---|\Z)', content, re.DOTALL)
    if not match:
        return None, None, None
    
    json_str = match.group(1).strip()
    try:
        return json.loads(json_str), match, content
    except Exception as e:
        return None, None, None

def needs_sum_aggregation(expr):
    """Check if expression needs sum() aggregation"""
    if not expr or not expr.strip():
        return False
    
    # Already has aggregation
    if any(agg in expr for agg in ['sum(', 'avg(', 'max(', 'min(', 'stddev', 'rate(', 'increase(', 'count(']):
        return False
    
    # Is a calculation that should be left alone (unless it has metrics)
    if expr.strip().startswith('100 -'):
        # Check if it contains metrics that need aggregation
        metrics = re.findall(METRIC_PATTERN, expr)
        return len(metrics) > 0
    
    # Simple metric name
    if re.match(r'^[a-z_][a-z0-9_]*$', expr.strip()):
        return True
    
    # Contains metric names that need aggregation
    metrics = re.findall(METRIC_PATTERN, expr)
    if metrics and not any(op in expr for op in ['stddev', 'avg', 'rate']):
        return True
    
    return False

def add_sum_to_expression(expr):
    """Add sum() aggregation to expression"""
    if not expr:
        return expr
    
    # If it's a simple metric, wrap it
    if re.match(r'^[a-z_][a-z0-9_]*$', expr.strip()):
        return f"sum({expr.strip()})"
    
    # For complex expressions, wrap each metric with sum()
    result = expr
    metrics_found = []
    
    # Find all metrics
    for metric_match in re.finditer(METRIC_PATTERN, expr):
        metric = metric_match.group(1)
        if metric not in metrics_found:
            metrics_found.append(metric)
    
    # Replace each metric with sum(metric), working backwards to preserve positions
    for metric in reversed(metrics_found):
        if not metric.startswith('sum(') and not any(f"{agg}(" in metric for agg in ['avg', 'max', 'min', 'stddev']):
            # Replace metric with sum(metric), being careful with word boundaries
            result = re.sub(r'\b' + re.escape(metric) + r'\b', f'sum({metric})', result)
    
    return result

def fix_dashboard_data(data):
    """Fix dashboard data structure"""
    fixes_applied = 0
    
    for panel in data.get('panels', []):
        panel_id = panel.get('id')
        panel_type = panel.get('type', 'unknown')
        
        for target in panel.get('targets', []):
            expr = target.get('expr', '')
            is_instant = target.get('instant', False)
            ref_id = target.get('refId', '')
            
            # Fix 1: Add instant: true to current-value panels
            if panel_type in CURRENT_VALUE_PANELS and not is_instant:
                target['instant'] = True
                fixes_applied += 1
                print(f"    ✅ Panel {panel_id} ({ref_id}): Added instant=true")
            
            # Fix 2: Add sum() aggregation
            if needs_sum_aggregation(expr):
                new_expr = add_sum_to_expression(expr)
                if new_expr != expr:
                    target['expr'] = new_expr
                    fixes_applied += 1
                    print(f"    ✅ Panel {panel_id} ({ref_id}): Added sum() to query")
    
    return fixes_applied

def fix_dashboard(filepath):
    """Fix a dashboard file"""
    dashboard_name = os.path.basename(filepath).replace('.yaml', '')
    
    data, match_obj, original_content = extract_json_from_yaml(filepath)
    if not data:
        print(f"  ❌ Could not parse dashboard")
        return False
    
    print(f"  Fixing {len(data.get('panels', []))} panels...")
    fixes_applied = fix_dashboard_data(data)
    
    if fixes_applied > 0:
        # Reconstruct the YAML file
        json_str = json.dumps(data, indent=2)
        
        # Replace the JSON section in the original content
        new_content = re.sub(
            r'json: \|(.*?)(?=\n---|\Z)',
            f'json: |\n    {json_str.replace(chr(10), chr(10) + "    ")}',
            original_content,
            flags=re.DOTALL
        )
        
        # Write fixed content
        with open(filepath, 'w') as f:
            f.write(new_content)
        
        print(f"  ✅ Applied {fixes_applied} fix(es)")
        return True
    else:
        print(f"  ℹ️  No fixes needed")
        return False

def main():
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    dashboard_dir = project_root / 'k8s' / 'grafana'
    
    dashboard_files = sorted(glob.glob(str(dashboard_dir / 'grafana-dashboard*.yaml')))
    
    print("=== Safe Dashboard Fix Script ===")
    print(f"Found {len(dashboard_files)} dashboard files\n")
    
    fixed_count = 0
    for dashboard_file in dashboard_files:
        dashboard_name = os.path.basename(dashboard_file).replace('.yaml', '')
        print(f"\n{dashboard_name}:")
        if fix_dashboard(dashboard_file):
            fixed_count += 1
    
    print(f"\n=== Summary ===")
    print(f"Fixed {fixed_count} out of {len(dashboard_files)} dashboards")

if __name__ == '__main__':
    main()

