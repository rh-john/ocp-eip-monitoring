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
BLUE='\033[0;34m'
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
    local endpoints=$(oc get endpoints "$SERVICE_NAME" -n "$NAMESPACE" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || echo "")
    [[ -n "$endpoints" ]]
}

test_health_endpoint() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    oc exec "$pod_name" -n "$NAMESPACE" -- curl -sf http://localhost:8080/health &>/dev/null
}

test_metrics_endpoint() {
    local pod_name=$(oc get pods -n "$NAMESPACE" -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pod_name" ]]; then
        return 1
    fi
    
    oc exec "$pod_name" -n "$NAMESPACE" -- curl -sf http://localhost:8080/metrics | grep -q "eips_configured_total"
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
    
    oc logs "$pod_name" -n "$NAMESPACE" --tail=20 | grep -q "Starting comprehensive metrics collection"
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
    oc get servicemonitor "$SERVICE_NAME" -n "$NAMESPACE" &>/dev/null
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
