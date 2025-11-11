# Refactoring Plan: Moving Functions from deploy-monitoring.sh to common.sh

## Functions That Can Be Moved

### 1. **Enhanced `check_prerequisites()`**
**Current location:** `deploy-monitoring.sh` lines 98-120  
**Why move:** Enhanced version checks for `jq` in addition to `oc`, which is useful for all scripts  
**Changes needed:**
- Add `jq` check to existing `check_prerequisites()` in `common.sh`
- Make `exit` vs `return` configurable (some scripts may want to handle errors differently)

### 2. **`oc_cmd()` and `oc_cmd_silent()`**
**Current location:** `deploy-monitoring.sh` lines 41-56  
**Why move:** Useful helper functions for verbose/non-verbose oc command execution  
**Usage pattern:** Used throughout `deploy-monitoring.sh` for conditional output suppression  
**Note:** Requires `VERBOSE` variable to be set (could be optional parameter)

### 3. **`find_prometheus_pod()`**
**Current location:** Duplicated in multiple places:
- `deploy-monitoring.sh` line 664
- `test-monitoring-e2e.sh` lines 179-182
- `test/test-monitoring-deployment.sh` (multiple places)
- `debug/verify-prometheus-metrics.sh` (multiple places)

**Proposed function signature:**
```bash
find_prometheus_pod() {
    local namespace=$1
    local prefer_coo=${2:-false}  # If true, prefer COO-specific labels
    
    # Try COO-specific labels first if prefer_coo=true
    # Then try standard labels
    # Return pod name or empty string
}
```

### 4. **`find_thanosquerier_pod()`**
**Current location:** Duplicated in:
- `deploy-monitoring.sh` lines 510-520, 1438-1448
- `test-monitoring-e2e.sh` lines 224-227
- `verify_thanosquerier_stores()` function

**Proposed function signature:**
```bash
find_thanosquerier_pod() {
    local namespace=$1
    
    # Try multiple selectors:
    # 1. COO-specific: app.kubernetes.io/managed-by=observability-operator,app.kubernetes.io/part-of=ThanosQuerier
    # 2. Standard: app.kubernetes.io/name=thanos-query
    # 3. Name pattern: thanos.*querier|querier.*thanos
    # Return pod name or empty string
}
```

### 5. **`find_query_pod()` (Composite function)**
**Current location:** Logic duplicated in:
- `test-monitoring-e2e.sh` lines 217-243
- `test/test-monitoring-deployment.sh` lines 468-490

**Proposed function signature:**
```bash
find_query_pod() {
    local namespace=$1
    local prefer_thanos=${2:-true}  # Prefer ThanosQuerier for COO
    
    # Returns: pod_name|port
    # Example: "thanos-querier-pod-123|10902" or "prometheus-pod-456|9090"
}
```

### 6. **`wait_for_pod_phase()`**
**Current location:** Logic duplicated in `deploy-monitoring.sh` lines 1430-1474  
**Why move:** More specific than `wait_for_pods()` - waits for specific pod to reach Running phase  
**Proposed function signature:**
```bash
wait_for_pod_phase() {
    local namespace=$1
    local pod_name=$2
    local expected_phase=${3:-Running}
    local timeout=${4:-120}
    
    # Wait for specific pod to reach expected phase
}
```

## Functions That Should Stay in deploy-monitoring.sh

### Monitoring-Specific Functions (not reusable):
- `enable_user_workload_monitoring()` - UWM-specific configuration
- `enable_user_workload_alertmanager()` - UWM-specific configuration
- `install_coo_operator()` - COO-specific operator installation
- `configure_coo_monitoring_stack()` - COO-specific stack configuration
- `remove_coo_monitoring()` - COO-specific cleanup
- `remove_uwm_monitoring()` - UWM-specific cleanup
- `setup_federation_token()` - Federation-specific setup
- `verify_federation()` - Federation-specific verification
- `verify_thanosquerier_stores()` - ThanosQuerier-specific verification
- `detect_current_monitoring_type()` - Monitoring-specific detection
- `deploy_monitoring()` - Main deployment logic
- `parse_args()` - Script-specific argument parsing
- `show_usage()` - Script-specific usage

## Implementation Priority

### High Priority (Most duplicated):
1. ✅ `find_thanosquerier_pod()` - Used in 3+ places
2. ✅ `find_prometheus_pod()` - Used in 4+ places  
3. ✅ `find_query_pod()` - Composite function that combines above

### Medium Priority (Useful helpers):
4. `oc_cmd()` / `oc_cmd_silent()` - Useful for verbose mode handling
5. Enhanced `check_prerequisites()` - Add jq check

### Low Priority (Nice to have):
6. `wait_for_pod_phase()` - More specific wait function

## Migration Steps

1. Add functions to `common.sh`
2. Update `deploy-monitoring.sh` to source and use common functions
3. Update other scripts (`test-monitoring-e2e.sh`, `test/test-monitoring-deployment.sh`, etc.) to use common functions
4. Remove duplicate code
5. Test all scripts to ensure they still work

## Benefits

- **Reduced duplication:** Eliminate repeated pod-finding logic
- **Consistency:** All scripts use same pod detection logic
- **Maintainability:** Fix bugs in one place
- **Testability:** Test pod-finding logic once

