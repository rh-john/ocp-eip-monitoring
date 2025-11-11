#!/usr/bin/env python3
"""
Comprehensive dashboard fix script
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
        return None, None
    
    json_str = match.group(1).strip()
    try:
        return json.loads(json_str), match
    except Exception as e:
        print(f"  Error parsing JSON: {e}")
        return None, None

def needs_sum_aggregation(expr):
    """Check if expression needs sum() aggregation"""
    if not expr or not expr.strip():
        return False
    
    # Already has aggregation
    if any(agg in expr for agg in ['sum(', 'avg(', 'max(', 'min(', 'stddev', 'rate(', 'increase(', 'count(']):
        return False
    
    # Is a calculation that should be left alone
    if expr.strip().startswith('100 -') or expr.strip().startswith('('):
        # Check if it's a complex calculation
        if expr.count('(') > 1 or expr.count('/') > 0:
            # Division queries need sum() on metrics
            metrics = re.findall(METRIC_PATTERN, expr)
            if metrics:
                return True
        return False
    
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
    
    # For division queries, wrap each metric with sum()
    # Pattern: (metric1 / metric2) or (metric1 / (metric2 + metric3))
    def wrap_metric(match):
        metric = match.group(1)
        # Don't wrap if already wrapped or if it's a function
        if metric.startswith('sum(') or metric.startswith('avg('):
            return match.group(0)
        return f"sum({metric})"
    
    # Find all metrics and wrap them
    result = expr
    for metric_match in re.finditer(METRIC_PATTERN, expr):
        metric = metric_match.group(1)
        if not metric.startswith('sum(') and not any(f"{agg}(" in metric for agg in ['avg', 'max', 'min', 'stddev']):
            result = result.replace(metric, f"sum({metric})", 1)
    
    return result

def fix_dashboard(filepath):
    """Fix a dashboard file"""
    dashboard_name = os.path.basename(filepath).replace('.yaml', '')
    print(f"\nFixing: {dashboard_name}")
    
    data, match_obj = extract_json_from_yaml(filepath)
    if not data:
        print(f"  ❌ Could not parse dashboard")
        return False
    
    fixes_applied = 0
    
    # Read original file
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Fix each panel
    for panel in data.get('panels', []):
        panel_id = panel.get('id')
        panel_type = panel.get('type', 'unknown')
        
        for target in panel.get('targets', []):
            expr = target.get('expr', '')
            is_instant = target.get('instant', False)
            ref_id = target.get('refId', '')
            
            # Fix 1: Add instant: true to current-value panels
            if panel_type in CURRENT_VALUE_PANELS and not is_instant:
                # Find the target in the YAML and add instant: true
                pattern = rf'"refId":\s*"{re.escape(ref_id)}"'
                if re.search(pattern, content):
                    # Add instant: true after refId
                    replacement = f'"refId": "{ref_id}",\n              "instant": true'
                    content = re.sub(pattern + r'(?:\s*,)?', replacement, content)
                    fixes_applied += 1
                    print(f"  ✅ Panel {panel_id}: Added instant=true")
            
            # Fix 2: Add sum() aggregation
            if needs_sum_aggregation(expr):
                new_expr = add_sum_to_expression(expr)
                if new_expr != expr:
                    # Replace in content
                    escaped_expr = re.escape(expr)
                    content = re.sub(rf'"expr":\s*"{escaped_expr}"', f'"expr": "{new_expr}"', content)
                    fixes_applied += 1
                    print(f"  ✅ Panel {panel_id} ({ref_id}): Added sum() to query")
    
    # Write fixed content
    if fixes_applied > 0:
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"  ✅ Applied {fixes_applied} fix(es)")
        return True
    else:
        print(f"  ℹ️  No fixes needed")
        return False

def main():
    script_dir = Path(__file__).parent
    project_root = script_dir.parent
    dashboard_dir = project_root / 'k8s' / 'grafana' / 'dashboards'
    
    dashboard_files = sorted(glob.glob(str(dashboard_dir / 'grafana-dashboard*.yaml')))
    
    print("=== Comprehensive Dashboard Fix Script ===")
    print(f"Found {len(dashboard_files)} dashboard files\n")
    
    fixed_count = 0
    for dashboard_file in dashboard_files:
        if fix_dashboard(dashboard_file):
            fixed_count += 1
    
    print(f"\n=== Summary ===")
    print(f"Fixed {fixed_count} out of {len(dashboard_files)} dashboards")

if __name__ == '__main__':
    main()

