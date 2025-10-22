# OpenShift EIP Monitoring - Deployment Guide

This guide provides comprehensive instructions for deploying and operating the OpenShift EIP monitoring solution that exposes 40+ Prometheus metrics and 25+ alerts for monitoring Egress IP (EIP) and CloudPrivateIPConfig (CPIC) resources.

## Overview

The containerized EIP monitor provides:
- **Real-time monitoring** of OpenShift EIP and CPIC resources
- **40+ advanced Prometheus metrics** for comprehensive observability
- **25+ intelligent alerts** for capacity planning and troubleshooting
- **Health scoring and stability tracking** for operational excellence
- **Distribution fairness analysis** with Gini coefficient calculations
- **API performance monitoring** with response time and success rate tracking
- **Historical trend analysis** for proactive capacity management
- **Secure, production-ready deployment** in OpenShift 4.18
- **Simplified deployment** with no external cloud dependencies

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Prometheus    │◄───│  EIP Monitor    │◄───│   OpenShift     │
│   (Scraping)    │    │   Container     │    │   API Server    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                              │
                              ▼
                    OpenShift EIP & CPIC Resources
```

## Components

| Component | Purpose |
|-----------|---------|
| `metrics_server.py` | Core Python Flask application for metrics collection and exposition |
| `Dockerfile` | Multi-stage container build with OpenShift CLI and monitoring tools |
| `entrypoint.sh` | Container lifecycle management and health checks |
| `k8s-manifests.yaml` | Complete OpenShift deployment resources (RBAC, ConfigMap, Deployment, Service) |
| `servicemonitor.yaml` | Prometheus ServiceMonitor and comprehensive alerting rules |
| `build-and-deploy.sh` | Automated build, push, and deployment script |
| `test-deployment.sh` | Deployment validation and health check script |
| `deploy-test-eips.sh` | Automated test EgressIP creation for monitoring validation |
| `discover-eip-ranges.sh` | Dynamic EgressIP range discovery from cluster configuration |

## Quick Start

### 1. Build the Container Image

```bash
# Build the image
podman build -t eip-monitor:latest .

# Or using Docker
docker build -t eip-monitor:latest .

# Tag for your registry
podman tag eip-monitor:latest your-registry.com/eip-monitor:latest
podman push your-registry.com/eip-monitor:latest
```

### 2. Update Configuration

Edit `k8s-manifests.yaml`:

```yaml
# Update the image reference in the Deployment
image: "your-registry.com/eip-monitor:latest"
```

### 3. Deploy to OpenShift

```bash
# Apply the manifests
oc apply -f k8s-manifests.yaml

# Wait for deployment
oc rollout status deployment/eip-monitor -n eip-monitoring

# Check logs
oc logs -f deployment/eip-monitor -n eip-monitoring
```

### 4. Set up Prometheus Monitoring

```bash
# Apply ServiceMonitor (if using Prometheus Operator)
oc apply -f servicemonitor.yaml

# Verify metrics endpoint
oc port-forward svc/eip-monitor 8080:8080 -n eip-monitoring
curl http://localhost:8080/metrics
```

## Available Metrics (40+ Total)

### Core EIP Metrics (6)
- `eips_configured_total` - Total configured EIPs
- `eips_assigned_total` - Total assigned EIPs  
- `eips_unassigned_total` - Total unassigned EIPs
- `eip_utilization_percent` - EIP utilization percentage
- `eip_assignment_rate_per_minute` - EIP assignment rate
- `eip_unassignment_rate_per_minute` - EIP unassignment rate

### CPIC Status Metrics (6)
- `cpic_success_total` - Successful CPIC resources
- `cpic_pending_total` - Pending CPIC resources
- `cpic_error_total` - Error CPIC resources
- `cpic_transitions_per_minute` - CPIC state transition rate
- `cpic_pending_duration_seconds{resource_name}` - Time in pending state
- `cpic_error_duration_seconds{resource_name}` - Time in error state

### Per-Node Metrics (8)
- `node_cpic_success_total{node}` - CPIC success per node
- `node_cpic_pending_total{node}` - CPIC pending per node
- `node_cpic_error_total{node}` - CPIC errors per node
- `node_eip_assigned_total{node}` - EIPs assigned per node
- `node_eip_capacity_total{node}` - Node EIP capacity
- `node_eip_utilization_percent{node}` - Node EIP utilization
- `eip_nodes_available_total` - Available EIP-enabled nodes
- `eip_nodes_with_errors_total` - Nodes with CPIC errors

### Distribution & Fairness Metrics (4)
- `eip_distribution_stddev` - Standard deviation of EIP distribution
- `eip_distribution_gini_coefficient` - Gini coefficient (0=fair, 1=unfair)
- `eip_max_per_node` - Maximum EIPs on any node
- `eip_min_per_node` - Minimum EIPs on any node

### Health & Performance Metrics (8)
- `cluster_eip_health_score` - Overall cluster health (0-100)
- `cluster_eip_stability_score` - Stability score (0-100)
- `api_response_time_seconds{operation}` - API response times
- `api_success_rate_percent{operation}` - API success rates
- `api_calls_total{operation,status}` - Total API calls
- `eip_changes_last_hour` - EIP changes in last hour
- `cpic_recoveries_last_hour` - CPIC recoveries in last hour
- `eip_scrape_duration_seconds` - Metrics collection duration

### Monitoring System Metrics (4)
- `eip_scrape_errors_total` - Total scrape errors
- `eip_last_scrape_timestamp_seconds` - Last successful scrape timestamp
- `eip_monitoring_info` - Static monitoring information with enhanced details

📊 **See `ENHANCED_METRICS_GUIDE.md` for complete metrics catalog and advanced usage examples.**

## Configuration

### Environment Variables

| Variable | Required | Description | Default |
|----------|----------|-------------|---------|
| `PORT` | No | Metrics server port | 8080 |
| `SCRAPE_INTERVAL` | No | Metrics collection interval (seconds) | 30 |

### Container Modes

The container supports multiple run modes:

```bash
# Metrics server mode (default)
docker run eip-monitor

# One-time monitoring
docker run eip-monitor monitor

# Interactive shell for debugging
docker run -it eip-monitor shell
```

## Required Permissions

### OpenShift RBAC

The service account needs cluster-level permissions:

```yaml
# Included in k8s-manifests.yaml
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["k8s.ovn.org"]  
  resources: ["egressips"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["cloud.network.openshift.io"]
  resources: ["cloudprivateipconfigs"]
  verbs: ["get", "list", "watch"]
```

### External Dependencies

**None** - The monitoring solution is fully self-contained within OpenShift:
- Uses OpenShift service account tokens for authentication
- Requires only cluster-level read access to EIP and CPIC resources
- No external API calls or cloud provider dependencies
- All required tools (oc CLI, jq, Python libraries) are embedded in the container

## Monitoring and Alerting

### Health Checks

The container provides health endpoints:

```bash
curl http://pod-ip:8080/health
curl http://pod-ip:8080/       # Basic info
curl http://pod-ip:8080/metrics # Prometheus metrics
```

### Built-in Alerts (25+ Total)

The `servicemonitor.yaml` includes comprehensive Prometheus alerting rules:

#### **Core EIP Alerts** (3)
- **EIPNotAssigned** - EIPs configured but not assigned
- **EIPUtilizationHigh** - EIP utilization > 90%
- **EIPUtilizationCritical** - EIP utilization > 95%

#### **CPIC Health Alerts** (3)
- **CPICErrors** - CPIC resources in error state  
- **CPICPendingTooLong** - CPIC resources pending > 10 minutes
- **CPICPendingCritical** - CPIC resources stuck > 30 minutes

#### **Capacity & Distribution Alerts** (4)
- **EIPDistributionUnfair** - Gini coefficient > 0.4 (uneven distribution)
- **EIPDistributionExtreme** - Gini coefficient > 0.7 (severe imbalance)
- **NodeEIPCapacityWarning** - Node utilization > 80%
- **NodeEIPCapacityCritical** - Node utilization > 95%

#### **Health & Performance Alerts** (7)
- **ClusterEIPHealthLow** - Health score < 70
- **ClusterEIPHealthCritical** - Health score < 50
- **ClusterEIPInstability** - Stability score < 70
- **APIResponseTimeSlow** - API response > 10s
- **APIResponseTimeCritical** - API response > 30s
- **APISuccessRateLow** - Success rate < 95%
- **APISuccessRateCritical** - Success rate < 80%

#### **Operational Alerts** (8+)
- **EIPNodesWithErrors** - Nodes have CPIC errors
- **EIPNodesUnavailable** - No EIP nodes available
- **HighEIPChangeRate** - High change frequency
- **FrequentCPICRecoveries** - Frequent error recoveries
- **CPICPendingTooLongSpecific** - Resource-specific duration alerts
- **EIPMetricsScrapeErrors** - Metrics collection failures
- **EIPMonitoringDown** - Service is down
- **EIPMetricsStale** - Outdated metrics data

🚨 **See `ENHANCED_METRICS_GUIDE.md` for complete alert catalog with thresholds and severity levels.**

## Creating Test EgressIPs

### Multiple EgressIP Examples for Testing

To test the EIP monitoring functionality, you can create multiple EgressIP resources with different configurations:

#### Example 1: Basic EgressIP Configuration
```yaml
# This example will be populated with dynamic IPs from cluster discovery
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-web
spec:
  egressIPs:
  - <discovered-from-node-annotation>.10
  - <discovered-from-node-annotation>.11
  namespaceSelector:
    matchLabels:
      name: web-apps
```

#### Example 2: Multi-Node EgressIP
```yaml
# Multiple IPs for production database tier
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-database
spec:
  egressIPs:
  - <discovered-from-node-annotation>.12
  - <discovered-from-node-annotation>.13
  - <discovered-from-node-annotation>.14
  namespaceSelector:
    matchLabels:
      environment: production
      tier: database
```

#### Example 3: Development Environment EgressIP
```yaml
# Single IP for development workloads
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-dev
spec:
  egressIPs:
  - <discovered-from-node-annotation>.15
  namespaceSelector:
    matchLabels:
      environment: development
```

#### Example 4: High-Availability EgressIP
```yaml
# Multiple IPs for HA API gateway
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-ha-api
spec:
  egressIPs:
  - <discovered-from-node-annotation>.16
  - <discovered-from-node-annotation>.17
  - <discovered-from-node-annotation>.18
  - <discovered-from-node-annotation>.19
  namespaceSelector:
    matchLabels:
      app: api-gateway
```

**Note**: The actual IP addresses will be automatically discovered from your cluster's node annotations and populated by the deployment script.

### Test Namespace Creation

Create matching namespaces for the EgressIP examples:

```bash
# Create test namespaces with appropriate labels
oc create namespace web-apps
oc label namespace web-apps name=web-apps

oc create namespace prod-db  
oc label namespace prod-db environment=production tier=database

oc create namespace dev-env
oc label namespace dev-env environment=development

oc create namespace api-services
oc label namespace api-services app=api-gateway
```

### Node Preparation

Ensure nodes are properly labeled for EgressIP assignment:

```bash
# List available nodes
oc get nodes

# Label nodes for egress IP assignment (required for EgressIP to work)
oc label node <worker-node-1> k8s.ovn.org/egress-assignable=""
oc label node <worker-node-2> k8s.ovn.org/egress-assignable=""
oc label node <worker-node-3> k8s.ovn.org/egress-assignable=""

# Verify node labels
oc get nodes -l k8s.ovn.org/egress-assignable
```

**Note**: EgressIP automatically selects from nodes labeled with `k8s.ovn.org/egress-assignable=""`. The node assignment is managed by OpenShift's network operator and cannot be directly controlled through the EgressIP specification.

### Dynamic EgressIP Discovery

First, let's create a script to discover available EgressIP ranges from node annotations:

```bash
#!/bin/bash
# discover-eip-ranges.sh - Dynamically discover EgressIP ranges from node annotations

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
        done
        echo
    done
}

generate_test_ips() {
    local cidr="$1"
    local count="$2"
    
    # Extract network and prefix
    local network=$(echo "$cidr" | cut -d/ -f1)
    local prefix=$(echo "$cidr" | cut -d/ -f2)
    
    # Calculate network base (this is a simplified approach for /23, /24 networks)
    local base_ip=$(echo "$network" | cut -d. -f1-3)
    local last_octet=$(echo "$network" | cut -d. -f4)
    
    # Generate IP addresses (starting from .10 to avoid common reserved IPs)
    local start_ip=10
    local generated=0
    
    for i in $(seq $start_ip $((start_ip + count - 1))); do
        if [ "$prefix" -eq 24 ]; then
            echo "${base_ip}.$i"
        elif [ "$prefix" -eq 23 ]; then
            # For /23 networks, we have two octets worth of space
            if [ $i -lt 256 ]; then
                echo "${base_ip}.$i"
            else
                local next_octet=$(($(echo "$base_ip" | cut -d. -f3) + 1))
                local final_octet=$((i - 256))
                echo "$(echo "$base_ip" | cut -d. -f1-2).${next_octet}.$final_octet"
            fi
        fi
        generated=$((generated + 1))
        [ $generated -eq $count ] && break
    done
}

# Get the first available EgressIP CIDR
get_first_eip_cidr() {
    oc get nodes -l k8s.ovn.org/egress-assignable -o json | \
    jq -r '.items[] | select(.metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]) | 
        .metadata.annotations["cloud.network.openshift.io/egress-ipconfig"]' | \
    head -1 | tr -d "'" | jq -r '.[0].ifaddr.ipv4' 2>/dev/null || echo ""
}

# Export functions for use in other scripts
export -f get_eip_ranges generate_test_ips get_first_eip_cidr
```

### Deploy All Test EgressIPs

Create a comprehensive test script that uses dynamic IP discovery:

```bash
#!/bin/bash
# deploy-test-eips.sh - Dynamic EgressIP deployment with auto-discovery

# Source the discovery functions
source ./discover-eip-ranges.sh

echo "🔍 Discovering EgressIP configuration from cluster..."

# Get the first available EgressIP CIDR
CIDR=$(get_first_eip_cidr)

if [ -z "$CIDR" ]; then
    echo "❌ No EgressIP configuration found on nodes"
    echo "Please ensure nodes are labeled with k8s.ovn.org/egress-assignable=\"\""
    echo "And have the cloud.network.openshift.io/egress-ipconfig annotation"
    exit 1
fi

echo "✅ Found EgressIP CIDR: $CIDR"

# Generate test IP addresses
echo "🎯 Generating test IP addresses..."

# Use portable method instead of readarray (not available in all bash versions)
TEST_IPS=()
while IFS= read -r line; do
    TEST_IPS+=("$line")
done < <(generate_test_ips "$CIDR" 15)

if [ ${#TEST_IPS[@]} -lt 10 ]; then
    echo "❌ Could not generate enough IP addresses from CIDR $CIDR"
    exit 1
fi

echo "✅ Generated ${#TEST_IPS[@]} test IP addresses:"
printf '   %s\n' "${TEST_IPS[@]:0:5}" "   ..."

echo ""
echo "📋 Creating test namespaces..."
oc create namespace web-apps --dry-run=client -o yaml | oc apply -f -
oc label namespace web-apps name=web-apps --overwrite

oc create namespace prod-db --dry-run=client -o yaml | oc apply -f -  
oc label namespace prod-db environment=production tier=database --overwrite

oc create namespace dev-env --dry-run=client -o yaml | oc apply -f -
oc label namespace dev-env environment=development --overwrite

oc create namespace api-services --dry-run=client -o yaml | oc apply -f -
oc label namespace api-services app=api-gateway --overwrite

echo ""
echo "🚀 Deploying EgressIP configurations with discovered IPs..."
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-eip-web
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
echo "✅ Test EgressIPs created successfully!"
echo "📊 Summary:"
echo "   - CIDR discovered: $CIDR"
echo "   - IPs allocated: ${#TEST_IPS[@]}"
echo "   - EgressIPs created: 4"
echo ""
echo "🔍 Verification commands:"
echo "   oc get egressip"
echo "   oc get egressip -o wide"
echo "   oc get cloudprivateipconfig"
```

### Verification Commands

After creating the test EgressIPs, verify they're working:

```bash
# List all EgressIPs
oc get egressip

# Detailed view with node assignments
oc get egressip -o wide

# Check individual EgressIP status
oc describe egressip test-eip-web
oc describe egressip test-eip-database

# Verify CPIC resources are created
oc get cloudprivateipconfig

# Check which nodes have EIP assignments
oc get nodes -o custom-columns="NAME:.metadata.name,EGRESS-IPS:.metadata.annotations.k8s\.ovn\.org/node-gateway-router-lrp-ifaddr"

# Monitor the EIP monitoring metrics
curl http://eip-monitor-service:8080/metrics | grep eip
```

### Testing Different Scenarios

#### Scenario 1: Test EIP Utilization
```bash
# Create EgressIPs with different utilization levels
# This will help test the utilization metrics and alerts

# High utilization (90%+ of IPs assigned)
# First, discover available IPs
CIDR=$(get_first_eip_cidr)
UTIL_IPS=()
while IFS= read -r line; do
    UTIL_IPS+=("$line")
done < <(generate_test_ips "$CIDR" 5)

oc apply -f - <<EOF
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-high-util
spec:
  egressIPs:
  - ${UTIL_IPS[0]}
  - ${UTIL_IPS[1]}
  namespaceSelector:
    matchLabels:
      test: high-utilization
EOF
```

#### Scenario 2: Test Distribution Fairness
```bash
# Create EgressIPs that might create uneven distribution
# This will test the Gini coefficient and distribution metrics

# Discover available IPs for distribution testing
CIDR=$(get_first_eip_cidr)
DIST_IPS=()
while IFS= read -r line; do
    DIST_IPS+=("$line")
done < <(generate_test_ips "$CIDR" 10)

for i in {1..5}; do
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: test-dist-${i}
spec:
  egressIPs:
  - ${DIST_IPS[$((i-1))]}
  namespaceSelector:
    matchLabels:
      test-group: distribution-${i}
EOF
done
```

### Cleanup Test Resources

When testing is complete:

```bash
#!/bin/bash
# cleanup-test-eips.sh

echo "Removing test EgressIPs..."
oc delete egressip test-eip-web test-eip-database test-eip-dev test-eip-ha-api test-high-util
oc delete egressip -l test=high-utilization
oc delete egressip test-dist-{1..5} 2>/dev/null

echo "Removing test namespaces..."
oc delete namespace web-apps prod-db dev-env api-services

echo "Cleanup complete!"
```

### Important Notes for EgressIP Configuration

**Dynamic IP Discovery**:
- IP addresses are automatically discovered from node annotations `cloud.network.openshift.io/egress-ipconfig`
- The system extracts CIDR ranges (e.g., "10.0.2.0/23") and generates available IPs
- IPs are selected starting from .10 in the range to avoid common reserved addresses
- Each IP can only be assigned to one EgressIP resource at a time

**Node Selection Behavior**:
- OpenShift automatically assigns EgressIPs to nodes labeled with `k8s.ovn.org/egress-assignable=""`
- Node assignment is managed by the network operator and cannot be directly controlled
- Multiple EgressIPs in a resource may be assigned to different nodes for HA
- If a node becomes unavailable, EgressIPs are automatically moved to other eligible nodes

**Testing Recommendations**:
- Test in a development cluster before using in production
- Verify network connectivity from assigned nodes to target destinations
- Monitor CPIC (CloudPrivateIPConfig) resources for assignment status
- Use `oc get egressip -o wide` to see current node assignments

## Troubleshooting

### Common Issues

1. **Permission Denied - OpenShift API**
   ```bash
   # Check service account permissions
   oc auth can-i get egressips --as=system:serviceaccount:eip-monitoring:eip-monitor
   
   # Verify cluster role binding
   oc describe clusterrolebinding eip-monitor
   ```

2. **Container Resources**
   ```bash
   # Check resource limits and requests
   oc describe pod -l app=eip-monitor -n eip-monitoring
   
   # Check resource usage
   oc top pod -l app=eip-monitor -n eip-monitoring
   ```

3. **No EIP Nodes Found**
   ```bash
   # Check if nodes have EIP label  
   oc get nodes -l k8s.ovn.org/egress-assignable=true
   
   # Check EIP resources exist
   oc get egressips
   ```

4. **Metrics Not Updating**
   ```bash
   # Check container logs
   oc logs -f deployment/eip-monitor -n eip-monitoring
   
   # Verify health endpoint
   oc port-forward svc/eip-monitor 8080:8080 -n eip-monitoring
   curl http://localhost:8080/health
   ```

### Debug Mode

Run the container in debug mode:

```bash
# Deploy with shell mode for debugging
oc run eip-debug --image=eip-monitor:latest --rm -it --restart=Never -- shell

# Inside the pod, run commands manually:
python3 /app/metrics_server.py
oc get eip -o json | jq
oc get cloudprivateipconfig -o json | jq
```

### Logs Analysis

```bash
# Check startup logs
oc logs deployment/eip-monitor -n eip-monitoring --previous

# Follow live logs
oc logs -f deployment/eip-monitor -n eip-monitoring

# Check events
oc get events -n eip-monitoring --sort-by='.lastTimestamp'
```

## Production Considerations

### Security
- Uses non-root user (UID 1000)
- Read-only root filesystem
- Drops all capabilities
- Network policies restrict traffic
- Secrets for sensitive data

### Resource Management
- Resource requests/limits defined
- Horizontal Pod Autoscaler compatible
- Runs as single replica (monitoring workload)

### High Availability
- Health checks configured
- Graceful shutdown handling
- Pod disruption budget recommended for production

### Scaling
- Single replica sufficient for most clusters
- Consider multiple replicas only for very large clusters
- Metrics collection is lightweight

## Integration Examples

### Grafana Dashboard Query Examples

```promql
# EIP Assignment Rate
rate(eips_assigned_total[5m])

# CPIC Error Percentage
(cpic_error_total / (cpic_success_total + cpic_pending_total + cpic_error_total)) * 100

# Node EIP Distribution
sum by (node) (node_eip_assigned_total)

# EIP Utilization
(eips_assigned_total / eips_configured_total) * 100
```

### Custom Alerts

```yaml
# High EIP utilization alert
- alert: HighEIPUtilization
  expr: (eips_assigned_total / eips_configured_total) > 0.8
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High EIP utilization"
    description: "EIP utilization is above 80%"
```

## Support

For issues with:
- **Container deployment**: Check this documentation and pod logs
- **EIP monitoring configuration**: Review k8s-manifests.yaml and ServiceMonitor setup
- **OpenShift EIP feature**: Consult OpenShift documentation
- **RBAC and permissions**: Check service account permissions and cluster roles
