#!/usr/bin/env python3
"""
Proper dashboard fix script using JSON manipulation
Safely fixes dashboards without breaking JSON structure
"""

import json
import re
import sys
import os
from pathlib import Path

CURRENT_VALUE_PANELS = ['gauge', 'stat', 'piechart', 'table', 'grafana-polystat-panel']
METRIC_PATTERN = r'\b([a-z_][a-z0-9_]*(?:_total|_count|_percent|_score))\b'

def needs_sum_aggregation(expr):
    """Check if expression needs sum() aggregation"""
    if not expr or not expr.strip():
        return False
    
    # Already has aggregation
    if any(agg in expr for agg in ['sum(', 'avg(', 'max(', 'min(', 'stddev', 'rate(', 'increase(', 'count(', 'sum by']):
        return False
    
    # Simple metric name
    if re.match(r'^[a-z_][a-z0-9_]*$', expr.strip()):
        return True
    
    # Contains metric names that need aggregation (but not in calculations with functions)
    if not any(op in expr for op in ['stddev', 'avg_over_time', 'stddev_over_time']):
        metrics = re.findall(METRIC_PATTERN, expr)
        if metrics:
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
    
    # Replace each metric with sum(metric), working backwards
    for metric in reversed(metrics_found):
        if not metric.startswith('sum(') and not any(f"{agg}(" in metric for agg in ['avg', 'max', 'min', 'stddev']):
            result = re.sub(r'\b' + re.escape(metric) + r'\b', f'sum({metric})', result)
    
    return result

def fix_dashboard_file(filepath):
    """Fix a dashboard file properly"""
    dashboard_name = os.path.basename(filepath).replace('.yaml', '')
    
    # Read file
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Extract JSON
    match = re.search(r'json: \|(.*?)(?=\n---|\Z)', content, re.DOTALL)
    if not match:
        print(f"  ❌ Could not find JSON section")
        return False
    
    json_str = match.group(1).strip()
    
    try:
        data = json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"  ❌ JSON parse error: {e}")
        return False
    
    fixes_applied = 0
    
    # Fix panels
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
    
    if fixes_applied > 0:
        # Reconstruct JSON with proper indentation
        json_str_fixed = json.dumps(data, indent=2)
        
        # Replace JSON section - maintain YAML structure
        # The JSON needs to be indented to match YAML
        indented_json = '\n'.join('    ' + line if line.strip() else line for line in json_str_fixed.split('\n'))
        
        new_content = content[:match.start()] + 'json: |\n' + indented_json + '\n' + content[match.end():]
        
        # Write back
        with open(filepath, 'w') as f:
            f.write(new_content)
        
        print(f"  ✅ Applied {fixes_applied} fix(es)")
        return True
    else:
        print(f"  ℹ️  No fixes needed")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: fix-dashboard-proper.py <dashboard-file>")
        sys.exit(1)
    
    filepath = sys.argv[1]
    if not os.path.exists(filepath):
        print(f"Error: File not found: {filepath}")
        sys.exit(1)
    
    print(f"Fixing: {os.path.basename(filepath)}")
    fix_dashboard_file(filepath)

if __name__ == '__main__':
    main()

