#!/usr/bin/env python3
"""
Fix table panels with multiple targets by adding merge transformation
"""

import json
import re
import sys
import os

def fix_table_panel(filepath, panel_id):
    """Add merge transformation to a table panel"""
    with open(filepath, 'r') as f:
        content = f.read()
    
    match = re.search(r'json: \|(.*?)(?=\n---|\Z)', content, re.DOTALL)
    if not match:
        return False
    
    json_str = match.group(1).strip()
    data = json.loads(json_str)
    
    fixed = False
    for panel in data.get('panels', []):
        if panel.get('id') == panel_id and panel.get('type') == 'table':
            targets = panel.get('targets', [])
            transformations = panel.get('transformations', [])
            
            if len(targets) > 1:
                # Check if merge transformation exists
                has_merge = any(t.get('id') == 'merge' for t in transformations)
                
                if not has_merge:
                    # Add merge transformation
                    if not transformations:
                        panel['transformations'] = []
                    
                    # Add merge at the beginning
                    panel['transformations'].insert(0, {
                        "id": "merge",
                        "options": {}
                    })
                    
                    fixed = True
                    print(f"    ✅ Panel {panel_id}: Added merge transformation")
    
    if fixed:
        # Reconstruct JSON
        json_str_fixed = json.dumps(data, indent=2)
        indented_json = '\n'.join('    ' + line if line.strip() else line for line in json_str_fixed.split('\n'))
        new_content = content[:match.start()] + 'json: |\n' + indented_json + '\n' + content[match.end():]
        
        with open(filepath, 'w') as f:
            f.write(new_content)
        
        return True
    
    return False

# Fix all identified panels
panels_to_fix = [
    ('k8s/grafana/dashboards/grafana-dashboard-eip-distribution.yaml', 8),
    ('k8s/grafana/dashboards/grafana-dashboard-cpic-health.yaml', 8),
    ('k8s/grafana/dashboards/grafana-dashboard-eip-timeline.yaml', 9),
    ('k8s/grafana/dashboards/grafana-dashboard-event-correlation.yaml', 14),
    ('k8s/grafana/dashboards/grafana-dashboard-node-performance.yaml', 8),
]

print("=== Fixing Table Panels with Multiple Targets ===\n")

for filepath, panel_id in panels_to_fix:
    if os.path.exists(filepath):
        print(f"Fixing {os.path.basename(filepath)} - Panel {panel_id}:")
        fix_table_panel(filepath, panel_id)
    else:
        print(f"⚠️  File not found: {filepath}")

print("\n✅ All table panels fixed!")

