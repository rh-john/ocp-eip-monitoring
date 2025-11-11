# Grafana Deployment Safety & Idempotency

## Safe to Re-run

The Grafana deploy script is safe to re-run multiple times. It uses idempotent operations that won't break existing resources.

## How It Works

### Idempotent Operations

The script uses `oc apply` for all resources, which is idempotent:
- Creates resources if they don't exist
- Updates resources if they exist but differ
- No-op if resources already match the desired state
- No deletion of existing resources

### Resource-by-Resource Analysis

#### 1. Namespace (`oc create namespace`)
- Safe: Checks if namespace exists before creating
- Behavior: Only creates if missing, otherwise skips
- Impact: No changes if namespace exists

#### 2. Grafana Operator (`oc apply`)
- Safe: Checks if operator is already installed
- Behavior: 
  - Skips installation if CSV is "Succeeded"
  - Skips if CRD already exists
  - Only installs if missing
- Impact: No changes if operator is already installed

#### 3. RBAC (`oc apply -f grafana-rbac.yaml`)
- Safe: Uses `oc apply` (idempotent)
- Behavior: Updates ServiceAccount/ClusterRoleBinding if changed
- Impact: Updates only if manifest changed, otherwise no-op

#### 4. Service Account Token (`oc create token`)
- Safe: Creates new token, handles errors gracefully
- Behavior: 
  - Creates token if successful
  - Falls back to placeholder if creation fails
  - Previous tokens remain valid until expiry
- Impact: May create new token, but old ones still work

#### 5. DataSource (`oc apply` + `oc patch`)
- Safe: Uses `oc apply` then patches token
- Behavior:
  - Updates datasource config if changed
  - Updates token in secureJsonData
  - No deletion of datasource
- Impact: Updates datasource config and token, otherwise no-op

#### 6. Grafana Instance (`oc apply`)
- Safe: Uses `oc apply` (idempotent)
- Behavior:
  - Updates Grafana instance config if changed
  - Updates plugins list if changed
  - Operator handles plugin installation/updates
  - No deletion of instance
- Impact: 
  - Updates config if manifest changed
  - Installs/updates plugins if plugin list changed
  - May restart Grafana pod if plugins changed (handled by operator)

#### 7. Dashboards (`oc apply`)
- Safe: Uses `oc apply` (idempotent)
- Behavior:
  - Creates dashboard if missing
  - Updates dashboard JSON if changed
  - No deletion of dashboards
- Impact: Updates dashboard content if manifest changed

## What Happens on Re-run

### Scenario 1: No Changes
```
Namespace exists → Skip
Operator installed → Skip
RBAC exists → No-op (apply detects no changes)
Token creation → May create new token (old one still valid)
DataSource exists → No-op (apply detects no changes)
Instance exists → No-op (apply detects no changes)
Dashboards exist → No-op (apply detects no changes)
```
Result: Script completes quickly, no changes made

### Scenario 2: Plugin List Changed
```
All resources exist
Instance manifest changed (new plugins added)
→ Operator detects plugin changes
→ Operator installs new plugins
→ Operator may restart Grafana pod
```
Result: New plugins installed, brief Grafana restart

### Scenario 3: Dashboard Updated
```
All resources exist
Dashboard manifest changed
→ Dashboard JSON updated in Grafana
→ Changes visible immediately
```
Result: Dashboard updated, no service interruption

### Scenario 4: Config Changed
```
All resources exist
Instance config changed (e.g., admin password)
→ Operator updates Grafana config
→ Operator may restart Grafana pod
```
Result: Config updated, brief Grafana restart

## Potential Considerations

### 1. Token Creation
- **Issue:** `oc create token` may create a new token each time
- **Impact:** Old tokens remain valid until expiry (8760h = 1 year)
- **Mitigation:** Script handles errors gracefully, falls back to placeholder
- **Recommendation:** Tokens are long-lived (1 year), so this is acceptable

### 2. Plugin Installation
- **Issue:** Adding new plugins may restart Grafana
- **Impact:** Brief service interruption (30-60 seconds)
- **Mitigation:** Operator handles this gracefully
- **Recommendation:** Plugin changes are infrequent, acceptable downtime

### 3. Dashboard Updates
- **Issue:** Large dashboard updates may take a moment to apply
- **Impact:** Dashboard may be briefly unavailable during update
- **Mitigation:** Grafana handles dashboard updates gracefully
- **Recommendation:** Updates are quick, minimal impact

## Best Practices

### Safe Operations
- Re-running script with no changes → Safe
- Adding new plugins → Safe (may restart Grafana)
- Updating dashboard JSON → Safe
- Updating config → Safe (may restart Grafana)
- Adding new dashboards → Safe

### Considerations
- Changing admin password → Safe but will log out current sessions
- Removing plugins from list → Safe but plugins remain installed (operator doesn't uninstall)
- Removing dashboards from script → Safe but dashboards remain in Grafana (need manual deletion)

### Not Handled (Manual Steps Required)
- Removing plugins → Need to manually uninstall via Grafana UI or pod exec
- Removing dashboards → Need to manually delete via `oc delete grafanadashboard <name>`
- Changing namespace → Need to delete old resources first

## Testing Idempotency

You can safely test by running:

```bash
# First run (COO)
./scripts/deploy-grafana.sh --monitoring-type coo

# Immediate re-run (should be fast, no changes)
./scripts/deploy-grafana.sh --monitoring-type coo

# After making changes
# Edit k8s/grafana/grafana-instance.yaml (add plugin)
./scripts/deploy-grafana.sh --monitoring-type coo  # Should update plugins

# Re-run again (should detect no changes)
./scripts/deploy-grafana.sh --monitoring-type coo
```

## Summary

The script is idempotent and safe to re-run.

- No destructive operations - uses `oc apply` everywhere
- Graceful error handling - continues even if some operations fail
- Operator-managed - Grafana Operator handles plugin installation safely
- No data loss - existing dashboards, configs, and data are preserved

Minor considerations:
- Token creation may generate new tokens (old ones still work)
- Plugin changes may cause brief Grafana restart
- Removing resources requires manual deletion

---

**Last Updated:** 2024  
**Script Version:** Current  
**Tested With:** OpenShift 4.x, Grafana Operator v4+

