# Deploy Grafana Script Optimization Analysis

## Current State Analysis

### Issues Identified

1. **Code Duplication**
   - Duplicate logging functions (`log_info`, `log_success`, `log_warn`, `log_error`) - already in `common.sh`
   - Duplicate `check_prerequisites()` - already in `common.sh`
   - Manual path resolution instead of using `PROJECT_ROOT` from `common.sh`
   - Manual wait loops instead of using `wait_for_resource()` and `wait_for_pods()`

2. **Command Structure Inconsistency**
   - Uses flags (`--remove`, `--remove-operator`, `--all`) instead of commands
   - Doesn't match pattern used in `deploy-monitoring.sh` (`--remove-monitoring [TYPE]`)
   - No `status` command to check deployment state
   - No clear separation between deploy/remove operations

3. **Logic Issues**
   - Manual operator CSV detection with complex loops (lines 119-161)
   - Manual namespace creation instead of using `wait_for_resource`
   - Dashboard deployment loop could use better error handling
   - Finalizer removal logic is verbose and repetitive
   - Token creation logic could be simplified

4. **Missing Features**
   - No `status` command to check Grafana deployment state
   - No `--verbose` option for debugging
   - No validation of Grafana instance readiness before deploying dashboards
   - No check for Grafana pod readiness

5. **Error Handling**
   - Some operations don't check return codes properly
   - Error messages could be more actionable
   - Missing validation for required files before deployment

## Proposed Optimizations

### 1. Use `common.sh` Functions

**Replace:**
- `log_*` functions → Use from `common.sh`
- `check_prerequisites()` → Use from `common.sh` (extend if needed)
- Manual path resolution → Use `PROJECT_ROOT` from `common.sh`
- Manual wait loops → Use `wait_for_resource()` and `wait_for_pods()`
- Manual `oc` calls → Use `oc_cmd()` and `oc_cmd_silent()` from `common.sh`

**Benefits:**
- ~100 lines of code reduction
- Consistent behavior across scripts
- Better error handling

### 2. Improve Command Structure

**Current:**
```bash
./deploy-grafana.sh --monitoring-type coo
./deploy-grafana.sh --remove --monitoring-type coo
./deploy-grafana.sh --all --monitoring-type coo
```

**Proposed (Option A - Commands):**
```bash
./deploy-grafana.sh deploy --monitoring-type coo
./deploy-grafana.sh remove --monitoring-type coo
./deploy-grafana.sh remove --all --monitoring-type coo
./deploy-grafana.sh status
```

**Proposed (Option B - Match deploy-monitoring.sh):**
```bash
./deploy-grafana.sh --monitoring-type coo
./deploy-grafana.sh --remove-grafana coo
./deploy-grafana.sh --remove-grafana all
./deploy-grafana.sh --status
```

**Recommendation:** Option B (match `deploy-monitoring.sh` pattern) for consistency.

### 3. Better Logic Improvements

#### Operator Detection
**Current:** Complex manual CSV checking with loops
**Proposed:** Use `wait_for_resource` for CSV, check CRD existence

#### Grafana Instance Readiness
**Current:** Just sleeps 5 seconds
**Proposed:** Use `wait_for_resource` to wait for Grafana instance to be ready

#### Pod Readiness
**Current:** No check for Grafana pod
**Proposed:** Use `wait_for_pods` to wait for Grafana pod to be running

#### Dashboard Deployment
**Current:** Sequential deployment with basic error counting
**Proposed:** 
- Batch deployment with better error reporting
- Validate dashboard files exist before deployment
- Use `wait_for_resource` for each dashboard

#### Finalizer Removal
**Current:** Repetitive code for each resource type
**Proposed:** Generic function to remove finalizers from any resource type

### 4. Add Missing Features

#### Status Command
```bash
./deploy-grafana.sh --status
```
Shows:
- Grafana instance status
- Grafana pod status
- Dashboard count
- Datasource count
- Operator status
- Route URL (if available)

#### Verbose Mode
```bash
./deploy-grafana.sh --monitoring-type coo --verbose
```
Shows full `oc` command output for debugging

#### Better Validation
- Check all required files exist before starting deployment
- Validate monitoring type early
- Check namespace exists or can be created
- Verify operator prerequisites

### 5. Code Organization

**Proposed Structure:**
```bash
# Source common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Configuration
# ...

# Helper Functions
- remove_finalizers()  # Generic finalizer removal
- get_grafana_pod()    # Find Grafana pod
- check_grafana_ready() # Check if Grafana is ready
- validate_files()     # Validate required files exist

# Main Functions
- deploy_grafana_operator()
- deploy_grafana_instance()
- deploy_grafana_datasource()
- deploy_grafana_dashboards()
- remove_grafana_resources()
- remove_grafana_operator()
- show_status()

# Main
- parse_args()
- main()
```

## Implementation Plan

### Phase 1: Use `common.sh` (High Priority)
1. Source `common.sh`
2. Remove duplicate logging functions
3. Replace `check_prerequisites()` with `common.sh` version
4. Use `PROJECT_ROOT` from `common.sh`
5. Replace manual `oc` calls with `oc_cmd()`/`oc_cmd_silent()`

**Estimated Reduction:** ~50 lines

### Phase 2: Improve Wait Logic (High Priority)
1. Replace operator CSV wait loop with `wait_for_resource`
2. Replace Grafana instance wait with `wait_for_resource`
3. Add Grafana pod wait with `wait_for_pods`
4. Add dashboard readiness checks

**Estimated Reduction:** ~40 lines

### Phase 3: Refactor Commands (Medium Priority)
1. Change to `--remove-grafana [TYPE]` pattern
2. Add `--status` command
3. Add `--verbose` option
4. Improve help text

**Estimated Reduction:** ~10 lines (but better UX)

### Phase 4: Code Organization (Medium Priority)
1. Extract `remove_finalizers()` helper
2. Extract `get_grafana_pod()` helper
3. Extract `validate_files()` helper
4. Split deployment into smaller functions

**Estimated Reduction:** ~30 lines

### Phase 5: Enhanced Features (Low Priority)
1. Add comprehensive status command
2. Add better error messages with troubleshooting tips
3. Add dry-run mode
4. Add validation for all resources before removal

## Expected Benefits

### Code Quality
- **~130 lines of code reduction** (from ~678 to ~548 lines)
- Consistent with other deployment scripts
- Better maintainability
- Reduced duplication

### Functionality
- Better error handling
- More reliable deployments
- Better debugging capabilities
- Status visibility

### Developer Experience
- Consistent command patterns across scripts
- Better error messages
- Easier to debug issues
- More predictable behavior

## Risks

1. **Breaking Changes:** Changing command structure may break existing scripts/calls
   - **Mitigation:** Support both old and new syntax during transition period

2. **Wait Logic:** `wait_for_resource` may not work perfectly for all Grafana resources
   - **Mitigation:** Test thoroughly, fallback to manual waits if needed

3. **Common.sh Dependencies:** Script becomes dependent on `common.sh`
   - **Mitigation:** Already a pattern in other scripts, low risk

## Testing Requirements

1. Test deployment for both COO and UWM
2. Test removal for both COO and UWM
3. Test operator installation (both namespace-scoped and cluster-scoped)
4. Test finalizer removal
5. Test status command
6. Test verbose mode
7. Test error cases (missing files, invalid monitoring type, etc.)
8. Test integration with `deploy-eip.sh --grafana`

## Migration Notes

- Old syntax should be supported during transition
- Update documentation
- Update `deploy-eip.sh` if needed
- Update e2e tests if needed

