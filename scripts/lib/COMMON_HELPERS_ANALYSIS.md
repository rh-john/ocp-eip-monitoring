# Helper Functions Analysis: What Should Move to common.sh

## Analysis Summary

After analyzing `deploy-grafana.sh` and other scripts, here are the helper functions that should be moved to `common.sh`:

## 1. Finalizer Removal (HIGH PRIORITY)

### Current Usage
- **`deploy-grafana.sh`** (lines 386-408): Removes finalizers from GrafanaDashboards, GrafanaDataSources, Grafana instances
- **`deploy-test-eips.sh`** (lines 1296, 1973): Removes finalizers from CloudPrivateIPConfig
- **`build-and-deploy.sh`** (line 1754): Removes finalizers from CSV

### Pattern Found
All scripts use similar logic:
```bash
# Get resources with finalizers
local stuck_resources=$(oc get <resource_type> -n "$namespace" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")

# Remove finalizers
if [[ -n "$stuck_resources" ]]; then
    echo "$stuck_resources" | while read -r name; do
        oc patch <resource_type> "$name" -n "$namespace" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    done
fi
```

### Proposed Function
```bash
# Remove finalizers from Kubernetes resources
# Usage: remove_finalizers <resource_type> <namespace> [resource_name]
#   If resource_name is provided, removes finalizers from that specific resource
#   Otherwise, removes finalizers from all resources of that type in the namespace
remove_finalizers() {
    local resource_type=$1
    local namespace=$2
    local resource_name=${3:-}
    
    if [[ -z "$resource_type" ]] || [[ -z "$namespace" ]]; then
        log_error "remove_finalizers: resource_type and namespace arguments required"
        return 1
    fi
    
    if [[ -n "$resource_name" ]]; then
        # Remove finalizers from specific resource
        local finalizers=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null || echo "")
        if [[ -n "$finalizers" ]]; then
            log_info "Removing finalizers from $resource_type/$resource_name..."
            oc patch "$resource_type" "$resource_name" -n "$namespace" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || {
                log_warn "Failed to remove finalizers from $resource_type/$resource_name"
                return 1
            }
            return 0
        fi
    else
        # Remove finalizers from all resources of this type
        local stuck_resources=$(oc get "$resource_type" -n "$namespace" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.finalizers != null and (.metadata.finalizers | length > 0)) | .metadata.name' 2>/dev/null || echo "")
        if [[ -n "$stuck_resources" ]]; then
            log_info "Removing finalizers from $resource_type resources..."
            local count=0
            echo "$stuck_resources" | while read -r name; do
                if oc patch "$resource_type" "$name" -n "$namespace" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null; then
                    ((count++)) || true
                fi
            done
            log_success "Removed finalizers from $count $resource_type resource(s)"
            return 0
        fi
    fi
    
    return 0
}
```

### Benefits
- **~30 lines** of code reduction per script
- Consistent finalizer removal logic
- Better error handling
- Reusable across all scripts

---

## 2. Grafana Pod Finding (HIGH PRIORITY)

### Current Usage
- **`test-uwm-grafana-e2e.sh`** (lines 284, 437-447): Multiple approaches to find Grafana pod
- **`test-dashboard-queries.sh`** (lines 38-42): Similar logic
- **`deploy-grafana.sh`**: Would benefit from this (currently doesn't check pod readiness)

### Pattern Found
All scripts use similar multi-selector approach:
```bash
# Try deployment name pattern first (most reliable for Grafana Operator)
grafana_pod=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "grafana.*deployment" | grep -v operator | head -1 || echo "")

# Fallback: operator-managed label
if [[ -z "$grafana_pod" ]]; then
    grafana_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/managed-by=grafana-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

# Fallback: standard Grafana label
if [[ -z "$grafana_pod" ]]; then
    grafana_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi
```

### Proposed Function
```bash
# Find Grafana pod in a namespace
# Tries multiple selectors in order: deployment name pattern, operator-managed label, standard Grafana label
# Usage: find_grafana_pod <namespace> [check_running]
#   check_running: if "true", only returns pods in Running state (default: false)
# Returns: pod name or empty string if not found
find_grafana_pod() {
    local namespace=$1
    local check_running=${2:-false}
    local grafana_pod=""
    
    if [[ -z "$namespace" ]]; then
        log_error "find_grafana_pod: namespace argument required"
        return 1
    fi
    
    # First try: deployment name pattern (most reliable for Grafana Operator)
    grafana_pod=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "grafana.*deployment" | grep -v operator | head -1 || echo "")
    
    # Fallback: operator-managed label
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/managed-by=grafana-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    # Fallback: standard Grafana label
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$namespace" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    # Fallback: name pattern (any grafana pod except operator)
    if [[ -z "$grafana_pod" ]]; then
        grafana_pod=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i grafana | grep -v operator | head -1 || echo "")
    fi
    
    # Check if pod is running if requested
    if [[ -n "$grafana_pod" ]] && [[ "$check_running" == "true" ]]; then
        local pod_phase=$(oc get pod "$grafana_pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$pod_phase" != "Running" ]]; then
            grafana_pod=""  # Pod found but not running
        fi
    fi
    
    # Return pod name (empty string if not found)
    echo "$grafana_pod"
}
```

### Benefits
- **~15 lines** of code reduction per script
- Consistent Grafana pod finding logic
- Matches pattern used for `find_thanosquerier_pod()` and `find_prometheus_pod()`
- Reusable across all scripts

---

## 3. Namespace Creation/Ensurance (MEDIUM PRIORITY)

### Current Usage
- **`deploy-grafana.sh`** (lines 109-115): Creates namespace if it doesn't exist
- **`deploy-monitoring.sh`**: Likely has similar logic
- **`deploy-eip.sh`**: Likely has similar logic

### Pattern Found
```bash
if ! oc get namespace "$namespace" &>/dev/null; then
    log_warn "Namespace '$namespace' not found, creating it..."
    oc create namespace "$namespace" 2>/dev/null || {
        log_error "Failed to create namespace"
        return 1
    }
fi
```

### Proposed Function
```bash
# Ensure namespace exists, create if it doesn't
# Usage: ensure_namespace <namespace>
# Returns: 0 if namespace exists or was created, 1 on error
ensure_namespace() {
    local namespace=$1
    
    if [[ -z "$namespace" ]]; then
        log_error "ensure_namespace: namespace argument required"
        return 1
    fi
    
    if oc get namespace "$namespace" &>/dev/null; then
        return 0  # Namespace already exists
    fi
    
    log_info "Namespace '$namespace' not found, creating it..."
    if oc create namespace "$namespace" 2>/dev/null; then
        log_success "Namespace '$namespace' created"
        return 0
    else
        log_error "Failed to create namespace '$namespace'"
        return 1
    fi
}
```

### Benefits
- **~8 lines** of code reduction per script
- Consistent namespace creation logic
- Better error handling
- Reusable across all scripts

---

## 4. CSV/Operator Detection (LOW PRIORITY)

### Current Usage
- **`deploy-grafana.sh`** (lines 119-161): Checks for Grafana operator CSV
- **`deploy-monitoring.sh`**: Likely has similar logic for COO operator

### Pattern Found
```bash
# Check cluster-scoped CSV
local cluster_csv_phase=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("operator-name")) | .status.phase' | head -1 || echo "")

# Check namespace-scoped CSV
local namespace_csv_phase=$(oc get csv -n "$namespace" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("operator-name")) | .status.phase' | head -1 || echo "")

# Check CRD as fallback
if oc get crd <operator-crd> &>/dev/null; then
    # Operator is available
fi
```

### Proposed Function
```bash
# Check if operator is installed via CSV or CRD
# Usage: check_operator_installed <operator_name> <crd_name> [namespace]
#   operator_name: name pattern to search for in CSV (e.g., "grafana-operator")
#   crd_name: CRD name to check (e.g., "grafanas.integreatly.org")
#   namespace: namespace to check (optional, checks openshift-operators if not provided)
# Returns: "succeeded", "installing", "available", or "not_found"
check_operator_installed() {
    local operator_name=$1
    local crd_name=$2
    local namespace=${3:-openshift-operators}
    
    if [[ -z "$operator_name" ]] || [[ -z "$crd_name" ]]; then
        log_error "check_operator_installed: operator_name and crd_name arguments required"
        return 1
    fi
    
    # Check cluster-scoped CSV (openshift-operators)
    local cluster_csv_phase=$(oc get csv -n openshift-operators -o json 2>/dev/null | jq -r ".items[] | select(.metadata.name | contains(\"$operator_name\")) | .status.phase" | head -1 || echo "")
    
    # Check namespace-scoped CSV
    local namespace_csv_phase=$(oc get csv -n "$namespace" -o json 2>/dev/null | jq -r ".items[] | select(.metadata.name | contains(\"$operator_name\")) | .status.phase" | head -1 || echo "")
    
    if [[ "$cluster_csv_phase" == "Succeeded" ]] || [[ "$namespace_csv_phase" == "Succeeded" ]]; then
        echo "succeeded"
        return 0
    elif [[ -n "$cluster_csv_phase" ]] || [[ -n "$namespace_csv_phase" ]]; then
        echo "installing"
        return 0
    elif oc get crd "$crd_name" &>/dev/null; then
        echo "available"
        return 0
    else
        echo "not_found"
        return 0
    fi
}
```

### Benefits
- **~20 lines** of code reduction per script
- Consistent operator detection logic
- Better error handling
- Reusable across all scripts

---

## 5. Wait for CSV (MEDIUM PRIORITY)

### Current Usage
- **`deploy-grafana.sh`** (lines 139-161): Waits for CSV to succeed
- **`deploy-monitoring.sh`**: Likely has similar logic

### Pattern Found
```bash
local max_wait=300
local waited=0
while [[ $waited -lt $max_wait ]]; do
    namespace_csv_phase=$(oc get csv -n "$namespace" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("operator-name")) | .status.phase' | head -1 || echo "")
    if [[ "$namespace_csv_phase" == "Succeeded" ]]; then
        log_success "Operator installed successfully"
        break
    elif oc get crd <crd-name> &>/dev/null; then
        log_success "Operator CRD available"
        break
    fi
    sleep 5
    waited=$((waited + 5))
    if [[ $((waited % 30)) -eq 0 ]]; then
        log_info "Still waiting... (${waited}s)"
    fi
done
```

### Proposed Function
```bash
# Wait for operator CSV to be installed
# Usage: wait_for_operator_csv <operator_name> <crd_name> <namespace> [timeout]
#   operator_name: name pattern to search for in CSV
#   crd_name: CRD name to check as fallback
#   namespace: namespace to check
#   timeout: maximum wait time in seconds (default: 300)
# Returns: 0 if CSV succeeded or CRD available, 1 on timeout
wait_for_operator_csv() {
    local operator_name=$1
    local crd_name=$2
    local namespace=$3
    local timeout=${4:-300}
    local elapsed=0
    
    if [[ -z "$operator_name" ]] || [[ -z "$crd_name" ]] || [[ -z "$namespace" ]]; then
        log_error "wait_for_operator_csv: operator_name, crd_name, and namespace arguments required"
        return 1
    fi
    
    log_info "Waiting for $operator_name operator to be installed (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local csv_phase=$(oc get csv -n "$namespace" -o json 2>/dev/null | jq -r ".items[] | select(.metadata.name | contains(\"$operator_name\")) | .status.phase" | head -1 || echo "")
        
        if [[ "$csv_phase" == "Succeeded" ]]; then
            log_success "$operator_name operator installed successfully (CSV phase: Succeeded)"
            return 0
        elif oc get crd "$crd_name" &>/dev/null; then
            log_success "$operator_name operator CRD available"
            return 0
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -lt $timeout ]]; then
            log_info "Still waiting for $operator_name operator... (${elapsed}s, CSV phase: ${csv_phase:-none})"
        fi
    done
    
    log_warn "$operator_name operator may not be fully ready yet (waited ${timeout}s)"
    return 1
}
```

### Benefits
- **~25 lines** of code reduction per script
- Consistent CSV wait logic
- Better error handling
- Reusable across all scripts

---

## Summary

### Recommended Functions to Add to `common.sh`

| Function | Priority | Code Reduction | Reusability | Status |
|----------|----------|----------------|-------------|--------|
| `remove_finalizers()` | HIGH | ~30 lines/script | Very High | ✅ **IMPLEMENTED** |
| `find_grafana_pod()` | HIGH | ~15 lines/script | High | ✅ **IMPLEMENTED** |
| `ensure_namespace()` | MEDIUM | ~8 lines/script | High | ⏳ Pending |
| `wait_for_operator_csv()` | MEDIUM | ~25 lines/script | Medium | ⏳ Pending |
| `check_operator_installed()` | LOW | ~20 lines/script | Medium | ⏳ Pending |

### Total Expected Benefits
- **~98 lines** of code reduction per script that uses all functions
- Consistent patterns across all scripts
- Better error handling and logging
- Easier maintenance

### Implementation Order
1. **Phase 1**: `remove_finalizers()` and `find_grafana_pod()` (highest impact)
2. **Phase 2**: `ensure_namespace()` and `wait_for_operator_csv()` (medium impact)
3. **Phase 3**: `check_operator_installed()` (nice to have)

### Files That Would Benefit
- `scripts/deploy-grafana.sh` (all functions)
- `scripts/deploy-monitoring.sh` (most functions)
- `scripts/deploy-eip.sh` (some functions)
- `scripts/deploy-test-eips.sh` (`remove_finalizers()`)
- `tests/e2e/test-uwm-grafana-e2e.sh` (`find_grafana_pod()`)
- `scripts/test/test-dashboard-queries.sh` (`find_grafana_pod()`)

