#!/bin/bash

# Get script directory for proper path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
#
# EIP Monitor Deployment Testing Script
# Comprehensive testing for the EIP monitoring deployment
#

set -euo pipefail

# Configuration
NAMESPACE="eip-monitoring"
SERVICE_NAME="eip-monitor"
DEPLOYMENT_NAME="eip-monitor"
TIMEOUT=300

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'  # Light blue (cyan)
NC='\033[0m' # No Color

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
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

# Test execution functions
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    ((TOTAL_TESTS++))
    log_info "Running test: $test_name"
    
    if $test_function; then
        log_success "✅ $test_name"
        ((TESTS_PASSED++))
        return 0
    else
        log_error "❌ $test_name"
        
        # Provide specific diagnostics for service endpoints failure
        if [[ "$test_name" == "Service endpoints available" ]]; then
            local service_selector=$(oc get service "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.selector}' 2>/dev/null || echo "{}")
            local pod_labels=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null || echo "{}")
            local endpoints_subsets=$(oc get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets}' 2>/dev/null || echo "")
            
            log_info "    Service selector: $service_selector"
            log_info "    Pod labels: $pod_labels"
            if [[ -z "$endpoints_subsets" ]] || [[ "$endpoints_subsets" == "null" ]]; then
                log_warn "    ⚠️  No pods match the service selector!"
                log_info "    To fix: Update service selector or pod labels to match"
                log_info "    Run: ./scripts/fix-service-labels.sh"
            else
                local not_ready=$(oc get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[0].notReadyAddresses[0].ip}' 2>/dev/null || echo "")
                if [[ -n "$not_ready" ]]; then
                    log_warn "    ⚠️  Pods exist but are not ready yet"
                    log_info "    Check pod status: oc get pods -n $NAMESPACE -l app=eip-monitor"
                fi
            fi
        fi
        
        ((TESTS_FAILED++))
        return 1
    fi
}

# Individual test functions
test_namespace_exists() {
    oc get namespace "$NAMESPACE" &>/dev/null
}

test_deployment_exists() {
    oc get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" &>/dev/null
}

test_service_exists() {
    oc get service "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null
}

test_pods_running() {
    local pod_status=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
    [[ "$pod_status" == "Running" ]]
}

test_pods_ready() {
    local ready_replicas=$(oc get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    local desired_replicas=$(oc get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    [[ "$ready_replicas" -eq "$desired_replicas" ]]
}

test_service_endpoints() {
    # First check if service exists
    if ! oc get service "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null; then
        return 1
    fi
    
    # Check if endpoints resource exists
    if ! oc get endpoints "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null; then
        return 1
    fi
    
    # Check if endpoints object has any subsets (even empty subsets array means no matching pods)
    local has_subsets=$(oc get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets}' 2>/dev/null || echo "")
    if [[ -z "$has_subsets" ]] || [[ "$has_subsets" == "null" ]]; then
        # No subsets means no pods match the service selector
        return 1
    fi
    
    # Check for ready endpoints (addresses, not notReadyAddresses)
    local endpoints=$(oc get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    
    # If no ready endpoints, check if there are notReadyAddresses (pods exist but not ready)
    if [[ -z "$endpoints" ]]; then
        local not_ready=$(oc get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[0].notReadyAddresses[0].ip}' 2>/dev/null || echo "")
        if [[ -n "$not_ready" ]]; then
            # Pods exist but not ready - this is a different issue
            return 1
        fi
        # No ready endpoints and no not-ready endpoints means no matching pods
        return 1
    fi
    
    [[ -n "$endpoints" ]]
}

test_health_endpoint() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    # Health endpoint may return 503 initially before first metrics collection
    # Test that endpoint responds (200 or 503 are both acceptable)
    local response=$(oc exec "$pod_name" -n "$NAMESPACE" -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health 2>/dev/null || echo "000")
    [[ "$response" == "200" ]] || [[ "$response" == "503" ]]
}

test_metrics_endpoint() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    # Check that the endpoint responds and returns content
    # prometheus_client.generate_latest() always returns metrics (even default Python metrics)
    # So we just need to verify the endpoint responds with non-empty content
    local metrics_output=$(oc exec "$pod_name" -n "$NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
    
    # Check that we got a response (not empty) - this indicates the endpoint is working
    # The specific metric "eips_configured_total" may not exist until first collection completes
    [[ -n "$metrics_output" ]]
}

test_prometheus_metrics_format() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    local metrics_output=$(oc exec "$pod_name" -n "$NAMESPACE" -- curl -sf http://localhost:8080/metrics 2>/dev/null || echo "")
    
    # Check for required metrics
    echo "$metrics_output" | grep -q "eips_configured_total" &&
    echo "$metrics_output" | grep -q "eips_assigned_total" &&
    echo "$metrics_output" | grep -q "cpic_success_total" &&
    echo "$metrics_output" | grep -q "eip_scrape_errors_total"
}

test_logs_present() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    # Wait a moment for logs to accumulate
    sleep 2
    
    # Check for any of these log messages that indicate the service is running
    # Look in the last 100 lines for startup or metrics collection messages
    local log_output=$(oc logs "$pod_name" -n "$NAMESPACE" --tail=100 2>/dev/null || echo "")
    
    # Check for multiple patterns that indicate the service is working
    # Updated to match actual log messages from metrics_server.py
    echo "$log_output" | grep -q "Starting EIP Metrics Server" ||
    echo "$log_output" | grep -q "Starting optimized metrics collection" ||
    echo "$log_output" | grep -q "Optimized metrics collection completed" ||
    echo "$log_output" | grep -q "Found.*EIP-enabled nodes" ||
    echo "$log_output" | grep -q "Global metrics"
}

test_openshift_permissions() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    # Test if the pod can access OpenShift resources
    oc exec "$pod_name" -n "$NAMESPACE" -- oc get nodes -l k8s.ovn.org/egress-assignable=true &>/dev/null
}

test_security_context() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    # Check that pod is running as non-root
    local run_as_user=$(oc get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.spec.securityContext.runAsNonRoot}' 2>/dev/null || echo "false")
    [[ "$run_as_user" == "true" ]]
}

test_resource_limits() {
    local memory_limit=$(oc get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "")
    local cpu_limit=$(oc get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || echo "")
    
    [[ -n "$memory_limit" ]] && [[ -n "$cpu_limit" ]]
}

test_servicemonitor_exists() {
    # Check for ServiceMonitor with -coo suffix (COO monitoring stack - uses monitoring.rhobs API)
    oc get servicemonitor.monitoring.rhobs "${SERVICE_NAME}-coo" -n "$NAMESPACE" &>/dev/null || \
    oc get servicemonitor "${SERVICE_NAME}-coo" -n "$NAMESPACE" &>/dev/null || \
    # Check for ServiceMonitor with -uwm suffix (UWM monitoring stack - uses monitoring.coreos.com API)
    oc get servicemonitor.monitoring.coreos.com "${SERVICE_NAME}-uwm" -n "$NAMESPACE" &>/dev/null || \
    oc get servicemonitor "${SERVICE_NAME}-uwm" -n "$NAMESPACE" &>/dev/null || \
    # Fallback to base name if neither -coo nor -uwm exist
    oc get servicemonitor "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null
}

test_prometheusrule_exists() {
    # First check if PrometheusRule CRD exists (either API version)
    if ! oc get crd prometheusrules.monitoring.coreos.com &>/dev/null && \
       ! oc get crd prometheusrules.monitoring.rhobs &>/dev/null; then
        # CRD doesn't exist, skip test
        return 0
    fi
    
    # Try multiple naming patterns and API versions
    # Check for PrometheusRule with -alerts-coo suffix (COO monitoring stack)
    oc get prometheusrule.monitoring.rhobs "${SERVICE_NAME}-alerts-coo" -n "$NAMESPACE" &>/dev/null && return 0
    oc get prometheusrule "${SERVICE_NAME}-alerts-coo" -n "$NAMESPACE" &>/dev/null && return 0
    # Check for PrometheusRule with -coo suffix (COO monitoring stack)
    oc get prometheusrule.monitoring.rhobs "${SERVICE_NAME}-coo" -n "$NAMESPACE" &>/dev/null && return 0
    oc get prometheusrule "${SERVICE_NAME}-coo" -n "$NAMESPACE" &>/dev/null && return 0
    # Check for PrometheusRule with -uwm suffix (UWM monitoring stack)
    oc get prometheusrule.monitoring.coreos.com "${SERVICE_NAME}-uwm" -n "$NAMESPACE" &>/dev/null && return 0
    oc get prometheusrule "${SERVICE_NAME}-uwm" -n "$NAMESPACE" &>/dev/null && return 0
    # Check for common alert name pattern
    oc get prometheusrule "${SERVICE_NAME}-alerts" -n "$NAMESPACE" &>/dev/null && return 0
    # Check for base name
    oc get prometheusrule "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null && return 0
    
    # If none found, check if any PrometheusRule exists in the namespace (might be named differently)
    local pr_count=$(oc get prometheusrule -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$pr_count" -gt 0 ]]; then
        # At least one PrometheusRule exists, consider it a pass
        return 0
    fi
    
    # No PrometheusRule found
    return 1
}

# Performance and load tests
test_metrics_performance() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    # Test response time (should be under 5 seconds)
    local start_time=$(date +%s)
    oc exec "$pod_name" -n "$NAMESPACE" -- curl -sf http://localhost:8080/metrics &>/dev/null
    local end_time=$(date +%s)
    local response_time=$((end_time - start_time))
    
    [[ $response_time -lt 5 ]]
}

# Comprehensive test execution
run_all_tests() {
    log_info "Starting comprehensive EIP Monitor deployment tests"
    log_info "Namespace: $NAMESPACE"
    log_info "Deployment: $DEPLOYMENT_NAME"
    log_info "Service: $SERVICE_NAME"
    echo ""
    
    # Basic deployment tests
    run_test "Namespace exists" test_namespace_exists
    run_test "Deployment exists" test_deployment_exists
    run_test "Service exists" test_service_exists
    run_test "Pods running" test_pods_running
    run_test "Pods ready" test_pods_ready
    run_test "Service endpoints available" test_service_endpoints
    
    echo ""
    log_info "Testing application functionality..."
    
    # Application functionality tests
    run_test "Health endpoint responds" test_health_endpoint
    run_test "Metrics endpoint responds" test_metrics_endpoint
    run_test "Prometheus metrics format" test_prometheus_metrics_format
    run_test "Application logs present" test_logs_present
    
    echo ""
    log_info "Testing security and permissions..."
    
    # Security tests
    run_test "OpenShift API permissions" test_openshift_permissions
    run_test "Security context configured" test_security_context
    run_test "Resource limits set" test_resource_limits
    
    echo ""
    log_info "Testing monitoring integration..."
    
    # Monitoring tests
    run_test "ServiceMonitor exists" test_servicemonitor_exists
    run_test "PrometheusRule exists" test_prometheusrule_exists
    run_test "Metrics performance" test_metrics_performance
    
    echo ""
    log_info "Test Summary"
    log_info "============"
    log_success "Tests Passed: $TESTS_PASSED"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        log_error "Tests Failed: $TESTS_FAILED"
    else
        log_success "Tests Failed: $TESTS_FAILED"
    fi
    log_info "Total Tests: $TOTAL_TESTS"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo ""
        log_success "🎉 All tests passed! EIP Monitor is working correctly."
        return 0
    else
        echo ""
        log_error "❌ Some tests failed. Please check the deployment."
        return 1
    fi
}

# Cleanup function
cleanup_test_resources() {
    log_info "Cleaning up test resources..."
    # Add any cleanup logic here if needed
}

# Show test information
show_test_info() {
    cat << EOF
EIP Monitor Deployment Test Suite

This script performs comprehensive testing of the EIP monitoring deployment:

Test Categories:
  🏗️  Deployment Tests     - Basic Kubernetes resource validation
  🚀 Application Tests     - Service functionality and endpoints  
  🔒 Security Tests        - Permissions and security context
  📊 Monitoring Tests      - Prometheus integration and performance

Usage:
  $0                       # Run all tests
  $0 --info               # Show this information
  $0 --cleanup            # Clean up test resources

Prerequisites:
  - OpenShift CLI (oc) configured and authenticated
  - EIP Monitor deployed in '$NAMESPACE' namespace
  - Appropriate permissions to access the namespace

EOF
}

# Main execution
main() {
    case "${1:-}" in
        --info|-i)
            show_test_info
            exit 0
            ;;
        --cleanup)
            cleanup_test_resources
            exit 0
            ;;
        --help|-h)
            show_test_info
            exit 0
            ;;
        "")
            run_all_tests
            ;;
        *)
            log_error "Unknown option: $1"
            show_test_info
            exit 1
            ;;
    esac
}

# Trap to handle cleanup on exit
trap cleanup_test_resources EXIT

# Run main function
main "$@"
