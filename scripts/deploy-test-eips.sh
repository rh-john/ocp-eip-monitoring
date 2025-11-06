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
# Usage: ./deploy-test-eips.sh [ip_count] [namespace_count] [eips_per_namespace]
#
# Parameters:
#   ip_count            - Total number of EIPs to create (default: 15)
#   namespace_count     - Number of namespaces to create (default: 4)
#   eips_per_namespace  - Fixed EIPs per namespace (default: 0 = auto-distribute)
#
# Examples:
#   ./deploy-test-eips.sh                    # 15 IPs, 4 namespaces, auto-distribute
#   ./deploy-test-eips.sh 20 5               # 20 IPs, 5 namespaces, auto-distribute
#   ./deploy-test-eips.sh 20 5 3             # 20 IPs, 5 namespaces, 3 EIPs each
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
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default timeouts
DEFAULT_EGRESSIP_TIMEOUT="30s"
DEFAULT_NAMESPACE_TIMEOUT="60s"

# Logging functions
log_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
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
    local eips_per_namespace="${3:-0}" # Default to 0 (auto-distribute) if not specified
    
    # Validate IP count
    if ! [[ "$ip_count" =~ ^[0-9]+$ ]] || [ "$ip_count" -lt 1 ] || [ "$ip_count" -gt 210 ]; then
        log_error "IP count must be a number between 1 and 210"
        exit 1
    fi
    
    # Validate namespace count
    if ! [[ "$namespace_count" =~ ^[0-9]+$ ]] || [ "$namespace_count" -lt 1 ] || [ "$namespace_count" -gt 200 ]; then
        log_error "Namespace count must be a number between 1 and 200"
        exit 1
    fi
    
    # Validate EIPs per namespace
    if ! [[ "$eips_per_namespace" =~ ^[0-9]+$ ]] || [ "$eips_per_namespace" -lt 0 ] || [ "$eips_per_namespace" -gt 50 ]; then
        log_error "EIPs per namespace must be a number between 0 and 50 (0 = auto-distribute)"
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
    if [ "$eips_per_namespace" -gt 0 ]; then
        log_info "EIPs per namespace: $eips_per_namespace (fixed)"
    else
        log_info "EIPs per namespace: auto-distribute"
    fi
    echo ""
    
    log_info "Discovering EgressIP configuration from cluster..."
    
    # Get the first available EgressIP CIDR
    CIDR=$(get_first_eip_cidr)
    
    if [ -z "$CIDR" ]; then
        log_error "No EgressIP configuration found on nodes"
        echo ""
        echo "To enable EgressIP testing:"
        echo "1. Label nodes for egress assignment:"
        echo "   oc label node <worker-node> k8s.ovn.org/egress-assignable="
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
    local temp_ips_file=$(mktemp)
    generate_test_ips "$CIDR" "$ip_count" > "$temp_ips_file"
    while IFS= read -r line; do
        TEST_IPS+=("$line")
    done < "$temp_ips_file"
    rm -f "$temp_ips_file"
    
    if [ ${#TEST_IPS[@]} -lt $ip_count ]; then
        log_error "Could not generate enough IP addresses from CIDR $CIDR"
        log_error "Generated only ${#TEST_IPS[@]} IPs, need $ip_count"
        exit 1
    fi
    
    log_success "Generated ${#TEST_IPS[@]} test IP addresses"
    log_info "Sample IPs: ${TEST_IPS[0]}, ${TEST_IPS[1]}, ${TEST_IPS[2]}, ..."
    echo ""
    
    # Check existing configuration - combined queries for better performance
    log_info "Checking existing test configuration..."
    
    # Get EgressIP data in one query
    local eip_json=$(oc get egressip -l test-suite=eip-monitoring -o json 2>/dev/null || echo '{"items":[]}')
    local existing_eips=$(echo "$eip_json" | jq -r '.items | length')
    local existing_total_ips=$(echo "$eip_json" | jq -r '[.items[].spec.egressIPs[]?] | length')
    
    # Get namespace data in one query (cache for later use)
    local ns_json=$(oc get namespaces -o json 2>/dev/null || echo '{"items":[]}')
    local existing_ns_list=($(echo "$ns_json" | jq -r '.items[] | select(.metadata.name | test("^test-ns-[0-9]+$")) | .metadata.name' | sort -V))
    local existing_namespaces=${#existing_ns_list[@]}
    
    # Calculate distribution ratios
    local existing_ips_per_ns=0
    local requested_ips_per_ns=0
    
    if [ "$existing_namespaces" -gt 0 ] && [ "$existing_total_ips" -gt 0 ]; then
        # Calculate existing ratio (using integer division)
        existing_ips_per_ns=$((existing_total_ips / existing_namespaces))
    fi
    
    if [ "$namespace_count" -gt 0 ] && [ "$ip_count" -gt 0 ]; then
        # Calculate requested ratio
        requested_ips_per_ns=$((ip_count / namespace_count))
    fi
    
    # Check if configuration matches exactly
    if [ "$existing_eips" -eq "$namespace_count" ] && [ "$existing_namespaces" -eq "$namespace_count" ] && [ "$existing_total_ips" -eq "$ip_count" ]; then
        log_success "Existing configuration matches requested ($namespace_count namespaces, $namespace_count EIPs, $ip_count IPs)"
        log_info "Skipping creation - using existing resources"
        
        # Use cached namespace list (already sorted)
        local created_namespaces=("${existing_ns_list[@]}")
        
        # Verify we have the right count
        if [ ${#created_namespaces[@]} -ne $namespace_count ]; then
            log_warn "Namespace count mismatch, recreating..."
            skip_to_eip_deployment=false
        else
            # Skip to EgressIP deployment
            skip_to_eip_deployment=true
        fi
    elif [ "$existing_namespaces" -eq "$namespace_count" ] && [ "$existing_ips_per_ns" -ne "$requested_ips_per_ns" ]; then
        # Same namespace count but different distribution - allow distribution change
        log_info "Changing distribution: Same namespace count ($namespace_count), different IP distribution"
        log_info "Existing: $existing_namespaces namespaces, $existing_total_ips IPs ($existing_ips_per_ns IPs/ns)"
        log_info "Requested: $namespace_count namespaces, $ip_count IPs ($requested_ips_per_ns IPs/ns)"
        log_info "Updating all EgressIPs with new IP distribution..."
        
        # Use existing namespaces (same count, just updating IPs)
        local created_namespaces=("${existing_ns_list[@]}")
        
        # Will update EgressIPs with new distribution
        skip_to_eip_deployment=false
    elif [ "$existing_namespaces" -gt 0 ] && [ "$existing_ips_per_ns" -eq "$requested_ips_per_ns" ]; then
        # Distribution ratio matches - allow scaling operation
        log_info "Distribution ratio matches ($existing_ips_per_ns IPs per namespace)"
        log_info "Existing: $existing_namespaces namespaces, $existing_total_ips IPs"
        log_info "Requested: $namespace_count namespaces, $ip_count IPs"
        
        if [ "$namespace_count" -gt "$existing_namespaces" ]; then
            log_info "Scaling UP: Adding $((namespace_count - existing_namespaces)) namespaces and $((ip_count - existing_total_ips)) IPs"
        elif [ "$namespace_count" -lt "$existing_namespaces" ]; then
            log_info "Scaling DOWN: Removing $((existing_namespaces - namespace_count)) namespaces and $((existing_total_ips - ip_count)) IPs"
        else
            log_info "IP count change only: Updating IPs from $existing_total_ips to $ip_count"
        fi
        
        # Use cached namespace list (already sorted from initial query)
        
        # Handle scaling operations
        if [ "$namespace_count" -lt "$existing_namespaces" ]; then
            # Scale down: Delete extra namespaces and their EgressIPs in parallel
            log_info "Deleting extra namespaces and EgressIPs in parallel..."
            local delete_pids=()
            for ((i=$namespace_count; i<${#existing_ns_list[@]}; i++)); do
                local ns_to_delete="${existing_ns_list[$i]}"
                local eip_to_delete="test-eip-${ns_to_delete}"
                
                # Delete EgressIP and namespace in parallel
                (
                    oc delete egressip "$eip_to_delete" --ignore-not-found=true &>/dev/null || true
                    oc delete namespace "$ns_to_delete" --ignore-not-found=true &>/dev/null || true
                ) &
                delete_pids+=($!)
            done
            
            # Wait for all deletions to complete
            for pid in "${delete_pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
            log_success "Removed $((existing_namespaces - namespace_count)) namespaces"
        elif [ "$namespace_count" -gt "$existing_namespaces" ]; then
            # Scale up: Will create additional namespaces below
            log_info "Will create $((namespace_count - existing_namespaces)) additional namespaces"
        fi
        
        # Use existing namespaces up to the requested count
        local created_namespaces=()
        for ((i=0; i<namespace_count && i<${#existing_ns_list[@]}; i++)); do
            created_namespaces+=("${existing_ns_list[$i]}")
        done
        
        # Will create additional namespaces if needed (handled below)
        skip_to_eip_deployment=false
    elif [ "$existing_namespaces" -gt 0 ] && [ "$existing_namespaces" -ne "$namespace_count" ] && [ "$existing_ips_per_ns" -ne "$requested_ips_per_ns" ]; then
        # Both namespace count and distribution differ - allow combined operation
        log_info "Changing both namespace count and distribution"
        log_info "Existing: $existing_namespaces namespaces, $existing_total_ips IPs ($existing_ips_per_ns IPs/ns)"
        log_info "Requested: $namespace_count namespaces, $ip_count IPs ($requested_ips_per_ns IPs/ns)"
        
        if [ "$namespace_count" -gt "$existing_namespaces" ]; then
            log_info "Step 1: Scaling UP namespaces from $existing_namespaces to $namespace_count"
        elif [ "$namespace_count" -lt "$existing_namespaces" ]; then
            log_info "Step 1: Scaling DOWN namespaces from $existing_namespaces to $namespace_count"
        fi
        log_info "Step 2: Updating IP distribution from $existing_ips_per_ns to $requested_ips_per_ns IPs per namespace"
        
        # Handle namespace scaling first
        if [ "$namespace_count" -lt "$existing_namespaces" ]; then
            # Scale down: Delete extra namespaces and their EgressIPs in parallel
            log_info "Deleting extra namespaces and EgressIPs in parallel..."
            local delete_pids=()
            for ((i=$namespace_count; i<${#existing_ns_list[@]}; i++)); do
                local ns_to_delete="${existing_ns_list[$i]}"
                local eip_to_delete="test-eip-${ns_to_delete}"
                
                # Delete EgressIP and namespace in parallel
                (
                    oc delete egressip "$eip_to_delete" --ignore-not-found=true &>/dev/null || true
                    oc delete namespace "$ns_to_delete" --ignore-not-found=true &>/dev/null || true
                ) &
                delete_pids+=($!)
            done
            
            # Wait for all deletions to complete
            for pid in "${delete_pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
            log_success "Removed $((existing_namespaces - namespace_count)) namespaces"
        fi
        
        # Use existing namespaces up to the requested count (will create more if needed below)
        local created_namespaces=()
        for ((i=0; i<namespace_count && i<${#existing_ns_list[@]}; i++)); do
            created_namespaces+=("${existing_ns_list[$i]}")
        done
        
        # Will create additional namespaces and update distribution (handled below)
        skip_to_eip_deployment=false
    else
        if [ "$existing_eips" -gt 0 ] || [ "$existing_namespaces" -gt 0 ]; then
            log_warn "Existing configuration found ($existing_namespaces namespaces, $existing_eips EIPs, $existing_total_ips IPs)"
            log_warn "Unexpected configuration mismatch"
            log_warn "Please run cleanup first or manually delete existing test resources"
            exit 1
        fi
        skip_to_eip_deployment=false
    fi
    
    if [ "$skip_to_eip_deployment" != "true" ]; then
        # Initialize created_namespaces if not already set (from scaling detection)
        if [ -z "${created_namespaces[*]:-}" ]; then
            created_namespaces=()
        fi
        
        # Calculate how many namespaces we need to create
        local existing_count=${#created_namespaces[@]}
        local namespaces_to_create=$((namespace_count - existing_count))
        
        if [ "$namespaces_to_create" -gt 0 ]; then
            log_info "Creating $namespaces_to_create additional namespaces (existing: $existing_count, requested: $namespace_count)..."
            
            # Batch create namespaces for speed
            local namespace_yaml=""
            
            # Define namespace templates with different characteristics
            # This array provides diverse labels for up to 200 namespaces
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
        
            # Build batch YAML for new namespaces only (starting from existing_count)
            for ((i=$existing_count; i<$namespace_count; i++)); do
                local template_index=$((i % ${#namespace_templates[@]}))
                local template="${namespace_templates[$template_index]}"
                local labels=$(echo "$template" | cut -d: -f2-)
                
                # Create generic namespace name with number
                local name="test-ns-$((i + 1))"
                created_namespaces+=("$name")
                
                # Build namespace YAML
                namespace_yaml+="apiVersion: v1\n"
                namespace_yaml+="kind: Namespace\n"
                namespace_yaml+="metadata:\n"
                namespace_yaml+="  name: $name\n"
                namespace_yaml+="  labels:\n"
                namespace_yaml+="    test-suite: eip-monitoring\n"
                namespace_yaml+="    environment: test\n"
                
                # Add template labels
                if [ -n "$labels" ]; then
                    IFS=' ' read -ra LABEL_ARRAY <<< "$labels"
                    for label in "${LABEL_ARRAY[@]}"; do
                        if [[ "$label" == *"="* ]]; then
                            local key=$(echo "$label" | cut -d'=' -f1)
                            local value=$(echo "$label" | cut -d'=' -f2-)
                            namespace_yaml+="    $key: $value\n"
                        fi
                    done
                fi
                
                namespace_yaml+="---\n"
            done
            
            # Apply all new namespaces in one batch operation
            # Only show output for newly created namespaces, suppress "configured" messages
            if [ -n "$namespace_yaml" ]; then
                local created_count=$(echo -e "$namespace_yaml" | oc apply -f - 2>&1 | grep -c "created" || echo "0")
                if [ "$created_count" -gt 0 ]; then
                    log_success "Created $created_count new namespaces"
                fi
            fi
            
            # Apply labels in parallel (faster than sequential)
            local label_pids=()
            for ((i=$existing_count; i<$namespace_count; i++)); do
                local template_index=$((i % ${#namespace_templates[@]}))
                local template="${namespace_templates[$template_index]}"
                local labels=$(echo "$template" | cut -d: -f2-)
                local name="test-ns-$((i + 1))"
                
                if [ -n "$labels" ]; then
                    oc label namespace "$name" $labels --overwrite &>/dev/null || true &
                    label_pids+=($!)
                fi
            done
            
            # Wait for all label operations to complete
            for pid in "${label_pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
        fi
        
        echo ""
    fi
    
    # Only deploy EgressIPs if we didn't skip (or if we need to update)
    if [ "$skip_to_eip_deployment" != "true" ]; then
        log_info "Deploying EgressIP configurations with discovered IPs..."
        
        # Calculate distribution of IPs across EgressIP resources
        local total_ips=${#TEST_IPS[@]}
        local ips_per_namespace
        local remaining_ips=0
        
        if [ "$eips_per_namespace" -gt 0 ]; then
            # Fixed EIPs per namespace
            ips_per_namespace=$eips_per_namespace
            local total_required_ips=$((namespace_count * eips_per_namespace))
            
            if [ $total_ips -lt $total_required_ips ]; then
                log_warn "Not enough IPs available for fixed distribution"
                log_warn "Available: $total_ips IPs, Required: $total_required_ips IPs"
                log_warn "Reducing EIPs per namespace to fit available IPs"
                ips_per_namespace=$((total_ips / namespace_count))
                [ $ips_per_namespace -lt 1 ] && ips_per_namespace=1
            fi
            
            log_info "Fixed distribution: $ips_per_namespace IPs per namespace"
        else
            # Auto-distribute (original logic)
            ips_per_namespace=$((total_ips / namespace_count))
            remaining_ips=$((total_ips % namespace_count))
            
            # Ensure we have at least 1 IP per namespace
            [ $ips_per_namespace -lt 1 ] && ips_per_namespace=1
            
            log_info "Auto distribution: $ips_per_namespace IPs per namespace (with $remaining_ips extra IPs)"
        fi
        
        # Get existing EgressIPs to check what needs updating
        local existing_eip_json=$(oc get egressip -l test-suite=eip-monitoring -o json 2>/dev/null || echo '{"items":[]}')
        
        # Collect all currently assigned IPs to avoid reassigning them
        local assigned_ips=($(echo "$existing_eip_json" | jq -r '.items[].spec.egressIPs[]?' 2>/dev/null))
        
        # Process each namespace: patch existing EgressIPs or create new ones
        local ip_index=0
        local created_count=0
        local updated_count=0
        local skipped_count=0
        
        for ((ns_index=0; ns_index<namespace_count; ns_index++)); do
            local namespace="${created_namespaces[$ns_index]}"
            local egressip_name="test-eip-${namespace}"
            
            # Calculate IPs for this namespace
            local ips_for_this_namespace=$ips_per_namespace
            if [ "$eips_per_namespace" -eq 0 ] && [ $ns_index -lt $remaining_ips ]; then
                # Only add extra IPs for auto-distribution mode
                ips_for_this_namespace=$((ips_for_this_namespace + 1))
            fi
            
            # Check if EgressIP already exists
            local existing_eip=$(echo "$existing_eip_json" | jq -r ".items[] | select(.metadata.name == \"$egressip_name\")" 2>/dev/null)
            
            if [ -n "$existing_eip" ]; then
                # Existing EgressIP - get current IPs
                local current_ips_array=($(echo "$existing_eip" | jq -r '.spec.egressIPs[]?' 2>/dev/null))
                local current_count=${#current_ips_array[@]}
                
                # If we need more IPs, append to existing (preserve existing assignments)
                if [ "$ips_for_this_namespace" -gt "$current_count" ]; then
                    # Keep all existing IPs and add new ones from the pool
                    local merged_ips=("${current_ips_array[@]}")
                    local needed=$((ips_for_this_namespace - current_count))
                    
                    # Find unused IPs from TEST_IPS pool
                    local added=0
                    for test_ip in "${TEST_IPS[@]}"; do
                        if [ $added -ge $needed ]; then
                            break
                        fi
                        
                        # Check if this IP is already assigned to any EgressIP
                        local already_assigned=0
                        for assigned_ip in "${assigned_ips[@]}"; do
                            if [ "$test_ip" = "$assigned_ip" ]; then
                                already_assigned=1
                                break
                            fi
                        done
                        
                        # Also check if it's already in this EgressIP
                        for current_ip in "${current_ips_array[@]}"; do
                            if [ "$test_ip" = "$current_ip" ]; then
                                already_assigned=1
                                break
                            fi
                        done
                        
                        if [ $already_assigned -eq 0 ]; then
                            merged_ips+=("$test_ip")
                            assigned_ips+=("$test_ip")
                            added=$((added + 1))
                        fi
                    done
                    
                    # Only patch if we actually added new IPs
                    if [ ${#merged_ips[@]} -gt "$current_count" ]; then
                        local ips_json="["
                        for ip in "${merged_ips[@]}"; do
                            [ "$ips_json" != "[" ] && ips_json+=","
                            ips_json+="\"$ip\""
                        done
                        ips_json+="]"
                        
                        log_info "Updating $egressip_name: adding $added new IP(s) (preserving existing ${#current_ips_array[@]} IPs)"
                        if oc patch egressip "$egressip_name" -p "{\"spec\":{\"egressIPs\":$ips_json}}" --type=merge &>/dev/null; then
                            updated_count=$((updated_count + 1))
                            # Small delay to avoid overwhelming the system
                            sleep 0.1
                        fi
                    fi
                elif [ "$ips_for_this_namespace" -lt "$current_count" ]; then
                    # If we need fewer IPs, keep first N IPs (preserve as many as possible)
                    local merged_ips=()
                    for ((i=0; i<ips_for_this_namespace && i<current_count; i++)); do
                        merged_ips+=("${current_ips_array[$i]}")
                    done
                    
                    local ips_json="["
                    for ip in "${merged_ips[@]}"; do
                        [ "$ips_json" != "[" ] && ips_json+=","
                        ips_json+="\"$ip\""
                    done
                    ips_json+="]"
                    
                    log_info "Updating $egressip_name: reducing from $current_count to ${#merged_ips[@]} IP(s)"
                    if oc patch egressip "$egressip_name" -p "{\"spec\":{\"egressIPs\":$ips_json}}" --type=merge &>/dev/null; then
                        updated_count=$((updated_count + 1))
                        # Small delay to avoid overwhelming the system
                        sleep 0.1
                    fi
                else
                    # Same count - no changes needed
                    skipped_count=$((skipped_count + 1))
                fi
            else
                # New EgressIP - create it with IPs from the pool
                local new_ips=()
                local needed=$ips_for_this_namespace
                
                # Find unused IPs from TEST_IPS pool
                for test_ip in "${TEST_IPS[@]}"; do
                    if [ ${#new_ips[@]} -ge $needed ]; then
                        break
                    fi
                    
                    # Check if this IP is already assigned
                    local already_assigned=0
                    for assigned_ip in "${assigned_ips[@]}"; do
                        if [ "$test_ip" = "$assigned_ip" ]; then
                            already_assigned=1
                            break
                        fi
                    done
                    
                    if [ $already_assigned -eq 0 ]; then
                        new_ips+=("$test_ip")
                        assigned_ips+=("$test_ip")
                    fi
                done
                
                # Create the new EgressIP
                if [ ${#new_ips[@]} -gt 0 ]; then
                    local yaml_content=""
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
                    
                    for ip in "${new_ips[@]}"; do
                        yaml_content+="  - $ip\n"
                    done
                    
                    yaml_content+="  namespaceSelector:\n"
                    yaml_content+="    matchLabels:\n"
                    yaml_content+="      kubernetes.io/metadata.name: $namespace\n"
                    
                    if echo -e "$yaml_content" | oc apply -f - &>/dev/null; then
                        created_count=$((created_count + 1))
                    fi
                fi
            fi
        done
        
        # Report results
        if [ "$created_count" -gt 0 ]; then
            log_success "Created $created_count new EgressIPs"
        fi
        if [ "$updated_count" -gt 0 ]; then
            log_success "Updated $updated_count existing EgressIPs"
        fi
        if [ "$skipped_count" -gt 0 ]; then
            log_info "Skipped $skipped_count EgressIPs (no changes needed)"
        fi
    fi

    echo ""
    
    # Summary
    echo ""
    echo "📊 Deployment Summary"
    echo "===================="
    echo "CIDR discovered: $CIDR"
    echo "IPs requested: $ip_count"
    echo "IPs allocated: ${#TEST_IPS[@]}"
    echo "Namespaces requested: $namespace_count"
    echo "Namespaces created: ${#created_namespaces[@]}"
    if [ "$eips_per_namespace" -gt 0 ]; then
        echo "Distribution: Fixed ($ips_per_namespace EIPs per namespace)"
    else
        echo "Distribution: Auto-distributed"
    fi
    echo "EgressIPs created: $namespace_count"
    echo ""
    
    # Wait a moment for resources to be processed
    # If we updated EgressIPs, wait longer for reassignment
    if [ "${updated_count:-0}" -gt 0 ]; then
        log_info "Waiting for EgressIP reassignment (updated $updated_count EgressIPs)..."
        sleep 10
    else
        log_info "Waiting for EgressIP assignment..."
        sleep 5
    fi
    
    # Verification - compressed output with counts only
    echo "🔍 Verification Summary"
    echo "======================"
    echo ""
    
    # Count EgressIPs by status
    local eip_json=$(oc get egressip -l test-suite=eip-monitoring -o json 2>/dev/null || echo '{"items":[]}')
    local eip_total=$(echo "$eip_json" | jq -r '.items | length' 2>/dev/null || echo "0")
    local eip_assigned=$(echo "$eip_json" | jq -r '[.items[] | select(.status.items != null and (.status.items | length) > 0)] | length' 2>/dev/null || echo "0")
    local eip_unassigned=$((eip_total - eip_assigned))
    
    echo "📋 EgressIPs: $eip_total total ($eip_assigned assigned, $eip_unassigned unassigned)"
    
    # Count CloudPrivateIPConfigs by status
    local cpic_json=$(oc get cloudprivateipconfig -o json 2>/dev/null || echo '{"items":[]}')
    local cpic_total=$(echo "$cpic_json" | jq -r '.items | length' 2>/dev/null || echo "0")
    if [ "${cpic_total:-0}" -gt 0 ]; then
        local cpic_assigned=$(echo "$cpic_json" | jq -r '[.items[] | select(.status.node != null and .status.node != "")] | length' 2>/dev/null || echo "0")
        local cpic_pending=$((cpic_total - cpic_assigned))
        echo "📋 CloudPrivateIPConfigs: $cpic_total total ($cpic_assigned assigned, $cpic_pending pending)"
    else
        echo "📋 CloudPrivateIPConfigs: 0 (not yet created)"
    fi
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
    local cleanup_stale="${4:-false}"
    
    echo ""
    log_info "Cleaning up test EgressIP resources..."
    log_info "EgressIP timeout: $egressip_timeout"
    log_info "Namespace timeout: $namespace_timeout"
    [ "$force_cleanup" = "true" ] && log_info "Force cleanup: enabled"
    [ "$cleanup_stale" = "true" ] && log_info "Stale/failed cleanup: enabled (deleting failed CPICs and mismatched EgressIPs)"
    
    # If --stale is used, only clean up failed resources and skip regular cleanup
    if [ "$cleanup_stale" = "true" ]; then
        echo ""
        log_info "Cleaning up stale/failed resources (CPICs and mismatched EgressIPs)..."
        log_info "Only deleting failed/stale CPICs and EgressIPs with mismatches (failed CPICs, stale CPICs not assigned to EIPs, or node assignment mismatches), leaving working ones untouched"
        
        # Get all CPICs first to check their status
        local cpic_json=$(oc get cloudprivateipconfig -o json 2>/dev/null || echo '{"items":[]}')
        
        # Find failed CPICs (those without CloudResponseSuccess)
        local jq_failed_file=$(mktemp)
        cat > "$jq_failed_file" <<'JQ_EOF'
.items[] | 
select(
    ((.status.conditions // []) | length == 0) or
    ([(.status.conditions[]? | select(.reason == "CloudResponseSuccess"))] | length == 0)
) |
.metadata.name
JQ_EOF
        local failed_cpics=($(echo "$cpic_json" | jq -r -f "$jq_failed_file" 2>/dev/null))
        rm -f "$jq_failed_file"
        
        local failed_cpic_count=${#failed_cpics[@]}
        
        # Get all EgressIPs and check for mismatches
        local eip_json=$(oc get egressip -l test-suite=eip-monitoring -o json 2>/dev/null || echo '{"items":[]}')
        
        # Find stale CPICs (CPICs that aren't assigned to any EgressIP)
        # A CPIC is stale if it's not referenced in any EgressIP's status.items
        log_info "Finding stale CPICs (not assigned to any EgressIP)..."
        local assigned_ips_map="{}"
        if [ -n "$eip_json" ]; then
            # Build a map of all IPs that are assigned in EgressIP status.items
            local jq_assigned_ips_file=$(mktemp)
            cat > "$jq_assigned_ips_file" <<'JQ_EOF'
[.items[]? |
 select(.status.items != null and (.status.items | length) > 0) |
 .status.items[]? |
 select(.egressIP != null) |
 .egressIP] |
reduce .[] as $ip ({}; .[$ip] = true)
JQ_EOF
            assigned_ips_map=$(echo "$eip_json" | jq -f "$jq_assigned_ips_file" 2>/dev/null || echo "{}")
            rm -f "$jq_assigned_ips_file"
            
        fi
        
        # Find CPICs that aren't in the assigned IPs map
        # If key doesn't exist, $assigned_map[$cpic_name] returns null, and null != true is true
        # If key exists but value is not true, $assigned_map[$cpic_name] != true is true
        local jq_stale_cpics_file=$(mktemp)
        cat > "$jq_stale_cpics_file" <<'JQ_EOF'
.items[] |
select(.metadata.name != null) |
.metadata.name as $cpic_name |
select(($assigned_map[$cpic_name] // false) != true) |
$cpic_name
JQ_EOF
        local stale_cpics=$(echo "$cpic_json" | jq -r --argjson assigned_map "$assigned_ips_map" -f "$jq_stale_cpics_file" 2>&1)
        local stale_jq_error=$?
        rm -f "$jq_stale_cpics_file"
        
        if [ $stale_jq_error -ne 0 ]; then
            log_warn "Warning: jq error when checking for stale CPICs (exit code: $stale_jq_error)"
            log_warn "jq output: $stale_cpics"
            stale_cpics=""
        fi
        
        # Convert stale CPICs to array and merge with failed CPICs
        local stale_cpics_array=()
        while IFS= read -r name; do
            [ -n "$name" ] && stale_cpics_array+=("$name")
        done <<< "$stale_cpics"
        
        local stale_cpic_count=${#stale_cpics_array[@]}
        if [ "$stale_cpic_count" -gt 0 ]; then
            log_info "Found $stale_cpic_count stale CPIC(s) (not assigned to any EgressIP)"
            # Add stale CPICs to failed_cpics array (avoid duplicates)
            for stale_cpic in "${stale_cpics_array[@]}"; do
                local already_in_failed=0
                for failed_cpic in "${failed_cpics[@]}"; do
                    if [ "$stale_cpic" = "$failed_cpic" ]; then
                        already_in_failed=1
                        break
                    fi
                done
                if [ $already_in_failed -eq 0 ]; then
                    failed_cpics+=("$stale_cpic")
                fi
            done
            failed_cpic_count=${#failed_cpics[@]}
        else
            log_info "No stale CPICs found (all CPICs are assigned to EgressIPs)"
        fi
        
        # Find EgressIPs that reference IPs with failed CPICs
        # Use jq to efficiently match EgressIPs containing any failed CPIC IPs
        local mismatched_eips=()
        
        if [ "$failed_cpic_count" -gt 0 ]; then
            # Build a lookup map of failed IPs for efficient checking
            local failed_ips_map=$(printf '%s\n' "${failed_cpics[@]}" | jq -R . | jq -s 'reduce .[] as $ip ({}; .[$ip] = true)' 2>/dev/null)
            
            # Find EgressIPs that have any IP matching a failed CPIC
            local jq_mismatch_file=$(mktemp)
            cat > "$jq_mismatch_file" <<'JQ_EOF'
.items[] |
select(
    [.spec.egressIPs[]? | $failed_map[.] == true] | any
) |
.metadata.name
JQ_EOF
            local mismatched_eip_names=$(echo "$eip_json" | jq -r --argjson failed_map "$failed_ips_map" -f "$jq_mismatch_file" 2>/dev/null)
            rm -f "$jq_mismatch_file"
            
            # Convert to array
            while IFS= read -r name; do
                [ -n "$name" ] && mismatched_eips+=("$name")
            done <<< "$mismatched_eip_names"
        fi
        
        # Find EgressIPs with node assignment mismatches
        # Mismatch occurs when:
        # 1. EIP status.node != CPIC node (status.node or spec.node)
        # 2. CPIC node field (status.node and spec.node) is empty/null
        # NOTE: CloudResponseSuccess status is NOT considered for mismatch detection
        #       We compare ALL CPICs regardless of their CloudResponseSuccess condition
        local node_mismatch_eips=""
        
        if [ -n "$eip_json" ] && [ -n "$cpic_json" ]; then
            # Build a lookup map of CPIC IP -> CPIC node assignment
            # Includes ALL CPICs regardless of CloudResponseSuccess status
            # Priority: status.node (observed state) > spec.node (desired state)
            local jq_cpic_map_file=$(mktemp)
            cat > "$jq_cpic_map_file" <<'JQ_EOF'
[.items[] | 
 select(.metadata.name != null) |
 {
   ip: .metadata.name,
   node: ((.status.node // .spec.node // "") | if . == null or . == "" then "" else . end)
 }] |
reduce .[] as $item ({}; . + {($item.ip): $item.node})
JQ_EOF
            # Use jq without -r to get JSON output for --argjson
            local cpic_node_map=$(echo "$cpic_json" | jq -f "$jq_cpic_map_file" 2>/dev/null)
            local cpic_map_error=$?
            rm -f "$jq_cpic_map_file"
            
            if [ $cpic_map_error -ne 0 ] || [ -z "$cpic_node_map" ] || [ "$cpic_node_map" = "null" ]; then
                log_warn "Failed to build CPIC node map (error: $cpic_map_error)"
                cpic_node_map="{}"
            fi
            
            # Check each EgressIP for node mismatches
            # Flag if: CPIC node is empty OR EIP node != CPIC node
            # Only check status.items (status.node), not spec.egressIPs
            local jq_mismatch_check_file=$(mktemp)
            cat > "$jq_mismatch_check_file" <<'JQ_EOF'
.items[]? | 
select(.status.items != null and (.status.items | length) > 0) |
. as $eip |
$eip.metadata.name as $eip_name |
[
  $eip.status.items[]? |
  select(.egressIP != null) |
  .egressIP as $ip |
  (.node // "") as $eip_node |
  ($cpic_map[$ip] // "") as $cpic_node |
  # Mismatch if: CPIC node is empty OR EIP node differs from CPIC node
  # (including when EIP node is empty but CPIC node is not)
  select($cpic_node == "" or ($cpic_node != "" and $cpic_node != $eip_node))
] |
if length > 0 then $eip_name else empty end
JQ_EOF
            # Run the mismatch check query
            node_mismatch_eips=$(echo "$eip_json" | jq -r --argjson cpic_map "$cpic_node_map" -f "$jq_mismatch_check_file" 2>&1)
            local jq_error=$?
            rm -f "$jq_mismatch_check_file"
            
            if [ $jq_error -ne 0 ]; then
                log_warn "Warning: jq error when checking for node mismatches (exit code: $jq_error)"
                log_warn "jq output: $node_mismatch_eips"
                node_mismatch_eips=""
            fi
        fi
        
        # Remove trailing newline
        node_mismatch_eips=$(echo "$node_mismatch_eips" | grep -v '^$' || echo "")
        
        # Add node mismatch EgressIPs to the list (avoid duplicates)
        if [ -n "$node_mismatch_eips" ]; then
            local node_mismatch_count=$(echo "$node_mismatch_eips" | grep -v '^$' | wc -l | tr -d ' ')
            log_info "Found $node_mismatch_count EgressIP(s) with node assignment mismatches (EgressIP status.node differs from CPIC node OR CPIC node is empty)"
            while IFS= read -r name; do
                [ -z "$name" ] && continue
                # Check if already in the array
                local already_added=0
                for existing in "${mismatched_eips[@]}"; do
                    if [ "$existing" = "$name" ]; then
                        already_added=1
                        break
                    fi
                done
                if [ $already_added -eq 0 ]; then
                    mismatched_eips+=("$name")
                fi
            done <<< "$node_mismatch_eips"
        fi
        
        local deleted_eips=0
        local failed_eip_delete=0
        
        # Delete mismatched EgressIPs first
        if [ ${#mismatched_eips[@]} -gt 0 ]; then
            log_info "Found ${#mismatched_eips[@]} EgressIP(s) with mismatches (failed CPICs or node assignment mismatches)"
            
            for eip_name in "${mismatched_eips[@]}"; do
                log_info "Deleting mismatched EgressIP: $eip_name"
                if oc delete egressip "$eip_name" --force --grace-period=0 &>/dev/null; then
                    deleted_eips=$((deleted_eips + 1))
                    log_success "Deleted EgressIP $eip_name"
                else
                    log_warn "Failed to delete EgressIP $eip_name"
                    failed_eip_delete=$((failed_eip_delete + 1))
                fi
            done
        else
            log_info "No EgressIPs with mismatches found"
        fi
        
        # Delete failed and stale CPICs
        if [ "$failed_cpic_count" -gt 0 ]; then
            log_info "Found $failed_cpic_count CPIC(s) to delete (failed and/or stale)"
            
            local removed_finalizers=0
            local deleted_cpics=0
            local failed_delete=0
            
            for cpic_name in "${failed_cpics[@]}"; do
                log_info "Processing CPIC: $cpic_name (failed or stale)"
                
                # Check if CPIC has finalizers
                local finalizers=$(echo "$cpic_json" | jq -r ".items[] | select(.metadata.name == \"$cpic_name\") | .metadata.finalizers[]?" 2>/dev/null)
                
                if [ -n "$finalizers" ]; then
                    # Remove finalizers
                    log_info "Removing finalizers from $cpic_name..."
                    if oc patch cloudprivateipconfig "$cpic_name" -p '{"metadata":{"finalizers":[]}}' --type=merge &>/dev/null; then
                        removed_finalizers=$((removed_finalizers + 1))
                    else
                        log_warn "Failed to remove finalizers from $cpic_name"
                        failed_delete=$((failed_delete + 1))
                        continue
                    fi
                fi
                
                # Force delete the CPIC
                oc delete cloudprivateipconfig "$cpic_name" --force --grace-period=0 &>/dev/null
                
                # Wait a moment for deletion to propagate
                sleep 0.2
                
                # Verify deletion by checking if resource still exists
                if ! oc get cloudprivateipconfig "$cpic_name" &>/dev/null; then
                    deleted_cpics=$((deleted_cpics + 1))
                    log_success "Deleted $cpic_name"
                else
                    log_warn "Failed to delete $cpic_name (still exists)"
                    failed_delete=$((failed_delete + 1))
                fi
            done
            
            echo ""
            if [ $removed_finalizers -gt 0 ]; then
                log_success "Removed finalizers from $removed_finalizers CPIC(s)"
            fi
            if [ $deleted_cpics -gt 0 ]; then
                log_success "Deleted $deleted_cpics CPIC(s) (failed and/or stale)"
            fi
            if [ $failed_delete -gt 0 ]; then
                log_warn "$failed_delete CPIC(s) failed to cleanup"
            fi
        else
            log_info "No failed or stale CPICs found to delete"
        fi
        
        echo ""
        if [ $deleted_eips -gt 0 ]; then
            log_success "Deleted $deleted_eips mismatched EgressIP(s)"
        fi
        if [ $failed_eip_delete -gt 0 ]; then
            log_warn "$failed_eip_delete EgressIP(s) failed to cleanup"
        fi
        
        log_success "Stale/failed cleanup completed"
        return 0
    fi
    
    # Delete EgressIPs (already efficient as batch operation)
    log_info "Deleting EgressIPs..."
    if oc delete egressip -l test-suite=eip-monitoring --timeout="$egressip_timeout" &>/dev/null; then
        log_success "Test EgressIPs deleted"
    else
        if [ "$force_cleanup" = "true" ]; then
            log_warn "Some EgressIPs failed to delete, continuing with force cleanup"
        else
            log_warn "Some EgressIPs may not have been deleted"
        fi
    fi
    
    # Delete test namespaces in parallel for better performance
    log_info "Deleting test namespaces in parallel..."
    local test_namespaces=$(oc get namespaces -l test-suite=eip-monitoring -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "$test_namespaces" ]; then
        # Fallback: delete generic test namespace names (only if they exist)
        log_info "No namespaces found with test-suite label, checking for generic test namespaces..."
        test_namespaces=$(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E '^test-ns-[0-9]+$' || echo "")
    fi
    
    if [ -n "$test_namespaces" ]; then
        # Convert space-separated string to array for parallel processing
        local ns_array=()
        for ns in $test_namespaces; do
            [ -n "$ns" ] && ns_array+=("$ns")
        done
        
        local total_ns=${#ns_array[@]}
        log_info "Found $total_ns namespaces to delete"
        
        # Delete namespaces in parallel
        local delete_pids=()
        local success_count=0
        local failed_count=0
        local force_count=0
        
        for ns in "${ns_array[@]}"; do
            # Start deletion in background
            (
                if oc delete namespace "$ns" --timeout="$namespace_timeout" &>/dev/null; then
                    exit 0
                else
                    if [ "$force_cleanup" = "true" ]; then
                        oc delete namespace "$ns" --force --grace-period=0 &>/dev/null || true
                        exit 2  # Force deletion attempted
                    else
                        exit 1  # Failed
                    fi
                fi
            ) &
            delete_pids+=($!)
        done
        
        # Wait for all deletions and count results
        for pid in "${delete_pids[@]}"; do
            wait "$pid" 2>/dev/null
            local exit_code=$?
            case $exit_code in
                0)
                    success_count=$((success_count + 1))
                    ;;
                2)
                    force_count=$((force_count + 1))
                    ;;
                *)
                    failed_count=$((failed_count + 1))
                    ;;
            esac
        done
        
        # Report results
        if [ $success_count -gt 0 ]; then
            log_success "Deleted $success_count namespaces successfully"
        fi
        if [ $force_count -gt 0 ]; then
            log_warn "Force deleted $force_count namespaces"
        fi
        if [ $failed_count -gt 0 ]; then
            log_warn "$failed_count namespaces may not have been deleted"
        fi
    else
        log_info "No test namespaces found"
    fi
    
    log_success "Cleanup completed"
}

# Redistribute failed CPICs to nodes with least EIPs
redistribute_failed_cpics() {
    check_prerequisites
    
    log_info "Finding failed CloudPrivateIPConfigs..."
    
    # Get all CPICs
    local cpic_json=$(oc get cloudprivateipconfig -o json 2>/dev/null || echo '{"items":[]}')
    
    if [ -z "$cpic_json" ] || [ "$cpic_json" = '{"items":[]}' ]; then
        log_warn "No CloudPrivateIPConfigs found"
        return 0
    fi
    
    local total_cpics=$(echo "$cpic_json" | jq -r '.items | length' 2>/dev/null || echo "0")
    log_info "Found $total_cpics total CPICs"
    
    # Find failed CPICs: all those without CloudResponseSuccess (including those with errors)
    # Check if CPIC does NOT have any condition with reason "CloudResponseSuccess"
    local jq_script_file=$(mktemp)
    cat > "$jq_script_file" <<'JQ_EOF'
.items[] | 
select(
    ((.status.conditions // []) | length == 0) or
    ([(.status.conditions[]? | select(.reason == "CloudResponseSuccess"))] | length == 0)
) |
.metadata.name
JQ_EOF
    local failed_cpics=$(echo "$cpic_json" | jq -r -f "$jq_script_file" 2>/dev/null)
    rm -f "$jq_script_file"
    
    if [ -z "$failed_cpics" ]; then
        log_success "No failed CPICs found (all are successfully assigned)"
        return 0
    fi
    
    # Convert to array
    local failed_array=()
    while IFS= read -r name; do
        [ -n "$name" ] && failed_array+=("$name")
    done <<< "$failed_cpics"
    
    local failed_count=${#failed_array[@]}
    log_info "Found $failed_count failed CPICs to redistribute"
    
    # Get egress-assignable nodes
    log_info "Getting egress-assignable nodes..."
    local nodes_json=$(oc get nodes -l k8s.ovn.org/egress-assignable -o json 2>/dev/null || echo '{"items":[]}')
    local all_nodes=($(echo "$nodes_json" | jq -r '.items[].metadata.name' 2>/dev/null))
    
    if [ ${#all_nodes[@]} -eq 0 ]; then
        log_error "No egress-assignable nodes found"
        return 1
    fi
    
    log_info "Found ${#all_nodes[@]} egress-assignable nodes"
    
    # Get failed CPICs for debug output (all CPICs without CloudResponseSuccess)
    # This is used both for node detection and for reporting
    local jq_debug_file=$(mktemp)
    cat > "$jq_debug_file" <<'JQ_EOF'
.items[] | 
select(
    ((.status.conditions // []) | length == 0) or
    ([(.status.conditions[]? | select(.reason == "CloudResponseSuccess"))] | length == 0)
) |
{
    name: .metadata.name, 
    node: (.status.node // .spec.node // "unassigned"),
    spec_node: .spec.node,
    status_node: .status.node,
    conditions: .status.conditions
}
JQ_EOF
    local failed_cpics_debug=$(echo "$cpic_json" | jq -r -f "$jq_debug_file" 2>/dev/null)
    rm -f "$jq_debug_file"
    
    # Find nodes that have CPICs with errors assigned to them (exclude these nodes)
    log_info "Identifying nodes with CPIC errors..."
    
    # Find nodes that have ANY CPICs without CloudResponseSuccess assigned to them
    # This includes CPICs with CloudResponseError, CloudResponsePending, or no success condition
    # Check both spec.node and status.node for node assignments
    local jq_nodes_file=$(mktemp)
    cat > "$jq_nodes_file" <<'JQ_EOF'
.items[] | 
select(
    ((.status.conditions // []) | length == 0) or
    ([(.status.conditions[]? | select(.reason == "CloudResponseSuccess"))] | length == 0)
) |
select((.spec.node != null and .spec.node != "") or (.status.node != null and .status.node != "")) |
(.status.node // .spec.node)
JQ_EOF
    local nodes_with_errors=$(echo "$cpic_json" | jq -r -f "$jq_nodes_file" 2>/dev/null | sort -u)
    rm -f "$jq_nodes_file"
    
    # Debug: show how many nodes with errors were found and list them
    local error_nodes_count=$(echo "$nodes_with_errors" | grep -v '^$' | wc -l | tr -d ' ')
    if [ "${error_nodes_count:-0}" -gt 0 ]; then
        log_info "Found $error_nodes_count unique node(s) with CPIC errors:"
        echo "$nodes_with_errors" | grep -v '^$' | while read -r node; do
            [ -n "$node" ] && log_info "  - $node"
        done
    fi
    
    if [ -n "$nodes_with_errors" ] && [ -n "$failed_cpics_debug" ]; then
        log_info "Nodes with failed CPICs (no CloudResponseSuccess) found:"
        echo "$nodes_with_errors" | while read -r node; do
            if [ -n "$node" ]; then
                local error_count=$(echo "$failed_cpics_debug" | jq -r "select(.node == \"$node\") | .name" 2>/dev/null | wc -l | tr -d ' ')
                log_info "  - $node ($error_count failed CPIC(s))"
            fi
        done
    else
        log_info "No nodes with CPIC errors detected"
        # Debug: show sample of CPICs assigned to nodes to help identify error patterns
        # Check both spec.node and status.node
        log_info "Debug: Checking CPICs assigned to nodes (sample of first 5):"
        local jq_sample_file=$(mktemp)
        cat > "$jq_sample_file" <<'JQ_EOF'
.items[] | 
select((.spec.node != null and .spec.node != "") or (.status.node != null and .status.node != "")) |
"\(.metadata.name)|\(.status.node // .spec.node // "unknown")|\(.spec.node // "none")|\(.status.node // "none")|\(.status.conditions | length)"
JQ_EOF
        local sample_assigned=$(echo "$cpic_json" | jq -r -f "$jq_sample_file" 2>/dev/null | head -5)
        rm -f "$jq_sample_file"
        
        if [ -n "$sample_assigned" ]; then
            echo "$sample_assigned" | while IFS='|' read -r name node spec_node status_node cond_count; do
                log_info "  $name on $node (spec: $spec_node, status: $status_node): $cond_count condition(s)"
            done
        else
            log_info "  (no CPICs with node assignments found)"
        fi
    fi
    
    # Build array of nodes without errors
    local nodes=()
    local nodes_with_errors_array=()
    
    # Convert nodes_with_errors to array for easier checking
    # Make sure we capture all nodes, even if there are multiple lines
    if [ -n "$nodes_with_errors" ]; then
        while IFS= read -r node; do
            if [ -n "$node" ] && [ "$node" != "null" ]; then
                nodes_with_errors_array+=("$node")
            fi
        done <<< "$nodes_with_errors"
        
        # Debug: verify all nodes were captured
        log_info "Excluding ${#nodes_with_errors_array[@]} node(s) from redistribution"
    else
        log_info "No nodes with CPIC errors to exclude"
    fi
    
    # Build list of healthy nodes (not in error list)
    for node in "${all_nodes[@]}"; do
        local has_error=0
        for error_node in "${nodes_with_errors_array[@]}"; do
            if [ "$node" = "$error_node" ]; then
                has_error=1
                break
            fi
        done
        if [ $has_error -eq 0 ]; then
            nodes+=("$node")
        fi
    done
    
    if [ ${#nodes[@]} -eq 0 ]; then
        log_error "No assignable nodes found - all nodes have failed CPICs assigned to them"
        log_error "Cannot redistribute failed CPICs when all nodes are problematic"
        log_info "Nodes with failed CPICs:"
        for node in "${all_nodes[@]}"; do
            local error_count=$(echo "$failed_cpics_debug" | jq -r "select(.node == \"$node\") | .name" 2>/dev/null | wc -l | tr -d ' ')
            log_error "  - $node: $error_count failed CPIC(s)"
        done
        log_info "Please resolve the CPIC errors on these nodes before attempting redistribution"
        return 1
    fi
    
    if [ ${#nodes[@]} -lt ${#all_nodes[@]} ]; then
        local excluded_count=$((${#all_nodes[@]} - ${#nodes[@]}))
        log_warn "Excluding $excluded_count node(s) with failed CPICs from redistribution"
        log_info "Excluded nodes:"
        for node in "${nodes_with_errors_array[@]}"; do
            local error_count=$(echo "$failed_cpics_debug" | jq -r "select(.node == \"$node\") | .name" 2>/dev/null | wc -l | tr -d ' ')
            log_info "  - $node: $error_count failed CPIC(s)"
        done
    fi
    
    log_info "Using ${#nodes[@]} assignable node(s) (without CPIC errors):"
    for node in "${nodes[@]}"; do
        log_info "  - $node"
    done
    
    # Count EIPs per node from successfully assigned CPICs
    log_info "Counting EIPs per node..."
    
    # Count successfully assigned CPICs per node using jq
    # Create a JSON object with node names and their EIP counts
    # Check both spec.node and status.node (prefer status.node as observed state)
    local jq_counts_file=$(mktemp)
    cat > "$jq_counts_file" <<'JQ_EOF'
[.items[] | 
 select((.spec.node != null and .spec.node != "") or (.status.node != null and .status.node != "")) |
 select((.status.conditions[]? | select(.reason == "CloudResponseSuccess")) != null) |
 (.status.node // .spec.node)] |
group_by(.) | 
map({node: .[0], count: length}) |
reduce .[] as $item ({}; . + {($item.node): $item.count})
JQ_EOF
    local node_counts_json=$(echo "$cpic_json" | jq -r -f "$jq_counts_file" 2>/dev/null)
    rm -f "$jq_counts_file"
    
    # Sort nodes by EIP count (ascending) - nodes with least EIPs first
    # Build sorted list using a temporary file to handle node names with spaces
    local temp_file=$(mktemp)
    for node in "${nodes[@]}"; do
        local count=$(echo "$node_counts_json" | jq -r ".[\"$node\"] // 0" 2>/dev/null || echo "0")
        # Use tab separator to safely handle node names with spaces
        printf "%s\t%s\n" "$count" "$node" >> "$temp_file"
    done
    
    # Sort by count (first field) and extract node names (second field)
    local sorted_nodes=()
    local tab_char=$(printf '\t')
    local sorted_file=$(mktemp)
    sort -n "$temp_file" > "$sorted_file"
    while IFS="$tab_char" read -r count node; do
        [ -n "$node" ] && sorted_nodes+=("$node")
    done < "$sorted_file"
    rm -f "$temp_file" "$sorted_file"
    
    log_info "Node EIP distribution:"
    for node in "${sorted_nodes[@]}"; do
        local count=$(echo "$node_counts_json" | jq -r ".[\"$node\"] // 0" 2>/dev/null || echo "0")
        log_info "  $node: $count EIPs"
    done
    
    # Distribute failed CPICs evenly across nodes
    log_info "Redistributing $failed_count failed CPICs..."
    local node_index=0
    local redistributed=0
    local failed=0
    
    for cpic_name in "${failed_array[@]}"; do
        # Round-robin assignment to nodes with least EIPs
        local target_node="${sorted_nodes[$node_index]}"
        
        # Safety check: verify target node is not in error list
        local is_error_node=0
        for error_node in "${nodes_with_errors_array[@]}"; do
            if [ "$target_node" = "$error_node" ]; then
                is_error_node=1
                log_warn "Skipping $cpic_name - target node $target_node has CPIC errors"
                failed=$((failed + 1))
                break
            fi
        done
        
        if [ $is_error_node -eq 0 ]; then
            log_info "Patching $cpic_name -> $target_node"
            
            if oc patch cloudprivateipconfig "$cpic_name" -p "{\"spec\":{\"node\": \"$target_node\"}}" --type=merge &>/dev/null; then
                redistributed=$((redistributed + 1))
            else
                log_warn "Failed to patch $cpic_name"
                failed=$((failed + 1))
            fi
        fi
        
        # Move to next node (round-robin)
        node_index=$((node_index + 1))
        if [ $node_index -ge ${#sorted_nodes[@]} ]; then
            node_index=0
        fi
    done
    
    echo ""
    if [ $redistributed -gt 0 ]; then
        log_success "Successfully redistributed $redistributed CPICs"
    fi
    if [ $failed -gt 0 ]; then
        log_warn "$failed CPICs failed to redistribute"
    fi
    
    if [ $redistributed -eq 0 ] && [ $failed -eq 0 ]; then
        log_info "No CPICs needed redistribution"
    fi
}

# Parse cleanup arguments
parse_cleanup_args() {
    local force_cleanup="false"
    local egressip_timeout="$DEFAULT_EGRESSIP_TIMEOUT"
    local namespace_timeout="$DEFAULT_NAMESPACE_TIMEOUT"
    local cleanup_stale="false"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force|-f)
                force_cleanup="true"
                shift
                ;;
            --stale|-s)
                cleanup_stale="true"
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
                echo "  --stale, -s                   Delete failed CPICs and EgressIPs with mismatches (failed CPICs or node assignment mismatches)"
                echo "  --egressip-timeout TIMEOUT     Timeout for EgressIP deletion (default: 30s)"
                echo "  --namespace-timeout TIMEOUT    Timeout for namespace deletion (default: 60s)"
                echo "  --help, -h                     Show this help"
                exit 0
                ;;
            *)
                log_error "Unknown cleanup option: $1"
                echo "Use --help for cleanup options"
                exit 1
                ;;
        esac
    done
    
    # Call cleanup function with parsed arguments
    cleanup_test_resources "$force_cleanup" "$egressip_timeout" "$namespace_timeout" "$cleanup_stale"
}

# Handle command line arguments
case "${1:-deploy}" in
    "deploy")
        # Check if second, third, and fourth arguments are numbers (IP count, namespace count, EIPs per namespace)
        ip_count="${2:-15}"
        namespace_count="${3:-4}"
        eips_per_namespace="${4:-0}"
        
        if [[ "$ip_count" =~ ^[0-9]+$ ]] && [[ "$namespace_count" =~ ^[0-9]+$ ]] && [[ "$eips_per_namespace" =~ ^[0-9]+$ ]]; then
            main "$ip_count" "$namespace_count" "$eips_per_namespace"
        elif [[ "$ip_count" =~ ^[0-9]+$ ]] && [[ "$namespace_count" =~ ^[0-9]+$ ]]; then
            main "$ip_count" "$namespace_count" "0"
        elif [[ "$ip_count" =~ ^[0-9]+$ ]]; then
            main "$ip_count" "4" "0"
        else
            main
        fi
        ;;
    "cleanup")
        # Parse cleanup arguments
        shift  # Remove cleanup from arguments
        parse_cleanup_args "$@"
        ;;
    "discover")
        check_prerequisites
        source_discovery_functions
        get_eip_ranges
        ;;
    "redistribute")
        redistribute_failed_cpics
        ;;
    "--help"|"-h"|"help")
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  deploy [ip_count] [namespace_count] [eips_per_namespace]  Deploy test EgressIP resources"
        echo "                                      ip_count: Number of IPs to deploy (1-210, default: 15)"
        echo "                                      namespace_count: Number of namespaces to create (1-200, default: 4)"
        echo "                                      eips_per_namespace: Fixed EIPs per namespace (0-50, default: 0 = auto-distribute)"
        echo "  cleanup [options]                    Remove all test resources"
        echo "                                      --force, -f: Force deletion with --force --grace-period=0"
        echo "                                      --stale, -s: Delete failed CPICs and EgressIPs with mismatches (failed CPICs or node assignment mismatches)"
        echo "                                      --egressip-timeout TIMEOUT: Timeout for EgressIP deletion (default: 30s)"
        echo "                                      --namespace-timeout TIMEOUT: Timeout for namespace deletion (default: 60s)"
        echo "  discover                             Show available EgressIP ranges"
        echo "  redistribute                         Redistribute failed CPICs to nodes with least EIPs"
        echo "  help                                 Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0 deploy                    # Deploy with default 15 IPs and 4 namespaces (auto-distribute)"
        echo "  $0 deploy 50                 # Deploy with 50 IPs and 4 namespaces (auto-distribute)"
        echo "  $0 deploy 50 8               # Deploy with 50 IPs and 8 namespaces (auto-distribute)"
        echo "  $0 deploy 20 5 3             # Deploy with 20 IPs, 5 namespaces, 3 EIPs each (fixed)"
        echo "  $0 deploy 30 6 5             # Deploy with 30 IPs, 6 namespaces, 5 EIPs each (fixed)"
        echo "  $0 cleanup                   # Clean up test resources"
        echo "  $0 cleanup --force          # Force clean up test resources"
        echo "  $0 cleanup --stale          # Delete failed CPICs and EgressIPs with mismatches (failed CPICs or node assignment mismatches)"
        echo "  $0 cleanup --force --stale  # Force delete failed CPICs and mismatched EgressIPs"
        echo "  $0 cleanup --egressip-timeout 60s --namespace-timeout 120s  # Custom timeouts"
        echo "  $0 cleanup --force --namespace-timeout 30s  # Force cleanup with custom namespace timeout"
        echo "  $0 redistribute              # Redistribute failed CPICs to nodes with least EIPs"
        ;;
    *)
        # Check if first argument is a number (IP count for deploy)
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
            ip_count="$1"
            namespace_count="${2:-4}"
            eips_per_namespace="${3:-0}"
            if [[ "$namespace_count" =~ ^[0-9]+$ ]]; then
                main "$ip_count" "$namespace_count" "$eips_per_namespace"
            else
                main "$ip_count"
            fi
        else
        log_error "Unknown command: $1"
        echo "Use \"$0 help\" for usage information"
        exit 1
        fi
        ;;
esac
