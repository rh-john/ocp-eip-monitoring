#!/usr/bin/env python3
"""
Add Prometheus inspect links to Perses dashboard panels.
This script adds an "Inspect in Prometheus" link to each panel that uses
the first Prometheus query from the panel.
"""

import os
import sys
import yaml
import urllib.parse
from pathlib import Path

# Prometheus/ThanosQuerier URL for inspect links
PROMETHEUS_URL = "http://thanos-querier-eip-monitoring-stack-querier-coo.eip-monitoring.svc.cluster.local:10902/graph"

def url_encode_query(query):
    """URL encode a Prometheus query for use in the graph URL."""
    # Prometheus expects the query parameter to be URL encoded
    return urllib.parse.quote(query, safe='')

def get_first_prometheus_query(panel_spec):
    """Extract the first Prometheus query from a panel."""
    queries = panel_spec.get('queries', [])
    for query in queries:
        query_spec = query.get('spec', {})
        plugin = query_spec.get('plugin', {})
        plugin_spec = plugin.get('spec', {})
        
        # Check if this is a Prometheus query
        if plugin.get('kind') == 'PrometheusTimeSeriesQuery':
            prom_query = plugin_spec.get('query', '')
            if prom_query:
                return prom_query
    return None

def add_inspect_link_to_panel(panel_spec, prometheus_url):
    """Add an inspect link to a panel if it has Prometheus queries."""
    # Check if links already exist
    if 'links' in panel_spec:
        # Check if inspect link already exists
        for link in panel_spec.get('links', []):
            if link.get('title') == 'Inspect in Prometheus':
                return False  # Already has inspect link
    
    # Get the first Prometheus query
    query = get_first_prometheus_query(panel_spec)
    if not query:
        return False  # No Prometheus query found
    
    # Create the inspect link URL
    encoded_query = url_encode_query(query)
    inspect_url = f"{prometheus_url}?g0.expr={encoded_query}&g0.tab=0"
    
    # Add the link
    if 'links' not in panel_spec:
        panel_spec['links'] = []
    
    panel_spec['links'].append({
        'title': 'Inspect in Prometheus',
        'url': inspect_url,
        'tooltip': 'View query in Prometheus'
    })
    
    return True

def process_dashboard_file(file_path, prometheus_url):
    """Process a single dashboard YAML file."""
    try:
        with open(file_path, 'r') as f:
            dashboard = yaml.safe_load(f)
        
        if dashboard.get('kind') != 'PersesDashboard':
            print(f"  ⚠️  Skipping {file_path.name}: not a PersesDashboard")
            return False
        
        panels = dashboard.get('spec', {}).get('panels', {})
        if not panels:
            print(f"  ⚠️  Skipping {file_path.name}: no panels found")
            return False
        
        updated_count = 0
        for panel_name, panel in panels.items():
            panel_spec = panel.get('spec', {})
            if add_inspect_link_to_panel(panel_spec, prometheus_url):
                updated_count += 1
        
        if updated_count > 0:
            # Write the updated dashboard
            with open(file_path, 'w') as f:
                yaml.dump(dashboard, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
            print(f"  ✓ Updated {updated_count} panel(s) in {file_path.name}")
            return True
        else:
            print(f"  ⊘ No updates needed for {file_path.name}")
            return False
            
    except Exception as e:
        print(f"  ✗ Error processing {file_path.name}: {e}")
        return False

def main():
    """Main function to process all dashboard files."""
    if len(sys.argv) > 1:
        dashboard_dir = Path(sys.argv[1])
    else:
        # Default to the perses dashboards directory
        script_dir = Path(__file__).parent
        project_root = script_dir.parent
        dashboard_dir = project_root / 'k8s' / 'monitoring' / 'coo' / 'perses' / 'dashboards'
    
    if not dashboard_dir.exists():
        print(f"Error: Dashboard directory not found: {dashboard_dir}")
        sys.exit(1)
    
    print(f"Processing dashboards in: {dashboard_dir}")
    print(f"Prometheus URL: {PROMETHEUS_URL}")
    print()
    
    dashboard_files = list(dashboard_dir.glob('*.yaml'))
    if not dashboard_files:
        print("No dashboard files found")
        sys.exit(0)
    
    updated_files = 0
    for dashboard_file in sorted(dashboard_files):
        if process_dashboard_file(dashboard_file, PROMETHEUS_URL):
            updated_files += 1
    
    print()
    if updated_files > 0:
        print(f"✓ Successfully updated {updated_files} dashboard file(s)")
    else:
        print("No dashboards needed updates")

if __name__ == '__main__':
    main()


