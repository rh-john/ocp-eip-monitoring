#!/bin/bash
#
# Verify Prometheus Metrics Ingestion
# Diagnoses and fixes issues with Prometheus not finding EIP metrics
#

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-eip-monitoring}"
MONITORING_TYPE="${MONITORING_TYPE:-coo}"  # coo or uwm
MAX_ATTEMPTS=12
WAIT_BETWEEN_ATTEMPTS=30
VERBOSE="${VERBOSE:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'  # Light blue (cyan)
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Show usage
show_usage() {
    cat << EOF
Verify Prometheus Metrics Ingestion

Usage: $0 [options]

Options:
  -n, --namespace NS        Kubernetes namespace (default: eip-monitoring)
  --monitoring-type TYPE    Monitoring type: coo or uwm (auto-detected if not specified)
  -v, --verbose            Show verbose output (detailed diagnostic information)
  -h, --help               Show this help message

Environment Variables:
  NAMESPACE                 Kubernetes namespace (default: eip-monitoring)
  MONITORING_TYPE           Monitoring type: coo or uwm (auto-detected if not specified)
  VERBOSE                   Set to true to show verbose output (default: false)

Examples:
  $0
  $0 --verbose
  $0 -n my-namespace --monitoring-type uwm
  $0 -v

EOF
}

# Detect monitoring type
detect_monitoring_type() {
    if oc get subscription cluster-observability-operator -n openshift-operators &>/dev/null; then
        echo "coo"
        return 0
    fi
    
    local cluster_config=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
    if echo "$cluster_config" | grep -qE "enableUserWorkload:\s*true"; then
        echo "uwm"
        return 0
    fi
    
    echo "none"
}

# Get Prometheus pod name
get_prometheus_pod() {
    local monitoring_type="$1"
    
    if [[ "$monitoring_type" == "coo" ]]; then
        oc get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
    elif [[ "$monitoring_type" == "uwm" ]]; then
        oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Query Prometheus for a metric
query_prometheus() {
    local prom_pod="$1"
    local prom_namespace="$2"
    local query="$3"
    
    # Escape the query for URL
    local encoded_query=$(echo "$query" | jq -sRr @uri)
    
    # Query Prometheus API
    local response=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
        curl -s "http://localhost:9090/api/v1/query?query=${encoded_query}" 2>/dev/null || echo "")
    
    if [[ -z "$response" ]]; then
        echo "{}"
        return 1
    fi
    
    echo "$response"
}

# Check if metric exists in Prometheus
check_metric_exists() {
    local prom_pod="$1"
    local prom_namespace="$2"
    local metric_name="$3"
    
    # Try multiple query patterns
    local queries=(
        "${metric_name}"
        "${metric_name}{}"
        "{__name__=\"${metric_name}\"}"
        "{job=~\".*eip.*\"}"
        "{job=\"eip-monitor\"}"
    )
    
    for query in "${queries[@]}"; do
        local result=$(query_prometheus "$prom_pod" "$prom_namespace" "$query")
        local status=$(echo "$result" | jq -r '.status' 2>/dev/null || echo "error")
        local data=$(echo "$result" | jq -r '.data.result | length' 2>/dev/null || echo "0")
        
        if [[ "$status" == "success" ]] && [[ "$data" != "0" ]] && [[ "$data" != "null" ]]; then
            return 0
        fi
    done
    
    return 1
}

# Get Prometheus target status
get_target_status() {
    local prom_pod="$1"
    local prom_namespace="$2"
    
    # Get targets from Prometheus
    local targets=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
        curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null || echo "{}")
    
    echo "$targets"
}

# Check ServiceMonitor configuration
check_servicemonitor() {
    log_info "Checking ServiceMonitor configuration..."
    
    # Determine ServiceMonitor name based on monitoring type
    local sm_name=""
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        sm_name="eip-monitor-coo"
    else
        sm_name="eip-monitor-uwm"
    fi
    
    # Try both CRD versions (COO uses monitoring.rhobs/v1)
    if ! oc get servicemonitor.monitoring.rhobs "$sm_name" -n "$NAMESPACE" &>/dev/null && \
       ! oc get servicemonitor.monitoring.coreos.com "$sm_name" -n "$NAMESPACE" &>/dev/null && \
       ! oc get servicemonitor "$sm_name" -n "$NAMESPACE" &>/dev/null; then
        log_error "ServiceMonitor '$sm_name' not found in namespace '$NAMESPACE'"
        log_info "Checking for ServiceMonitors in namespace..."
        oc get servicemonitor -n "$NAMESPACE" 2>&1 | head -5
        return 1
    fi
    
    log_success "ServiceMonitor '$sm_name' exists"
    
    # Check ServiceMonitor labels
    # Try different API versions to get labels (COO uses monitoring.rhobs/v1, UWM uses monitoring.coreos.com/v1)
    local sm_labels="{}"
    if [[ "$MONITORING_TYPE" == "coo" ]]; then
        # Try COO API version first
        sm_labels=$(oc get servicemonitor.monitoring.rhobs "$sm_name" -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "{}")
        # Fallback to standard API if that fails
        if [[ "$sm_labels" == "{}" ]]; then
            sm_labels=$(oc get servicemonitor "$sm_name" -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "{}")
        fi
    else
        # Try UWM API version first
        sm_labels=$(oc get servicemonitor.monitoring.coreos.com "$sm_name" -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "{}")
        # Fallback to standard API if that fails
        if [[ "$sm_labels" == "{}" ]]; then
            sm_labels=$(oc get servicemonitor "$sm_name" -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "{}")
        fi
    fi
    log_verbose "ServiceMonitor labels: $sm_labels"
    
    # Check endpoint configuration
    local endpoint_path=$(oc get servicemonitor "$sm_name" -n "$NAMESPACE" -o jsonpath='{.spec.endpoints[0].path}' 2>/dev/null || echo "")
    local endpoint_port=$(oc get servicemonitor "$sm_name" -n "$NAMESPACE" -o jsonpath='{.spec.endpoints[0].port}' 2>/dev/null || echo "")
    
    log_verbose "Endpoint path: ${endpoint_path:-/metrics}"
    log_verbose "Endpoint port: ${endpoint_port:-metrics}"
    
    return 0
}

# Check if service has correct labels
check_service_labels() {
    log_info "Checking service labels..."
    
    if ! oc get service eip-monitor -n "$NAMESPACE" &>/dev/null; then
        log_error "Service 'eip-monitor' not found"
        return 1
    fi
    
    local service_labels=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "{}")
    log_verbose "Service labels: $service_labels"
    
    # Check if service has required labels
    local app_label=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app}' 2>/dev/null || echo "")
    local service_label=$(oc get service eip-monitor -n "$NAMESPACE" -o jsonpath='{.metadata.labels.service}' 2>/dev/null || echo "")
    
    local label_issue=false
    if [[ "$app_label" != "eip-monitor" ]]; then
        log_warn "Service label 'app' is '$app_label', expected 'eip-monitor'"
        label_issue=true
    fi
    
    if [[ "$service_label" != "eip-monitor" ]]; then
        log_warn "Service label 'service' is '$service_label', expected 'eip-monitor'"
        label_issue=true
    fi
    
    if [[ "$label_issue" == "true" ]]; then
        log_info "To fix service labels, run: ./scripts/fix-service-labels.sh"
        log_info "Or reapply the service manifest: oc apply -f k8s/deployment/k8s-manifests.yaml"
    fi
    
    return 0
}

# Check MonitoringStack configuration (for COO)
check_monitoringstack() {
    if [[ "$MONITORING_TYPE" != "coo" ]]; then
        return 0
    fi
    
    log_info "Checking MonitoringStack configuration..."
    
    if ! oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" &>/dev/null; then
        log_error "MonitoringStack 'eip-monitoring-stack' not found in namespace '$NAMESPACE'"
        return 1
    fi
    
    log_success "MonitoringStack 'eip-monitoring-stack' exists"
    
    # Check resourceSelector
    local resource_selector=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.spec.resourceSelector.matchLabels}' 2>/dev/null || echo "{}")
    log_verbose "MonitoringStack resourceSelector: $resource_selector"
    
    # Check if resourceSelector matches ServiceMonitor labels
    local app_match=$(echo "$resource_selector" | jq -r '.app' 2>/dev/null || echo "")
    if [[ "$app_match" == "eip-monitor" ]]; then
        log_success "✓ MonitoringStack resourceSelector matches ServiceMonitor labels"
    else
        log_warn "MonitoringStack resourceSelector might not match ServiceMonitor labels"
        log_info "  Expected: app=eip-monitor"
        log_info "  Found: app=$app_match"
    fi
    
    # Check MonitoringStack status
    # Try with explicit API version first (monitoring.rhobs/v1alpha1)
    local stack_status=""
    local stack_message=""
    local has_status=""
    
    # Check if status field exists at all (try both API versions)
    has_status=$(oc get monitoringstack.monitoring.rhobs eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status}' 2>/dev/null || echo "")
    if [[ -z "$has_status" ]] || [[ "$has_status" == "" ]]; then
        has_status=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status}' 2>/dev/null || echo "")
    fi
    
    # Try to get Ready condition status (try both API versions)
    if [[ -n "$has_status" ]] && [[ "$has_status" != "{}" ]]; then
        stack_status=$(oc get monitoringstack.monitoring.rhobs eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ -z "$stack_status" ]]; then
            stack_status=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        fi
        
        # Get condition message if status exists
        if [[ -n "$stack_status" ]]; then
            stack_message=$(oc get monitoringstack.monitoring.rhobs eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        fi
    fi
    
    # Evaluate and report status
    if [[ "$stack_status" == "True" ]]; then
        log_success "✓ MonitoringStack is Ready"
        if [[ -n "$stack_message" ]]; then
            log_verbose "  Status message: $stack_message"
        fi
    elif [[ -z "$has_status" ]] || [[ "$has_status" == "{}" ]] || [[ "$has_status" == "" ]]; then
        log_info "MonitoringStack status not yet available (may still be initializing)"
        log_info "  This is normal if the MonitoringStack was just created"
        log_info "  The operator is likely still creating Prometheus and Alertmanager pods"
        log_info "  Check progress: oc get pods -n $NAMESPACE -l app.kubernetes.io/name=prometheus"
    elif [[ -z "$stack_status" ]]; then
        # Status exists but Ready condition doesn't - check what conditions are available
        local all_conditions=$(oc get monitoringstack.monitoring.rhobs eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
        if [[ -z "$all_conditions" ]]; then
            all_conditions=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "")
        fi
        
        if [[ -n "$all_conditions" ]]; then
            log_verbose "MonitoringStack status available but Ready condition not found"
            log_verbose "  Available conditions: $all_conditions"
            
            # Try to get status from the first available condition
            local first_condition_type=$(echo "$all_conditions" | awk '{print $1}')
            if [[ -n "$first_condition_type" ]]; then
                local first_status=$(oc get monitoringstack.monitoring.rhobs eip-monitoring-stack -n "$NAMESPACE" -o jsonpath="{.status.conditions[?(@.type==\"$first_condition_type\")].status}" 2>/dev/null || echo "")
                if [[ -z "$first_status" ]]; then
                    first_status=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath="{.status.conditions[?(@.type==\"$first_condition_type\")].status}" 2>/dev/null || echo "")
                fi
                if [[ -n "$first_status" ]]; then
                    log_verbose "  $first_condition_type condition status: $first_status"
                fi
            fi
            
            # Check for common alternative condition types
            for condition_type in "Available" "Progressing" "Degraded" "Reconciling"; do
                local alt_status=$(oc get monitoringstack.monitoring.rhobs eip-monitoring-stack -n "$NAMESPACE" -o jsonpath="{.status.conditions[?(@.type==\"$condition_type\")].status}" 2>/dev/null || echo "")
                if [[ -z "$alt_status" ]]; then
                    alt_status=$(oc get monitoringstack eip-monitoring-stack -n "$NAMESPACE" -o jsonpath="{.status.conditions[?(@.type==\"$condition_type\")].status}" 2>/dev/null || echo "")
                fi
                if [[ -n "$alt_status" ]]; then
                    log_verbose "  $condition_type condition status: $alt_status"
                fi
            done
        else
            log_info "MonitoringStack status field exists but no conditions found yet"
            log_info "  This usually means the operator is still processing the resource"
        fi
    else
        log_warn "MonitoringStack status: ${stack_status}"
        if [[ -n "$stack_message" ]]; then
            log_verbose "  Status message: $stack_message"
        fi
    fi
    
    return 0
}

# Check Prometheus configuration for ServiceMonitor
check_prometheus_config() {
    local prom_pod="$1"
    local prom_namespace="$2"
    
    log_verbose "Checking Prometheus configuration for ServiceMonitor..."
    
    # Get Prometheus configuration
    local prom_config=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
        curl -s "http://localhost:9090/api/v1/status/config" 2>/dev/null || echo "{}")
    
    if [[ -z "$prom_config" ]] || [[ "$prom_config" == "{}" ]]; then
        log_warn "Could not retrieve Prometheus configuration"
        return 1
    fi
    
    # Check if ServiceMonitor is in the configuration
    local config_yaml=$(echo "$prom_config" | jq -r '.data.yaml' 2>/dev/null || echo "")
    
    if echo "$config_yaml" | grep -q "eip-monitor"; then
        log_success "✓ ServiceMonitor found in Prometheus configuration"
        
        # Try to find the actual scrape config
        if echo "$config_yaml" | grep -A 10 "eip-monitor" | grep -q "job_name"; then
            local job_name=$(echo "$config_yaml" | grep -A 10 "eip-monitor" | grep "job_name" | head -1 | sed 's/.*job_name: *//' | tr -d '"' || echo "")
            if [[ -n "$job_name" ]]; then
                log_verbose "  Found job: $job_name"
            fi
        fi
        
        return 0
    else
        log_warn "ServiceMonitor not found in Prometheus configuration"
        log_verbose "Prometheus may need to reload its configuration"
        return 1
    fi
}

# Check service endpoints
check_service_endpoints() {
    log_info "Checking service endpoints..."
    
    local endpoints=$(oc get endpoints eip-monitor -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[*].ip}' 2>/dev/null || echo "")
    
    if [[ -z "$endpoints" ]]; then
        log_error "Service 'eip-monitor' has no endpoints!"
        log_verbose "This means no pods are matching the service selector"
        log_verbose ""
        log_verbose "Possible causes:"
        log_verbose "  1. Pods are not running"
        log_verbose "  2. Service selector doesn't match pod labels"
        log_verbose "  3. Service labels were changed incorrectly"
        log_verbose ""
        log_verbose "Check pod status:"
        log_verbose "  oc get pods -n $NAMESPACE -l app=eip-monitor"
        log_verbose ""
        log_verbose "Check service selector vs pod labels:"
        log_verbose "  oc get service eip-monitor -n $NAMESPACE -o jsonpath='{.spec.selector}'"
        log_verbose "  oc get pods -n $NAMESPACE -l app=eip-monitor -o jsonpath='{.items[*].metadata.labels}'"
        log_verbose ""
        log_verbose "To fix service labels/selector:"
        log_verbose "  ./scripts/fix-service-labels.sh"
        return 1
    fi
    
    log_success "✓ Service has endpoints: $endpoints"
    return 0
}

# Check Prometheus scrape configs directly
check_prometheus_scrape_configs() {
    local prom_pod="$1"
    local prom_namespace="$2"
    
    log_verbose "Checking Prometheus scrape configurations..."
    
    # Get full config
    local full_config=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
        curl -s "http://localhost:9090/api/v1/status/config" 2>/dev/null | \
        jq -r '.data.yaml' 2>/dev/null || echo "")
    
    if [[ -z "$full_config" ]]; then
        log_warn "Could not retrieve scrape configs"
        return 1
    fi
    
    # Extract all job names - handle different YAML formatting
    # Try multiple patterns to extract job names from YAML
    local job_names=$(echo "$full_config" | grep -E "^\s+- job_name:" | sed 's/.*job_name: *//' | sed 's/^"//' | sed 's/"$//' | tr -d '"' | sed 's/^[ ]*//' | grep -v "^$" || echo "")
    
    # If that didn't work, try extracting from scrape_configs section
    if [[ -z "$job_names" ]]; then
        job_names=$(echo "$full_config" | awk '/scrape_configs:/{flag=1} flag && /^- job_name:/{gsub(/.*job_name: */, ""); gsub(/^[ ]+/, ""); print}' | head -10 || echo "")
    fi
    
    log_verbose "Available scrape jobs:"
    if [[ -n "$job_names" ]] && [[ "$job_names" != "" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$job_names" | sed 's/^/  - /'
        fi
    else
        log_verbose "  (Could not extract job names from config, but checking targets directly)"
    fi
    
    # Check for eip-monitor related jobs
    # COO creates jobs with pattern: serviceMonitor/namespace/name/0
    # Check both job names and the full config
    local eip_jobs=""
    if [[ -n "$job_names" ]]; then
        eip_jobs=$(echo "$job_names" | grep -iE "eip|serviceMonitor.*eip" || echo "")
    fi
    
    # Also check if eip-monitor appears in the config or if we have active targets
    if [[ -z "$eip_jobs" ]] && echo "$full_config" | grep -qi "eip-monitor"; then
        eip_jobs="eip-monitor"
    fi
    
    if [[ -z "$eip_jobs" ]]; then
        log_warn "No eip-monitor job found in scrape configs"
        log_verbose "This means Prometheus hasn't created scrape targets from the ServiceMonitor"
        
        # Try to find ServiceMonitor in the config
        if echo "$full_config" | grep -q "eip-monitor"; then
            log_verbose "ServiceMonitor reference found in config, but no scrape job created"
            log_verbose "This usually means Prometheus needs to evaluate the ServiceMonitor"
        fi
        
        return 1
    else
        log_success "✓ Found eip-monitor job(s): $eip_jobs"
        
        # Show the full scrape config for the eip job
        for job in $eip_jobs; do
            log_verbose "Scrape config for job '$job':"
            # Extract the job config block
            # Escape slashes in job name for awk pattern matching
            local escaped_job=$(echo "$job" | sed 's/\//\\\//g')
            # Extract config from job_name line until next job_name or end of scrape_configs
            local job_config=$(echo "$full_config" | awk -v job="$escaped_job" '
                BEGIN { in_job=0 }
                /- job_name: / && $0 ~ job { in_job=1 }
                in_job && /^- job_name: / && $0 !~ job { exit }
                in_job { print }
            ' | head -25)
            if [[ -n "$job_config" ]] && [[ "$job_config" != "" ]]; then
                if [[ "$VERBOSE" == "true" ]]; then
                    echo "$job_config" | sed 's/^/  /'
                fi
            else
                log_verbose "  (Config extraction limited, but job exists in Prometheus)"
            fi
        done
        
        return 0
    fi
}

# Check all Prometheus targets to see what's actually being scraped
check_all_prometheus_targets() {
    local prom_pod="$1"
    local prom_namespace="$2"
    
    log_verbose "Checking all Prometheus targets..."
    
    local targets=$(get_target_status "$prom_pod" "$prom_namespace")
    
    # Get all unique job names
    local all_jobs=$(echo "$targets" | jq -r '.data.activeTargets[].labels.job' 2>/dev/null | sort -u || echo "")
    
    if [[ -n "$all_jobs" ]]; then
        log_verbose "Active scrape jobs in Prometheus:"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$all_jobs" | sed 's/^/  - /'
        fi
        
        # Check if any eip-related jobs exist
        local eip_target_jobs=$(echo "$all_jobs" | grep -i "eip" || echo "")
        if [[ -z "$eip_target_jobs" ]]; then
            log_warn "No eip-monitor targets found in active targets"
            log_verbose "This confirms Prometheus hasn't created targets from the ServiceMonitor"
        else
            log_verbose "Found eip-related targets: $eip_target_jobs"
        fi
    else
        log_verbose "Could not retrieve target information"
    fi
}

# Reload Prometheus configuration
reload_prometheus_config() {
    local prom_pod="$1"
    local prom_namespace="$2"
    
    log_info "Attempting to reload Prometheus configuration..."
    
    # Trigger configuration reload
    local response=$(oc exec "$prom_pod" -n "$prom_namespace" -- \
        curl -s -X POST "http://localhost:9090/-/reload" 2>/dev/null || echo "")
    
    if [[ -n "$response" ]]; then
        log_warn "Prometheus reload response: $response"
    else
        log_info "Prometheus configuration reload triggered"
        log_info "Waiting 30 seconds for configuration to reload..."
        sleep 30
    fi
}

# Check Prometheus logs for errors
check_prometheus_logs() {
    local prom_pod="$1"
    local prom_namespace="$2"
    
    log_info "Checking Prometheus logs for ServiceMonitor-related errors..."
    
    # Get recent logs
    local logs=$(oc logs "$prom_pod" -n "$prom_namespace" --tail=100 2>/dev/null || echo "")
    
    if [[ -z "$logs" ]]; then
        log_warn "Could not retrieve Prometheus logs"
        return 1
    fi
    
    # Check for ServiceMonitor errors
    local errors=$(echo "$logs" | grep -i "servicemonitor\|eip-monitor" | grep -i "error\|fail" | head -5 || echo "")
    
    if [[ -n "$errors" ]]; then
        log_warn "Found ServiceMonitor-related errors in Prometheus logs:"
        echo "$errors" | sed 's/^/  /'
        return 1
    else
        log_info "No ServiceMonitor-related errors found in recent logs"
        return 0
    fi
}

# Restart Prometheus pod (for COO)
restart_prometheus() {
    local prom_pod="$1"
    local prom_namespace="$2"
    
    log_info "Restarting Prometheus pod to reload configuration..."
    log_warn "This will cause a brief interruption in metrics collection"
    
    oc delete pod "$prom_pod" -n "$prom_namespace" &>/dev/null || {
        log_error "Failed to delete Prometheus pod"
        return 1
    }
    
    log_info "Waiting for Prometheus pod to restart..."
    local max_wait=120
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        local new_pod=$(oc get pods -n "$prom_namespace" -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$new_pod" ]]; then
            local pod_status=$(oc get pod "$new_pod" -n "$prom_namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
            if [[ "$pod_status" == "Running" ]]; then
                log_success "✓ Prometheus pod restarted: $new_pod"
                log_info "Waiting 30 seconds for Prometheus to initialize..."
                sleep 30
                return 0
            fi
        fi
        sleep 5
        waited=$((waited + 5))
    done
    
    log_warn "Prometheus pod may not be fully ready yet"
    return 1
}

# Main verification function
verify_metrics() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Verifying Prometheus Metrics Ingestion"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Detect monitoring type
    local detected_type=$(detect_monitoring_type)
    if [[ "$detected_type" != "none" ]]; then
        MONITORING_TYPE="$detected_type"
    fi
    log_info "Detected monitoring type: $MONITORING_TYPE"
    
    # Check ServiceMonitor
    if ! check_servicemonitor; then
        log_error "ServiceMonitor check failed"
        return 1
    fi
    
    # Check service labels
    if ! check_service_labels; then
        log_error "Service labels check failed"
        return 1
    fi
    
    # Check service endpoints
    if ! check_service_endpoints; then
        log_error "Service endpoints check failed"
        log_info "Without endpoints, Prometheus cannot create scrape targets"
        return 1
    fi
    
    # Check MonitoringStack (for COO)
    if ! check_monitoringstack; then
        log_warn "MonitoringStack check had issues, but continuing..."
    fi
    
    # Get Prometheus pod
    local prom_namespace="$NAMESPACE"
    if [[ "$MONITORING_TYPE" == "uwm" ]]; then
        prom_namespace="openshift-user-workload-monitoring"
    fi
    
    local prom_pod=$(get_prometheus_pod "$MONITORING_TYPE")
    if [[ -z "$prom_pod" ]]; then
        log_error "Prometheus pod not found in namespace '$prom_namespace'"
        return 1
    fi
    
    log_verbose "Found Prometheus pod: $prom_pod"
    
    # Check if eip-monitor pod is serving metrics
    local eip_pod=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$eip_pod" ]]; then
        log_error "eip-monitor pod not found"
        return 1
    fi
    
    log_verbose "Verifying eip-monitor pod is serving metrics..."
    local pod_metrics=$(oc exec "$eip_pod" -n "$NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
    if echo "$pod_metrics" | grep -q "eips_configured_total"; then
        log_success "✓ eip-monitor pod is serving metrics"
    else
        log_error "eip-monitor pod is not serving metrics correctly"
        return 1
    fi
    
    # Check Prometheus configuration
    if ! check_prometheus_config "$prom_pod" "$prom_namespace"; then
        log_warn "ServiceMonitor not found in Prometheus configuration"
        log_info "This usually means Prometheus hasn't discovered the ServiceMonitor yet"
        log_info "Possible solutions:"
        log_info "  1. Wait a few minutes for Prometheus to discover the ServiceMonitor"
        log_info "  2. Restart Prometheus pod to force configuration reload"
        log_info "  3. Verify MonitoringStack resourceSelector matches ServiceMonitor labels"
        
        # Offer to reload/restart Prometheus
        if [[ "$MONITORING_TYPE" == "coo" ]]; then
            log_info ""
            log_info "Would you like to restart Prometheus to reload configuration? (This will cause a brief interruption)"
            log_info "You can do this manually with: oc delete pod $prom_pod -n $prom_namespace"
        fi
    else
        # ServiceMonitor is in config, check if it's in scrape configs
        if ! check_prometheus_scrape_configs "$prom_pod" "$prom_namespace"; then
            log_warn "ServiceMonitor is in configuration but not in scrape configs"
            log_info "This means Prometheus knows about the ServiceMonitor but hasn't created targets"
            log_info "Possible causes:"
            log_info "  1. Service has no endpoints (no pods matching service selector)"
            log_info "  2. Prometheus needs to reload/restart to evaluate ServiceMonitor"
            log_info "  3. Namespace selector mismatch"
        fi
    fi
    
    # Check Prometheus logs for errors
    check_prometheus_logs "$prom_pod" "$prom_namespace"
    
    # Check all targets to see what jobs exist
    check_all_prometheus_targets "$prom_pod" "$prom_namespace"
    
    # Check Prometheus target status
    log_verbose "Checking if Prometheus has discovered the target..."
    local targets=$(get_target_status "$prom_pod" "$prom_namespace")
    
    # Get all eip target health statuses (handle multiple targets)
    local target_healths=$(echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | .health' 2>/dev/null || echo "")
    
    # Check if any target is up
    local has_up_target=false
    local first_target_status=""
    if [[ -n "$target_healths" ]]; then
        # Get first target status (trimmed of all whitespace including newlines)
        first_target_status=$(echo "$target_healths" | head -1 | xargs)
        # Check if any target is "up" (handle newlines properly)
        if echo "$target_healths" | grep -x "up" >/dev/null 2>&1; then
            has_up_target=true
        fi
    fi
    
    if [[ "$has_up_target" == "true" ]] || [[ "$first_target_status" == "up" ]]; then
        log_success "✓ Prometheus has discovered eip-monitor target"
        log_success "✓ Prometheus target is healthy (up)"
    else
        log_warn "Prometheus target status: ${first_target_status:-unknown}"
        log_verbose "Target details:"
        local target_info=$(echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | "  Job: \(.labels.job), Health: \(.health), Last Scrape: \(.lastScrape), Last Error: \(.lastError)"' 2>/dev/null || echo "")
        if [[ -n "$target_info" ]]; then
            if [[ "$VERBOSE" == "true" ]]; then
                echo "$target_info"
            fi
        else
            log_warn "  No eip-monitor target found in Prometheus"
            log_verbose ""
            log_verbose "Diagnosis:"
            log_verbose "  - ServiceMonitor exists and is in Prometheus config ✓"
            log_verbose "  - Service has endpoints (checked above)"
            log_verbose "  - But Prometheus hasn't created scrape targets"
            log_verbose ""
            log_verbose "This usually means Prometheus needs to evaluate the ServiceMonitor."
            log_verbose "With COO, this can happen if:"
            log_verbose "  1. Prometheus was started before the ServiceMonitor was created"
            log_verbose "  2. The MonitoringStack hasn't triggered a configuration reload"
            log_verbose "  3. There's a timing issue with ServiceMonitor discovery"
            log_verbose ""
            log_verbose "Recommended fix:"
            log_verbose "  Run: ./scripts/fix-prometheus-discovery.sh"
            log_verbose "  Or manually: oc delete pod $prom_pod -n $prom_namespace"
            log_verbose ""
            log_verbose "Additional troubleshooting:"
            log_verbose "  1. Verify MonitoringStack resourceSelector:"
            log_verbose "     oc get monitoringstack eip-monitoring-stack -n $NAMESPACE -o yaml | grep -A 3 resourceSelector"
            log_verbose "  2. Check ServiceMonitor labels match resourceSelector:"
            log_verbose "     oc get servicemonitor $sm_name -n $NAMESPACE -o yaml | grep -A 5 labels"
            log_verbose "  3. Check Prometheus logs:"
            log_verbose "     oc logs $prom_pod -n $prom_namespace --tail=200 | grep -i servicemonitor"
        fi
    fi
    
    # Wait for Prometheus to scrape and ingest metrics
    log_verbose "Waiting for Prometheus to scrape metrics (may take a few minutes)..."
    
    local attempt=1
    local metric_found=false
    
    while [[ $attempt -le $MAX_ATTEMPTS ]]; do
        log_verbose "Attempt $attempt/$MAX_ATTEMPTS: Querying Prometheus..."
        
        # Get last scrape time
        local scrape_time=$(echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip")) | .lastScrape' 2>/dev/null || echo "")
        if [[ -n "$scrape_time" ]] && [[ "$scrape_time" != "null" ]]; then
            log_verbose "  Last scrape: $scrape_time"
        fi
        
        # Try to find any EIP metric
        if check_metric_exists "$prom_pod" "$prom_namespace" "eips_configured_total"; then
            log_success "✓ Found eips_configured_total in Prometheus!"
            metric_found=true
            break
        fi
        
        # Try other common metrics
        for metric in "eips_assigned_total" "cpic_success_total" "eip_utilization_percent"; do
            if check_metric_exists "$prom_pod" "$prom_namespace" "$metric"; then
                log_success "✓ Found $metric in Prometheus!"
                metric_found=true
                break 2
            fi
        done
        
        if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
            log_verbose "  Metric not found yet, waiting ${WAIT_BETWEEN_ATTEMPTS}s before retry..."
            sleep "$WAIT_BETWEEN_ATTEMPTS"
            
            # Refresh targets
            targets=$(get_target_status "$prom_pod" "$prom_namespace")
        fi
        
        ((attempt++))
    done
    
    if [[ "$metric_found" == "true" ]]; then
        log_success "✓ Metrics are available in Prometheus!"
        
        # Show sample metrics
        log_verbose "Sample metrics in Prometheus:"
        for metric in "eips_configured_total" "eips_assigned_total" "cpic_success_total"; do
            local result=$(query_prometheus "$prom_pod" "$prom_namespace" "$metric")
            local value=$(echo "$result" | jq -r '.data.result[0].value[1]' 2>/dev/null || echo "")
            if [[ -n "$value" ]] && [[ "$value" != "null" ]]; then
                log_verbose "  $metric = $value"
            fi
        done
        
        return 0
    else
        log_error "Metrics not found in Prometheus after $MAX_ATTEMPTS attempts"
        log_verbose "Troubleshooting steps:"
        log_verbose "1. Check Prometheus logs: oc logs $prom_pod -n $prom_namespace"
        log_verbose "2. Verify ServiceMonitor labels match service labels"
        log_verbose "3. Check if Prometheus has relabeling rules that might drop metrics"
        log_verbose "4. Verify the metrics endpoint is accessible from Prometheus pod"
        
        # Show Prometheus configuration
        log_verbose "Prometheus target configuration:"
        if [[ "$VERBOSE" == "true" ]]; then
            echo "$targets" | jq -r '.data.activeTargets[] | select(.labels.job | contains("eip"))' 2>/dev/null || echo "  No target configuration found"
        fi
        
        return 1
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --monitoring-type)
                MONITORING_TYPE="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main execution
main() {
    parse_args "$@"
    verify_metrics
}

# Run main function
main "$@"

