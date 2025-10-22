#!/bin/bash
# deploy-test-eips.sh - Dynamic EgressIP deployment with auto-discovery
#
# This script automatically discovers available EgressIP ranges from your OpenShift
# cluster and creates comprehensive test EgressIP configurations for monitoring validation.
#
# Usage: ./deploy-test-eips.sh
#
# Requirements:
# - oc CLI logged into OpenShift cluster
# - jq installed
# - Nodes labeled with k8s.ovn.org/egress-assignable=""

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check oc CLI
    if ! command -v oc &> /dev/null; then
        log_error "OpenShift CLI (oc) is not installed"
        exit 1
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed (required for JSON parsing)"
        exit 1
    fi
    
    # Check cluster connectivity
    if ! oc whoami &>/dev/null; then
        log_error "Not logged into OpenShift cluster. Please run 'oc login' first"
        exit 1
    fi
    
    log_success "Prerequisites validated"
}

# Source the discovery functions
source_discovery_functions() {
    if [ -f "./discover-eip-ranges.sh" ]; then
        source ./discover-eip-ranges.sh
    else
        log_error "discover-eip-ranges.sh not found in current directory"
        exit 1
    fi
}

# Main deployment function
main() {
    echo ""
    echo "🚀 EgressIP Test Deployment with Dynamic Discovery"
    echo "================================================="
    echo ""
    
    check_prerequisites
    source_discovery_functions
    
    log_info "Current cluster: $(oc whoami --show-server 2>/dev/null)"
    log_info "Current user: $(oc whoami 2>/dev/null)"
    echo ""
    
    log_info "Discovering EgressIP configuration from cluster..."
    
    # Get the first available EgressIP CIDR
    CIDR=$(get_first_eip_cidr)
    
    if [ -z "$CIDR" ]; then
        log_error "No EgressIP configuration found on nodes"
        echo ""
        echo "To enable EgressIP testing:"
        echo "1. Label nodes for egress assignment:"
        echo "   oc label node <worker-node> k8s.ovn.org/egress-assignable=''"
        echo "2. Verify cloud provider has configured egress IP ranges"
        echo "3. Check node annotations with:"
        echo "   oc get nodes -o yaml | grep -A5 -B5 egress-ipconfig"
        exit 1
    fi
    
    log_success "Found EgressIP CIDR: $CIDR"
    
    # Validate we have enough capacity
    if ! check_eip_capacity "$CIDR" 15; then
        log_warn "Limited IP capacity available - proceeding with available IPs"
    fi
    
    # Generate test IP addresses
    log_info "Generating test IP addresses..."
    
    # Use portable method instead of readarray (not available in all bash versions)
    TEST_IPS=()
    while IFS= read -r line; do
        TEST_IPS+=("$line")
    done < <(generate_test_ips "$CIDR" 15)
    
    if [ ${#TEST_IPS[@]} -lt 10 ]; then
        log_error "Could not generate enough IP addresses from CIDR $CIDR"
        log_error "Generated only ${#TEST_IPS[@]} IPs, need at least 10"
        exit 1
    fi
    
    log_success "Generated ${#TEST_IPS[@]} test IP addresses"
    log_info "Sample IPs: ${TEST_IPS[0]}, ${TEST_IPS[1]}, ${TEST_IPS[2]}, ..."
    echo ""
    
    log_info "Creating test namespaces..."
    
    # Create namespaces with error handling
    create_namespace() {
        local name="$1"
        local labels="$2"
        
        if oc create namespace "$name" --dry-run=client -o yaml | oc apply -f - &>/dev/null; then
            log_success "Namespace '$name' created/verified"
        else
            log_warn "Namespace '$name' already exists"
        fi
        
        if [ -n "$labels" ]; then
            oc label namespace "$name" $labels --overwrite &>/dev/null
        fi
    }
    
    create_namespace "web-apps" "name=web-apps"
    create_namespace "prod-db" "environment=production tier=database"
    create_namespace "dev-env" "environment=development"
    create_namespace "api-services" "app=api-gateway"
    
    echo ""
    log_info "Deploying EgressIP configurations with discovered IPs..."
    
    # Deploy EgressIP resources
    cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-web
  labels:
    test-suite: eip-monitoring
    environment: test
spec:
  egressIPs:
  - ${TEST_IPS[0]}
  - ${TEST_IPS[1]}
  namespaceSelector:
    matchLabels:
      name: web-apps
---
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-database
  labels:
    test-suite: eip-monitoring
    environment: test
spec:
  egressIPs:
  - ${TEST_IPS[2]}
  - ${TEST_IPS[3]}
  - ${TEST_IPS[4]}
  namespaceSelector:
    matchLabels:
      environment: production
      tier: database
---
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-dev
  labels:
    test-suite: eip-monitoring
    environment: test
spec:
  egressIPs:
  - ${TEST_IPS[5]}
  namespaceSelector:
    matchLabels:
      environment: development
---
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-ha-api
  labels:
    test-suite: eip-monitoring
    environment: test
spec:
  egressIPs:
  - ${TEST_IPS[6]}
  - ${TEST_IPS[7]}
  - ${TEST_IPS[8]}
  - ${TEST_IPS[9]}
  namespaceSelector:
    matchLabels:
      app: api-gateway
EOF

    echo ""
    log_success "Test EgressIPs deployed successfully!"
    
    # Summary
    echo ""
    echo "📊 Deployment Summary"
    echo "===================="
    echo "CIDR discovered: $CIDR"
    echo "IPs allocated: ${#TEST_IPS[@]}"
    echo "EgressIPs created: 4"
    echo "Namespaces created: 4"
    echo ""
    
    # Wait a moment for resources to be processed
    log_info "Waiting for EgressIP assignment..."
    sleep 5
    
    # Verification
    echo "🔍 Verification Commands & Results"
    echo "================================="
    echo ""
    
    echo "📋 EgressIP Resources:"
    oc get egressip -l test-suite=eip-monitoring
    echo ""
    
    echo "📋 EgressIP Status:"
    oc get egressip -l test-suite=eip-monitoring -o wide
    echo ""
    
    echo "📋 CloudPrivateIPConfig Resources:"
    oc get cloudprivateipconfig 2>/dev/null || log_warn "CloudPrivateIPConfig resources not yet created"
    echo ""
    
    # Check if monitoring is deployed
    if oc get deployment eip-monitor -n eip-monitoring &>/dev/null; then
        log_info "EIP Monitor detected - checking metrics..."
        
        # Try to get metrics
        if oc get service eip-monitor -n eip-monitoring &>/dev/null; then
            echo "📊 Current EIP Metrics (sample):"
            oc exec -n eip-monitoring deployment/eip-monitor -- curl -s http://localhost:8080/metrics 2>/dev/null | grep -E "eips_(configured|assigned|unassigned)_total" | head -5 || log_warn "Metrics not yet available"
        fi
    else
        log_info "Deploy EIP Monitor to see metrics for these test EgressIPs"
    fi
    
    echo ""
    echo "🎯 Next Steps"
    echo "============"
    echo "1. Monitor EgressIP assignment: watch oc get egressip -o wide"
    echo "2. Check CPIC status: oc get cloudprivateipconfig"
    echo "3. Deploy EIP Monitor to collect metrics on these test resources"
    echo "4. Test your monitoring alerts and dashboards"
    echo "5. Clean up when done: oc delete egressip -l test-suite=eip-monitoring"
    echo ""
    
    log_success "EgressIP test deployment completed!"
}

# Cleanup function (can be called separately)
cleanup_test_resources() {
    echo ""
    log_info "Cleaning up test EgressIP resources..."
    
    # Delete EgressIPs
    if oc delete egressip -l test-suite=eip-monitoring --timeout=30s; then
        log_success "Test EgressIPs deleted"
    else
        log_warn "Some EgressIPs may not have been deleted"
    fi
    
    # Delete namespaces
    for ns in web-apps prod-db dev-env api-services; do
        if oc delete namespace "$ns" --timeout=60s &>/dev/null; then
            log_success "Namespace '$ns' deleted"
        else
            log_warn "Namespace '$ns' may not have been deleted or didn't exist"
        fi
    done
    
    log_success "Cleanup completed"
}

# Handle command line arguments
case "${1:-deploy}" in
    "deploy")
        main
        ;;
    "cleanup")
        cleanup_test_resources
        ;;
    "discover")
        check_prerequisites
        source_discovery_functions
        get_eip_ranges
        ;;
    "--help"|"-h"|"help")
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  deploy    Deploy test EgressIP resources (default)"
        echo "  cleanup   Remove all test resources"
        echo "  discover  Show available EgressIP ranges"
        echo "  help      Show this help message"
        ;;
    *)
        log_error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac
