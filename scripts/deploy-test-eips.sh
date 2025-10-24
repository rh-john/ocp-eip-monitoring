#!/bin/bash

# Get script directory for proper path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
#
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

# Default timeouts
DEFAULT_EGRESSIP_TIMEOUT="30s"
DEFAULT_NAMESPACE_TIMEOUT="60s"

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
    if [ -f "$SCRIPT_DIR/discover-eip-ranges.sh" ]; then
        source "$SCRIPT_DIR/discover-eip-ranges.sh"
    else
        log_error "discover-eip-ranges.sh not found in script directory: $SCRIPT_DIR"
        exit 1
    fi
}

# Main deployment function
main() {
    local ip_count="${1:-15}"      # Default to 15 IPs if not specified
    local namespace_count="${2:-4}" # Default to 4 namespaces if not specified
    
    # Validate IP count
    if ! [[ "$ip_count" =~ ^[0-9]+$ ]] || [ "$ip_count" -lt 1 ] || [ "$ip_count" -gt 200 ]; then
        log_error "IP count must be a number between 1 and 200"
        exit 1
    fi
    
    # Validate namespace count
    if ! [[ "$namespace_count" =~ ^[0-9]+$ ]] || [ "$namespace_count" -lt 1 ] || [ "$namespace_count" -gt 200 ]; then
        log_error "Namespace count must be a number between 1 and 200"
        exit 1
    fi
    
    echo ""
    echo "🚀 EgressIP Test Deployment with Dynamic Discovery"
    echo "================================================="
    echo ""
    
    check_prerequisites
    source_discovery_functions
    
    log_info "Current cluster: $(oc whoami --show-server 2>/dev/null)"
    log_info "Current user: $(oc whoami 2>/dev/null)"
    log_info "Requested IP count: $ip_count"
    log_info "Requested namespace count: $namespace_count"
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
    if ! check_eip_capacity "$CIDR" "$ip_count"; then
        log_warn "Limited IP capacity available - proceeding with available IPs"
    fi
    
    # Generate test IP addresses
    log_info "Generating $ip_count test IP addresses..."
    
    # Use portable method instead of readarray (not available in all bash versions)
    TEST_IPS=()
    while IFS= read -r line; do
        TEST_IPS+=("$line")
    done < <(generate_test_ips "$CIDR" "$ip_count")
    
    if [ ${#TEST_IPS[@]} -lt $ip_count ]; then
        log_error "Could not generate enough IP addresses from CIDR $CIDR"
        log_error "Generated only ${#TEST_IPS[@]} IPs, need $ip_count"
        exit 1
    fi
    
    log_success "Generated ${#TEST_IPS[@]} test IP addresses"
    log_info "Sample IPs: ${TEST_IPS[0]}, ${TEST_IPS[1]}, ${TEST_IPS[2]}, ..."
    echo ""
    
    log_info "Creating $namespace_count test namespaces..."
    
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
    
    # Define namespace templates with different characteristics
    # This array provides diverse labels for up to 100 namespaces
    local namespace_templates=(
        "test-ns-1:environment=production tier=database"
        "test-ns-2:environment=development"
        "test-ns-3:app=api-gateway"
        "test-ns-4:app=monitoring tier=observability"
        "test-ns-5:environment=staging"
        "test-ns-6:environment=test"
        "test-ns-7:app=frontend tier=presentation"
        "test-ns-8:app=backend tier=service"
        "test-ns-9:app=cache tier=infrastructure"
        "test-ns-10:app=queue tier=infrastructure"
        "test-ns-11:app=storage tier=infrastructure"
        "test-ns-12:app=security tier=security"
        "test-ns-13:app=analytics tier=service"
        "test-ns-14:app=integration tier=service"
        "test-ns-15:app=mobile tier=presentation"
        "test-ns-16:app=admin tier=management"
        "test-ns-17:app=reporting tier=service"
        "test-ns-18:app=workflow tier=service"
        "test-ns-19:app=notification tier=service"
        "test-ns-20:app=test tier=service"
        "test-ns-21:app=web tier=presentation"
        "test-ns-22:app=api tier=service"
        "test-ns-23:app=db tier=database"
        "test-ns-24:app=redis tier=cache"
        "test-ns-25:app=elasticsearch tier=search"
        "test-ns-26:app=kafka tier=messaging"
        "test-ns-27:app=rabbitmq tier=messaging"
        "test-ns-28:app=postgres tier=database"
        "test-ns-29:app=mysql tier=database"
        "test-ns-30:app=mongodb tier=database"
        "test-ns-31:app=nginx tier=proxy"
        "test-ns-32:app=haproxy tier=proxy"
        "test-ns-33:app=consul tier=service-discovery"
        "test-ns-34:app=etcd tier=coordination"
        "test-ns-35:app=zookeeper tier=coordination"
        "test-ns-36:app=prometheus tier=monitoring"
        "test-ns-37:app=grafana tier=monitoring"
        "test-ns-38:app=jaeger tier=tracing"
        "test-ns-39:app=zipkin tier=tracing"
        "test-ns-40:app=fluentd tier=logging"
        "test-ns-41:app=logstash tier=logging"
        "test-ns-42:app=elasticsearch tier=logging"
        "test-ns-43:app=kibana tier=logging"
        "test-ns-44:app=splunk tier=logging"
        "test-ns-45:app=datadog tier=monitoring"
        "test-ns-46:app=newrelic tier=monitoring"
        "test-ns-47:app=appdynamics tier=monitoring"
        "test-ns-48:app=dynatrace tier=monitoring"
        "test-ns-49:app=sumo tier=monitoring"
        "test-ns-50:app=pingdom tier=monitoring"
        "test-ns-51:app=jenkins tier=ci-cd"
        "test-ns-52:app=gitlab tier=ci-cd"
        "test-ns-53:app=github tier=ci-cd"
        "test-ns-54:app=bitbucket tier=ci-cd"
        "test-ns-55:app=azure-devops tier=ci-cd"
        "test-ns-56:app=circleci tier=ci-cd"
        "test-ns-57:app=travis tier=ci-cd"
        "test-ns-58:app=bamboo tier=ci-cd"
        "test-ns-59:app=teamcity tier=ci-cd"
        "test-ns-60:app=spinnaker tier=ci-cd"
        "test-ns-61:app=terraform tier=infrastructure"
        "test-ns-62:app=ansible tier=infrastructure"
        "test-ns-63:app=puppet tier=infrastructure"
        "test-ns-64:app=chef tier=infrastructure"
        "test-ns-65:app=vagrant tier=infrastructure"
        "test-ns-66:app=docker tier=containerization"
        "test-ns-67:app=kubernetes tier=orchestration"
        "test-ns-68:app=helm tier=package-management"
        "test-ns-69:app=istio tier=service-mesh"
        "test-ns-70:app=linkerd tier=service-mesh"
        "test-ns-71:app=envoy tier=proxy"
        "test-ns-72:app=traefik tier=proxy"
        "test-ns-73:app=kong tier=api-gateway"
        "test-ns-74:app=zuul tier=api-gateway"
        "test-ns-75:app=spring-cloud tier=microservices"
        "test-ns-76:app=micronaut tier=microservices"
        "test-ns-77:app=quarkus tier=microservices"
        "test-ns-78:app=vertx tier=microservices"
        "test-ns-79:app=akka tier=microservices"
        "test-ns-80:app=play tier=microservices"
        "test-ns-81:app=dropwizard tier=microservices"
        "test-ns-82:app=spark tier=microservices"
        "test-ns-83:app=jersey tier=microservices"
        "test-ns-84:app=restlet tier=microservices"
        "test-ns-85:app=cxf tier=microservices"
        "test-ns-86:app=axis2 tier=microservices"
        "test-ns-87:app=metro tier=microservices"
        "test-ns-88:app=wsdl tier=microservices"
        "test-ns-89:app=soap tier=microservices"
        "test-ns-90:app=rest tier=microservices"
        "test-ns-91:app=graphql tier=microservices"
        "test-ns-92:app=grpc tier=microservices"
        "test-ns-93:app=thrift tier=microservices"
        "test-ns-94:app=avro tier=microservices"
        "test-ns-95:app=protobuf tier=microservices"
        "test-ns-96:app=json tier=microservices"
        "test-ns-97:app=xml tier=microservices"
        "test-ns-98:app=yaml tier=microservices"
        "test-ns-99:app=toml tier=microservices"
        "test-ns-100:app=config tier=microservices"
        "test-ns-101:app=gateway tier=api-gateway"
        "test-ns-102:app=loadbalancer tier=infrastructure"
        "test-ns-103:app=firewall tier=security"
        "test-ns-104:app=vpn tier=security"
        "test-ns-105:app=proxy tier=infrastructure"
        "test-ns-106:app=cdn tier=infrastructure"
        "test-ns-107:app=backup tier=infrastructure"
        "test-ns-108:app=disaster-recovery tier=infrastructure"
        "test-ns-109:app=compliance tier=security"
        "test-ns-110:app=audit tier=security"
        "test-ns-111:app=governance tier=management"
        "test-ns-112:app=policy tier=management"
        "test-ns-113:app=compliance tier=management"
        "test-ns-114:app=risk tier=management"
        "test-ns-115:app=quality tier=management"
        "test-ns-116:app=testing tier=ci-cd"
        "test-ns-117:app=staging tier=ci-cd"
        "test-ns-118:app=production tier=ci-cd"
        "test-ns-119:app=rollback tier=ci-cd"
        "test-ns-120:app=canary tier=ci-cd"
        "test-ns-121:app=blue-green tier=ci-cd"
        "test-ns-122:app=feature-flag tier=ci-cd"
        "test-ns-123:app=a-b-testing tier=ci-cd"
        "test-ns-124:app=performance tier=testing"
        "test-ns-125:app=load tier=testing"
        "test-ns-126:app=stress tier=testing"
        "test-ns-127:app=chaos tier=testing"
        "test-ns-128:app=security tier=testing"
        "test-ns-129:app=penetration tier=testing"
        "test-ns-130:app=vulnerability tier=testing"
        "test-ns-131:app=compliance tier=testing"
        "test-ns-132:app=accessibility tier=testing"
        "test-ns-133:app=usability tier=testing"
        "test-ns-134:app=compatibility tier=testing"
        "test-ns-135:app=integration tier=testing"
        "test-ns-136:app=end-to-end tier=testing"
        "test-ns-137:app=smoke tier=testing"
        "test-ns-138:app=regression tier=testing"
        "test-ns-139:app=acceptance tier=testing"
        "test-ns-140:app=user tier=testing"
        "test-ns-141:app=api tier=testing"
        "test-ns-142:app=unit tier=testing"
        "test-ns-143:app=component tier=testing"
        "test-ns-144:app=system tier=testing"
        "test-ns-145:app=contract tier=testing"
        "test-ns-146:app=consumer tier=testing"
        "test-ns-147:app=provider tier=testing"
        "test-ns-148:app=wiremock tier=testing"
        "test-ns-149:app=mock tier=testing"
        "test-ns-150:app=stub tier=testing"
        "test-ns-151:app=spy tier=testing"
        "test-ns-152:app=double tier=testing"
        "test-ns-153:app=fake tier=testing"
        "test-ns-154:app=dummy tier=testing"
        "test-ns-155:app=test-double tier=testing"
        "test-ns-156:app=test-harness tier=testing"
        "test-ns-157:app=test-fixture tier=testing"
        "test-ns-158:app=test-data tier=testing"
        "test-ns-159:app=test-environment tier=testing"
        "test-ns-160:app=test-infrastructure tier=testing"
        "test-ns-161:app=test-automation tier=testing"
        "test-ns-162:app=test-orchestration tier=testing"
        "test-ns-163:app=test-execution tier=testing"
        "test-ns-164:app=test-reporting tier=testing"
        "test-ns-165:app=test-analysis tier=testing"
        "test-ns-166:app=test-metrics tier=testing"
        "test-ns-167:app=test-dashboard tier=testing"
        "test-ns-168:app=test-alerts tier=testing"
        "test-ns-169:app=test-notifications tier=testing"
        "test-ns-170:app=test-escalation tier=testing"
        "test-ns-171:app=test-workflow tier=testing"
        "test-ns-172:app=test-process tier=testing"
        "test-ns-173:app=test-procedure tier=testing"
        "test-ns-174:app=test-protocol tier=testing"
        "test-ns-175:app=test-standard tier=testing"
        "test-ns-176:app=test-guideline tier=testing"
        "test-ns-177:app=test-best-practice tier=testing"
        "test-ns-178:app=test-pattern tier=testing"
        "test-ns-179:app=test-template tier=testing"
        "test-ns-180:app=test-framework tier=testing"
        "test-ns-181:app=test-library tier=testing"
        "test-ns-182:app=test-toolkit tier=testing"
        "test-ns-183:app=test-suite tier=testing"
        "test-ns-184:app=test-specification tier=testing"
        "test-ns-185:app=test-requirement tier=testing"
        "test-ns-186:app=test-criteria tier=testing"
        "test-ns-187:app=test-scenario tier=testing"
        "test-ns-188:app=test-case tier=testing"
        "test-ns-189:app=test-script tier=testing"
        "test-ns-190:app=test-step tier=testing"
        "test-ns-191:app=test-action tier=testing"
        "test-ns-192:app=test-assertion tier=testing"
        "test-ns-193:app=test-validation tier=testing"
        "test-ns-194:app=test-verification tier=testing"
        "test-ns-195:app=test-confirmation tier=testing"
        "test-ns-196:app=test-approval tier=testing"
        "test-ns-197:app=test-signoff tier=testing"
        "test-ns-198:app=test-release tier=testing"
        "test-ns-199:app=test-deployment tier=testing"
        "test-ns-200:app=test-production tier=testing"
    )
    
    # Create namespaces based on requested count
    local created_namespaces=()
    for ((i=0; i<namespace_count; i++)); do
        local template_index=$((i % ${#namespace_templates[@]}))
        local template="${namespace_templates[$template_index]}"
        local labels=$(echo "$template" | cut -d: -f2-)
        
        # Create generic namespace name with number
        local name="test-ns-$((i + 1))"
        
        create_namespace "$name" "$labels"
        created_namespaces+=("$name")
    done
    
    echo ""
    log_info "Deploying EgressIP configurations with discovered IPs..."
    
    # Calculate distribution of IPs across EgressIP resources
    local total_ips=${#TEST_IPS[@]}
    local ips_per_namespace=$((total_ips / namespace_count))
    local remaining_ips=$((total_ips % namespace_count))
    
    # Ensure we have at least 1 IP per namespace
    [ $ips_per_namespace -lt 1 ] && ips_per_namespace=1
    
    log_info "IP distribution: $ips_per_namespace IPs per namespace (with $remaining_ips extra IPs)"
    
    # Generate EgressIP YAML dynamically for each namespace
    local yaml_content=""
    local ip_index=0
    
    for ((ns_index=0; ns_index<namespace_count; ns_index++)); do
        local namespace="${created_namespaces[$ns_index]}"
        local egressip_name="test-eip-${namespace}"
        
        # Calculate IPs for this namespace
        local ips_for_this_namespace=$ips_per_namespace
        if [ $ns_index -lt $remaining_ips ]; then
            ips_for_this_namespace=$((ips_for_this_namespace + 1))
        fi
        
        # Use namespace name directly for simpler assignment
        # No need to parse complex labels - just use the namespace name
        
        # Generate EgressIP for this namespace
        yaml_content+="apiVersion: k8s.ovn.org/v1\n"
        yaml_content+="kind: EgressIP\n"
        yaml_content+="metadata:\n"
        yaml_content+="  name: $egressip_name\n"
        yaml_content+="  labels:\n"
        yaml_content+="    test-suite: eip-monitoring\n"
        yaml_content+="    environment: test\n"
        yaml_content+="    namespace: $namespace\n"
        yaml_content+="spec:\n"
        yaml_content+="  egressIPs:\n"
        
        # Add IPs for this namespace
        for ((i=0; i<ips_for_this_namespace; i++)); do
            if [ $ip_index -lt ${#TEST_IPS[@]} ]; then
                yaml_content+="  - ${TEST_IPS[$ip_index]}\n"
                ip_index=$((ip_index + 1))
            fi
        done
        
        yaml_content+="  namespaceSelector:\n"
        yaml_content+="    matchLabels:\n"
        yaml_content+="      kubernetes.io/metadata.name: $namespace\n"
        
        yaml_content+="---\n"
    done
    
    # Deploy the EgressIP resources
    echo -e "$yaml_content" | oc apply -f -

    echo ""
    log_success "Test EgressIPs deployed successfully!"
    
    # Summary
    echo ""
    echo "📊 Deployment Summary"
    echo "===================="
    echo "CIDR discovered: $CIDR"
    echo "IPs requested: $ip_count"
    echo "IPs allocated: ${#TEST_IPS[@]}"
    echo "Namespaces requested: $namespace_count"
    echo "Namespaces created: ${#created_namespaces[@]}"
    echo "EgressIPs created: $namespace_count"
    echo "IPs per namespace: $ips_per_namespace (with $remaining_ips extra IPs)"
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
    local force_cleanup="${1:-false}"
    local egressip_timeout="${2:-$DEFAULT_EGRESSIP_TIMEOUT}"
    local namespace_timeout="${3:-$DEFAULT_NAMESPACE_TIMEOUT}"
    
    echo ""
    log_info "Cleaning up test EgressIP resources..."
    log_info "EgressIP timeout: $egressip_timeout"
    log_info "Namespace timeout: $namespace_timeout"
    [ "$force_cleanup" = "true" ] && log_info "Force cleanup: enabled"
    
    # Delete EgressIPs
    if oc delete egressip -l test-suite=eip-monitoring --timeout="$egressip_timeout"; then
        log_success "Test EgressIPs deleted"
    else
        if [ "$force_cleanup" = "true" ]; then
            log_warn "Some EgressIPs failed to delete, continuing with force cleanup"
    else
        log_warn "Some EgressIPs may not have been deleted"
        fi
    fi
    
    # Delete test namespaces (those with test-suite label)
    log_info "Deleting test namespaces..."
    local test_namespaces=$(oc get namespaces -l test-suite=eip-monitoring -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$test_namespaces" ]; then
        for ns in $test_namespaces; do
            if oc delete namespace "$ns" --timeout="$namespace_timeout" &>/dev/null; then
            log_success "Namespace '$ns' deleted"
            else
                if [ "$force_cleanup" = "true" ]; then
                    log_warn "Namespace '$ns' failed to delete, attempting force deletion..."
                    oc delete namespace "$ns" --force --grace-period=0 &>/dev/null || true
                    log_warn "Force deletion attempted for namespace '$ns'"
                else
                    log_warn "Namespace '$ns' may not have been deleted or didn't exist"
                fi
            fi
        done
        else
            # Fallback: delete generic test namespace names (only if they exist)
            log_info "No namespaces found with test-suite label, checking for generic test namespaces..."
            # Get all namespaces and filter for test-ns-* pattern
            local existing_test_ns=$(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^test-ns-[0-9]+$' || echo "")
            if [ -n "$existing_test_ns" ]; then
                log_info "Found generic test namespaces: $existing_test_ns"
                for ns in $existing_test_ns; do
                    if oc delete namespace "$ns" --timeout="$namespace_timeout" &>/dev/null; then
                        log_success "Namespace '$ns' deleted"
                    else
                        if [ "$force_cleanup" = "true" ]; then
                            log_warn "Namespace '$ns' failed to delete, attempting force deletion..."
                            oc delete namespace "$ns" --force --grace-period=0 &>/dev/null || true
                            log_warn "Force deletion attempted for namespace '$ns'"
                        fi
                    fi
                done
            else
                log_info "No test namespaces found (neither labeled nor generic test-ns-* pattern)"
            fi
        fi
    
    log_success "Cleanup completed"
}

# Parse cleanup arguments
parse_cleanup_args() {
    local force_cleanup="false"
    local egressip_timeout="$DEFAULT_EGRESSIP_TIMEOUT"
    local namespace_timeout="$DEFAULT_NAMESPACE_TIMEOUT"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force|-f)
                force_cleanup="true"
                shift
                ;;
            --egressip-timeout)
                egressip_timeout="$2"
                shift 2
                ;;
            --namespace-timeout)
                namespace_timeout="$2"
                shift 2
                ;;
            --help|-h)
                echo "Cleanup options:"
                echo "  --force, -f                    Force deletion with --force --grace-period=0"
                echo "  --egressip-timeout TIMEOUT     Timeout for EgressIP deletion (default: 30s)"
                echo "  --namespace-timeout TIMEOUT    Timeout for namespace deletion (default: 60s)"
                echo "  --help, -h                     Show this help"
                exit 0
                ;;
            *)
                log_error "Unknown cleanup option: $1"
                echo "Use '--help' for cleanup options"
                exit 1
                ;;
        esac
    done
    
    # Call cleanup function with parsed arguments
    cleanup_test_resources "$force_cleanup" "$egressip_timeout" "$namespace_timeout"
}

# Handle command line arguments
case "${1:-deploy}" in
    "deploy")
        # Check if second and third arguments are numbers (IP count and namespace count)
        ip_count="${2:-15}"
        namespace_count="${3:-4}"
        
        if [[ "$ip_count" =~ ^[0-9]+$ ]] && [[ "$namespace_count" =~ ^[0-9]+$ ]]; then
            main "$ip_count" "$namespace_count"
        elif [[ "$ip_count" =~ ^[0-9]+$ ]]; then
            main "$ip_count"
        else
            main
        fi
        ;;
    "cleanup")
        # Parse cleanup arguments
        shift  # Remove 'cleanup' from arguments
        parse_cleanup_args "$@"
        ;;
    "discover")
        check_prerequisites
        source_discovery_functions
        get_eip_ranges
        ;;
    "--help"|"-h"|"help")
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  deploy [ip_count] [namespace_count]  Deploy test EgressIP resources"
        echo "                                      ip_count: Number of IPs to deploy (1-200, default: 15)"
        echo "                                      namespace_count: Number of namespaces to create (1-200, default: 4)"
        echo "  cleanup [options]                    Remove all test resources"
        echo "                                      --force, -f: Force deletion with --force --grace-period=0"
        echo "                                      --egressip-timeout TIMEOUT: Timeout for EgressIP deletion (default: 30s)"
        echo "                                      --namespace-timeout TIMEOUT: Timeout for namespace deletion (default: 60s)"
        echo "  discover                             Show available EgressIP ranges"
        echo "  help                                 Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 deploy                    # Deploy with default 15 IPs and 4 namespaces"
        echo "  $0 deploy 50                 # Deploy with 50 IPs and 4 namespaces"
        echo "  $0 deploy 50 8               # Deploy with 50 IPs and 8 namespaces"
        echo "  $0 deploy 200 200           # Deploy with maximum 200 IPs and 200 namespaces (1:1 mapping)"
        echo "  $0 cleanup                   # Clean up test resources"
        echo "  $0 cleanup --force          # Force clean up test resources"
        echo "  $0 cleanup --egressip-timeout 60s --namespace-timeout 120s  # Custom timeouts"
        echo "  $0 cleanup --force --namespace-timeout 30s  # Force cleanup with custom namespace timeout"
        ;;
    *)
        # Check if first argument is a number (IP count for deploy)
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
            ip_count="$1"
            namespace_count="${2:-4}"
            if [[ "$namespace_count" =~ ^[0-9]+$ ]]; then
                main "$ip_count" "$namespace_count"
            else
                main "$ip_count"
            fi
        else
        log_error "Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        fi
        ;;
esac
