#!/bin/bash
# Comprehensive validation script for ALL Grafana dashboards
# Checks for: duplicate values, query errors, missing aggregations, instant query configuration

set -euo pipefail

NAMESPACE="${NAMESPACE:-eip-monitoring}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'  # Light blue (cyan)
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== Comprehensive Dashboard Validation ==="
echo ""

# Find all dashboard files
DASHBOARD_FILES=("$PROJECT_ROOT/k8s/grafana/grafana-dashboard"*.yaml)
TOTAL_DASHBOARDS=${#DASHBOARD_FILES[@]}

log_info "Found $TOTAL_DASHBOARDS dashboard files"

ISSUES_FOUND=0
FIXES_NEEDED=0

for dashboard_file in "${DASHBOARD_FILES[@]}"; do
    dashboard_name=$(basename "$dashboard_file" .yaml)
    log_info ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Validating: $dashboard_name"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Extract JSON from YAML
    if ! python3 << 'PYEOF'
import sys
import json
import re

try:
    with open(sys.argv[1], 'r') as f:
        content = f.read()
    
    # Extract JSON from YAML
    match = re.search(r'json: \|(.*?)(?=\n---|\Z)', content, re.DOTALL)
    if not match:
        print("ERROR: Could not extract JSON from YAML")
        sys.exit(1)
    
    json_str = match.group(1).strip()
    data = json.loads(json_str)
    
    # Validate structure
    if 'panels' not in data:
        print("ERROR: No panels found")
        sys.exit(1)
    
    issues = []
    fixes_needed = []
    
    for panel in data.get('panels', []):
        panel_id = panel.get('id')
        panel_title = panel.get('title', 'Unknown')
        panel_type = panel.get('type', 'unknown')
        
        for target in panel.get('targets', []):
            expr = target.get('expr', '')
            is_instant = target.get('instant', False)
            ref_id = target.get('refId', '')
            
            # Check 1: Current-value panels should have instant queries
            if panel_type in ['gauge', 'stat', 'piechart', 'table', 'grafana-polystat-panel']:
                if not is_instant:
                    issues.append(f"Panel {panel_id} ({panel_title}): Missing instant=true for {panel_type} panel (refId: {ref_id})")
                    fixes_needed.append({
                        'panel_id': panel_id,
                        'panel_title': panel_title,
                        'panel_type': panel_type,
                        'ref_id': ref_id,
                        'expr': expr,
                        'fix': 'add_instant'
                    })
            
            # Check 2: Queries should have sum() aggregation for metrics that might have labels
            # Skip if it's a calculation or already has aggregation
            if expr and not expr.startswith('(') and 'sum(' not in expr and 'avg(' not in expr and 'max(' not in expr and 'min(' not in expr and 'stddev' not in expr and 'rate(' not in expr and 'increase(' not in expr:
                # Check if this is a simple metric name (not a calculation)
                if not any(op in expr for op in ['/', '*', '+', '-', '(', ')']):
                    issues.append(f"Panel {panel_id} ({panel_title}): Query '{expr}' may need sum() aggregation (refId: {ref_id})")
                    fixes_needed.append({
                        'panel_id': panel_id,
                        'panel_title': panel_title,
                        'panel_type': panel_type,
                        'ref_id': ref_id,
                        'expr': expr,
                        'fix': 'add_sum'
                    })
            
            # Check 3: Division queries should have sum() on both sides
            if '/' in expr and 'sum(' not in expr:
                issues.append(f"Panel {panel_id} ({panel_title}): Division query may need sum() aggregation: {expr[:60]}...")
                fixes_needed.append({
                    'panel_id': panel_id,
                    'panel_title': panel_title,
                    'panel_type': panel_type,
                    'ref_id': ref_id,
                    'expr': expr,
                    'fix': 'add_sum_to_division'
                })
    
    # Output results
    if issues:
        print(f"ISSUES_FOUND: {len(issues)}")
        for issue in issues:
            print(f"ISSUE: {issue}")
    else:
        print("ISSUES_FOUND: 0")
    
    if fixes_needed:
        print(f"FIXES_NEEDED: {len(fixes_needed)}")
        for fix in fixes_needed:
            print(f"FIX: {json.dumps(fix)}")
    else:
        print("FIXES_NEEDED: 0")
    
    print(f"PANELS: {len(data.get('panels', []))}")
    print(f"TITLE: {data.get('title', 'Unknown')}")
    
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
PYEOF
    "$dashboard_file" > /tmp/dashboard_validation.txt; then
        
        ISSUES_COUNT=$(grep "^ISSUES_FOUND:" /tmp/dashboard_validation.txt | cut -d' ' -f2)
        FIXES_COUNT=$(grep "^FIXES_NEEDED:" /tmp/dashboard_validation.txt | cut -d' ' -f2)
        PANEL_COUNT=$(grep "^PANELS:" /tmp/dashboard_validation.txt | cut -d' ' -f2)
        TITLE=$(grep "^TITLE:" /tmp/dashboard_validation.txt | cut -d' ' -f2-)
        
        if [[ "$ISSUES_COUNT" -gt 0 ]]; then
            log_warn "Found $ISSUES_COUNT issue(s), $FIXES_COUNT fix(es) needed"
            ISSUES_FOUND=$((ISSUES_FOUND + ISSUES_COUNT))
            FIXES_NEEDED=$((FIXES_NEEDED + FIXES_COUNT))
            
            # Show issues
            grep "^ISSUE:" /tmp/dashboard_validation.txt | sed 's/^ISSUE: /  - /' | head -10
            if [[ "$ISSUES_COUNT" -gt 10 ]]; then
                log_info "  ... and $((ISSUES_COUNT - 10)) more issues"
            fi
        else
            log_success "No issues found ($PANEL_COUNT panels)"
        fi
    else
        log_error "Failed to validate $dashboard_name"
        ISSUES_FOUND=$((ISSUES_FOUND + 1))
    fi
done

echo ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Summary"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Total dashboards checked: $TOTAL_DASHBOARDS"
log_info "Total issues found: $ISSUES_FOUND"
log_info "Total fixes needed: $FIXES_NEEDED"

if [[ $ISSUES_FOUND -eq 0 ]]; then
    log_success "All dashboards validated successfully!"
    exit 0
else
    log_warn "Issues found that need to be fixed"
    exit 1
fi

