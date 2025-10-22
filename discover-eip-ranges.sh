#!/bin/bash
# discover-eip-ranges.sh - Dynamically discover EgressIP ranges from node annotations
# 
# This script extracts EgressIP CIDR ranges from OpenShift node annotations
# and generates available IP addresses for testing purposes.
#
# Usage:
#   source ./discover-eip-ranges.sh
#   CIDR=$(get_first_eip_cidr)
#   generate_test_ips "$CIDR" 10

get_eip_ranges() {
    echo "Discovering EgressIP ranges from node annotations..."
    
    # Get nodes with egress-assignable label and extract egress-ipconfig annotations
    oc get nodes -l k8s.ovn.org/egress-assignable -o json | \
    jq -r '.items[] | select(.metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]) | 
        .metadata.name + ": " + .metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]' | \
    while read -r line; do
        node_name=$(echo "$line" | cut -d: -f1)
        config=$(echo "$line" | cut -d: -f2- | tr -d "'")
        
        echo "Node: $node_name"
        echo "$config" | jq -r '.[].ifaddr.ipv4' | while read -r cidr; do
            echo "  Available CIDR: $cidr"
            echo "  Capacity: $(echo "$config" | jq -r '.[].capacity.ip') IPs"
        done
        echo
    done
}

generate_test_ips() {
    local cidr="$1"
    local count="$2"
    
    if [ -z "$cidr" ] || [ -z "$count" ]; then
        echo "Usage: generate_test_ips <cidr> <count>" >&2
        return 1
    fi
    
    # Extract network and prefix
    local network=$(echo "$cidr" | cut -d/ -f1)
    local prefix=$(echo "$cidr" | cut -d/ -f2)
    
    # Calculate network base (this is a simplified approach for /23, /24 networks)
    local base_ip=$(echo "$network" | cut -d. -f1-3)
    local last_octet=$(echo "$network" | cut -d. -f4)
    
    # Generate IP addresses (starting from .10 to avoid common reserved IPs)
    local start_ip=10
    local generated=0
    
    for i in $(seq $start_ip $((start_ip + count + 50))); do
        if [ "$prefix" -eq 24 ]; then
            # /24 network - single subnet
            if [ $i -lt 255 ]; then
                echo "${base_ip}.$i"
                generated=$((generated + 1))
            fi
        elif [ "$prefix" -eq 23 ]; then
            # /23 network - spans two /24 subnets
            if [ $i -lt 256 ]; then
                echo "${base_ip}.$i"
                generated=$((generated + 1))
            else
                local third_octet=$(echo "$base_ip" | cut -d. -f3)
                local next_third_octet=$((third_octet + 1))
                local final_octet=$((i - 256))
                if [ $final_octet -lt 255 ]; then
                    echo "$(echo "$base_ip" | cut -d. -f1-2).${next_third_octet}.$final_octet"
                    generated=$((generated + 1))
                fi
            fi
        elif [ "$prefix" -eq 22 ]; then
            # /22 network - spans four /24 subnets
            local subnet_offset=$((i / 256))
            local host_offset=$((i % 256))
            local third_octet=$(echo "$base_ip" | cut -d. -f3)
            local target_third_octet=$((third_octet + subnet_offset))
            
            if [ $subnet_offset -lt 4 ] && [ $host_offset -lt 255 ]; then
                echo "$(echo "$base_ip" | cut -d. -f1-2).${target_third_octet}.$host_offset"
                generated=$((generated + 1))
            fi
        else
            # Fallback for other network sizes
            echo "${base_ip}.$i"
            generated=$((generated + 1))
        fi
        
        [ $generated -eq $count ] && break
    done
}

# Get the first available EgressIP CIDR
get_first_eip_cidr() {
    oc get nodes -l k8s.ovn.org/egress-assignable -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]) | 
        .metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]' | \
    head -1 | tr -d "'" | jq -r '.[0].ifaddr.ipv4' 2>/dev/null || echo ""
}

# Get all available EgressIP CIDRs
get_all_eip_cidrs() {
    oc get nodes -l k8s.ovn.org/egress-assignable -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]) | 
        .metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]' | \
    while read -r config; do
        echo "$config" | tr -d "'" | jq -r '.[].ifaddr.ipv4' 2>/dev/null
    done
}

# Validate that a CIDR has available capacity
check_eip_capacity() {
    local cidr="$1"
    local needed="$2"
    
    # Get existing EgressIP allocations
    local used_ips=$(oc get egressip -o json 2>/dev/null | jq -r '.items[].spec.egressIPs[]' | wc -l)
    
    # Calculate total capacity from CIDR
    local prefix=$(echo "$cidr" | cut -d/ -f2)
    local total_capacity=$((2 ** (32 - prefix) - 2))  # Subtract network and broadcast
    
    local available=$((total_capacity - used_ips))
    
    if [ $available -ge $needed ]; then
        echo "✅ CIDR $cidr has $available IPs available (need $needed)"
        return 0
    else
        echo "❌ CIDR $cidr has only $available IPs available (need $needed)"
        return 1
    fi
}

# Export functions for use in other scripts
export -f get_eip_ranges generate_test_ips get_first_eip_cidr get_all_eip_cidrs check_eip_capacity

# If script is run directly, show discovery information
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "🔍 EgressIP Range Discovery"
    echo "=========================="
    echo ""
    
    # Check if cluster is accessible
    if ! oc whoami &>/dev/null; then
        echo "❌ Not logged into OpenShift cluster"
        echo "Please run 'oc login' first"
        exit 1
    fi
    
    echo "Current cluster: $(oc whoami --show-server 2>/dev/null || echo 'Unknown')"
    echo "Current user: $(oc whoami 2>/dev/null || echo 'Unknown')"
    echo ""
    
    # Show available EgressIP configuration
    get_eip_ranges
    
    # Show first available CIDR for quick testing
    FIRST_CIDR=$(get_first_eip_cidr)
    if [ -n "$FIRST_CIDR" ]; then
        echo "🎯 First available CIDR: $FIRST_CIDR"
        echo ""
        echo "📋 Sample generated IPs (first 5):"
        generate_test_ips "$FIRST_CIDR" 5
    else
        echo "❌ No EgressIP configuration found"
        echo ""
        echo "To enable EgressIP:"
        echo "1. Label worker nodes: oc label node <node> k8s.ovn.org/egress-assignable=''"
        echo "2. Verify cloud provider configuration is present"
    fi
fi
