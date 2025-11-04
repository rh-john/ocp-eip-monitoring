# OpenShift EIP Monitoring - Deployment Guide

This guide provides comprehensive instructions for deploying and operating the OpenShift EIP monitoring solution that exposes 40+ Prometheus metrics and 30+ intelligent alerts for monitoring Egress IP (EIP) and CloudPrivateIPConfig (CPIC) resources.

## Overview

The containerized EIP monitor provides:
- **Real-time monitoring** of OpenShift EIP and CPIC resources
- **40+ advanced Prometheus metrics** for comprehensive observability
- **25+ intelligent alerts** for capacity planning and troubleshooting
- **Health scoring and stability tracking** for operational excellence
- **Distribution fairness analysis** with Gini coefficient calculations
- **API performance monitoring** with response time and success rate tracking
- **Historical trend analysis** for proactive capacity management
- **Secure deployment** designed for OpenShift 4.18
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
| `build-and-deploy.sh` | Build, push, and deployment script |
| `test-deployment.sh` | Deployment validation and health check script |
| `deploy-test-eips.sh` | Automated test EgressIP creation for monitoring validation |
| `discover-eip-ranges.sh` | Dynamic EgressIP range discovery from cluster configuration |

## Quick Start

### Option 1: Use Pre-built Image (Recommended for Testing)

If you want to skip the build process, you can use the pre-built image from Quay.io:

```bash
# Clone repository for manifests
git clone https://github.com/rh-john/ocp-eip-monitoring.git
cd ocp-eip-monitoring

# Deploy with pre-built image (see step 3 for deployment)
# Image: quay.io/rh_ee_jjohanss/eip-monitor:latest
```

### Option 2: Build Your Own Container Image

```bash
# Build the image
podman build -t eip-monitor:latest .

# Or using Docker
docker build -t eip-monitor:latest .

# Tag for your registry
podman tag eip-monitor:latest your-registry.com/eip-monitor:latest
podman push your-registry.com/eip-monitor:latest
```

### Step 2: Update Configuration

Edit `k8s-manifests.yaml`:

```yaml
# Update the image reference in the Deployment
image: "your-registry.com/eip-monitor:latest"
```

### Step 3: Deploy to OpenShift

## 🚀 **Deployment Script**

The `build-and-deploy.sh` script provides ease of deployment:

### **📋 Script Commands**

| Command | Description | Use Case |
|---------|-------------|----------|
| `build` | Build container image locally | Development |
| `push` | Push image to registry | CI/CD pipeline |
| `deploy` | Deploy manifests to OpenShift | Manifest updates |
| `all` | Build + Push + Deploy | Full deployment |
| `test` | Validate deployment | Verification |
| `logs` | Show container logs | Debugging |
| `clean` | Remove deployment | Cleanup |

### **🎯 Intelligent Image Handling**

#### **✅ Without Registry (Local Development):**
```bash
./scripts/build-and-deploy.sh deploy
# Result:
# - Uses current deployment's image (no pull errors)
# - Applies all manifests (deployment, ServiceMonitor, ConfigMap, etc.)
# - Perfect for manifest updates (alert rules, config changes)
```

#### **✅ With Registry (Production Deployment):**
```bash
./scripts/build-and-deploy.sh deploy -r quay.io/your-org
# Result:
# - Uses registry image: quay.io/your-org/eip-monitor:latest
# - Applies all manifests with new image
# - Full deployment with updated container
```

#### **✅ Full Pipeline:**
```bash
./scripts/build-and-deploy.sh all -r quay.io/your-org
# Result:
# - Builds new image
# - Pushes to registry
# - Deploys with new image
```

### **📊 Usage Examples**

#### **For Manifest Updates (ServiceMonitor, ConfigMap, etc.):**
```bash
# Update alert rules, config changes, etc.
./scripts/build-and-deploy.sh deploy
```

#### **For New Container Image:**
```bash
# Deploy with new image from registry
./scripts/build-and-deploy.sh deploy -r quay.io/your-org
```

#### **For Full Development Cycle:**
```bash
# Build, push, and deploy
./scripts/build-and-deploy.sh all -r quay.io/your-org
```

### **🔧 Advanced Options**

```bash
# Custom image tag
./scripts/build-and-deploy.sh deploy -r quay.io/your-org -t v1.2.3

# Custom namespace
./scripts/build-and-deploy.sh deploy -n my-monitoring

# Show help
./scripts/build-and-deploy.sh --help
```

### Step 3: Deploy to OpenShift

**Option A: Using Custom Registry Image**

```bash
# Apply the manifests
oc apply -f k8s-manifests.yaml

# Wait for deployment
oc rollout status deployment/eip-monitor -n eip-monitoring

# Check logs
oc logs -f deployment/eip-monitor -n eip-monitoring
```

**Option B: Using Pre-built Image from Quay.io**

```bash
# Apply the manifests with pre-built image
oc apply -f k8s-manifests.yaml

# Update deployment to use pre-built image
oc patch deployment eip-monitor -n eip-monitoring -p '{"spec":{"template":{"spec":{"containers":[{"name":"eip-monitor","image":"quay.io/rh_ee_jjohanss/eip-monitor:latest"}]}}}}'

# Wait for deployment
oc rollout status deployment/eip-monitor -n eip-monitoring

# Check logs
oc logs -f deployment/eip-monitor -n eip-monitoring
```

> **Note**: Option B uses a pre-built container image maintained by the project maintainer, eliminating the need to build and push your own image.

### Step 4: Set up Prometheus Monitoring

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
| `EIP_CAPACITY_PER_NODE` | No | Maximum EIPs per node for capacity calculations | 75 |

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
- **ClusterEIPHealthLow** - Health score < 70 (only when EIPs configured)
- **ClusterEIPHealthCritical** - Health score < 50 (only when EIPs configured)
- **ClusterEIPInstability** - Stability score < 70 (only when EIPs configured)
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
  name: test-eip-test-ns-1
  labels:
    test-suite: eip-monitoring
    environment: test
    namespace: test-ns-1
spec:
  egressIPs:
  - <discovered-from-node-annotation>.10
  - <discovered-from-node-annotation>.11
  namespaceSelector:
    matchLabels:
      environment: production
      tier: database
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

### Automated EgressIP Testing

The repository includes an automated script to create comprehensive test EgressIP configurations for monitoring validation.

#### **Prerequisites**

1. **Label nodes for EgressIP assignment:**
   ```bash
   # List available worker nodes
   oc get nodes --no-headers -l node-role.kubernetes.io/worker | awk '{print $1}'
   
   # Label nodes for egress assignment (replace with your worker nodes)
   oc label node <worker-node-1> k8s.ovn.org/egress-assignable=""
   oc label node <worker-node-2> k8s.ovn.org/egress-assignable=""
   ```

2. **Ensure your cloud provider has configured egress IP ranges on the labeled nodes**

#### **Deploy Test EgressIPs**

Use the automated deployment script:

```bash
# Deploy test EgressIPs with automatic IP discovery
./scripts/deploy-test-eips.sh

# Or deploy with cleanup of existing test resources
./scripts/deploy-test-eips.sh deploy
```

#### **What the Script Does**

The `deploy-test-eips.sh` script automatically:

1. **🔍 Discovers EgressIP ranges** from cluster node annotations
2. **📋 Creates test namespaces** with diverse labels (up to 200 namespaces):
   - `test-ns-1` through `test-ns-200` with various application and infrastructure labels
   - Includes databases, monitoring, CI/CD, microservices, protocols, security, and testing infrastructure
3. **🚀 Deploys dynamic EgressIPs**:
   - Creates one EgressIP per namespace with appropriate labels
   - Supports flexible IP distribution modes:
     - **Auto-distribute**: Evenly distributes IPs across namespaces with extras handled
     - **Fixed per namespace**: Each namespace gets exactly the specified number of EIPs
   - Supports 1:1 IP to namespace mapping (up to 200 IPs and 200 namespaces)
   - Enables maximum granularity for namespace isolation testing

#### **Script Usage Examples**

```bash
# Deploy with default settings (15 IPs, 4 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy

# Deploy with custom IP count (50 IPs, 4 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy 50

# Deploy with custom IP and namespace counts (100 IPs, 25 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy 100 25

# Deploy with fixed EIPs per namespace (20 IPs, 5 namespaces, 3 EIPs each)
./scripts/deploy-test-eips.sh deploy 20 5 3

# Deploy with 1:1 mapping (200 IPs, 200 namespaces, 1 EIP each)
./scripts/deploy-test-eips.sh deploy 200 200 1

# Deploy with maximum scale (200 IPs, 100 namespaces, 2 EIPs each)
./scripts/deploy-test-eips.sh deploy 200 100 2

# Clean up test resources
./scripts/deploy-test-eips.sh cleanup

# Show available EgressIP ranges (discovery only)
./scripts/discover-eip-ranges.sh

# Show help and usage information
./scripts/deploy-test-eips.sh help
```

#### **Distribution Modes**

The script supports two IP distribution modes:

**Auto-Distribute Mode (Default)**
- Evenly distributes IPs across namespaces
- Handles remaining IPs by giving extras to first few namespaces
- Example: 10 IPs, 3 namespaces → 3, 3, 4 IPs respectively

**Fixed Per Namespace Mode**
- Each namespace gets exactly the specified number of EIPs
- Validates sufficient IP capacity before deployment
- Falls back to auto-distribute if insufficient IPs available
- Example: 20 IPs, 5 namespaces, 3 EIPs each → Each namespace gets exactly 3 EIPs

#### **Expected Output**

```
🚀 EgressIP Test Deployment with Dynamic Discovery
=================================================

✅ Prerequisites validated
ℹ️  Current cluster: https://api.your-cluster.com:6443
ℹ️  Current user: your-username  
ℹ️  Requested IP count: 200
ℹ️  Requested namespace count: 200
ℹ️  EIPs per namespace: auto-distribute

🔍 Discovering EgressIP configuration from cluster...
✅ Found EgressIP CIDR: 10.0.128.0/23
🎯 Generating 200 test IP addresses...
✅ Generated 200 test IP addresses

📋 Creating 200 test namespaces...
✅ Namespace 'test-ns-1' created/verified
✅ Namespace 'test-ns-2' created/verified
... (continues for all 200 namespaces)

🚀 Deploying EgressIP configurations with discovered IPs...
ℹ️  Auto distribution: 1 IP per namespace (with 0 extra IPs)
✅ Test EgressIPs deployed successfully!

📊 Deployment Summary
====================
CIDR discovered: 10.0.128.0/23
IPs requested: 200
IPs allocated: 200
Namespaces requested: 200
Namespaces created: 200
Distribution: Auto-distributed
EgressIPs created: 200
```

### Verification Commands

After creating the test EgressIPs, verify they're working:

```bash
# List all EgressIPs
oc get egressip

# Detailed view with node assignments
oc get egressip -o wide

# Check individual EgressIP status
oc describe egressip test-eip-test-ns-1
oc describe egressip test-eip-test-ns-2

# List EgressIPs with labels
oc get egressip -l test-suite=eip-monitoring

# Verify CPIC resources are created
oc get cloudprivateipconfig

# Monitor the EIP monitoring metrics
curl http://eip-monitor-service:8080/metrics | grep eip
```

### Large-Scale Testing

The script supports enterprise-scale testing scenarios with up to 200 egress IPs distributed across 200 namespaces:

#### **Maximum Scale Deployment**

```bash
# Deploy with maximum scale (200 IPs, 200 namespaces - 1:1 mapping)
./scripts/deploy-test-eips.sh deploy 200 200 1
```

This creates:
- **200 namespaces**: `test-ns-1` through `test-ns-200`
- **200 EgressIPs**: One per namespace with diverse labels
- **200 IPs total**: 1 IP per namespace (perfect 1:1 mapping)
- **Diverse labels**: Databases, monitoring, CI/CD, microservices, protocols, security, testing infrastructure

#### **Namespace Categories**

The 200 namespaces include diverse application types:

- **Databases & Storage** (test-ns-1-30): postgres, mysql, mongodb, redis, elasticsearch
- **Monitoring & Observability** (test-ns-31-50): prometheus, grafana, jaeger, datadog, newrelic
- **CI/CD & DevOps** (test-ns-51-70): jenkins, gitlab, github, azure-devops, circleci
- **Infrastructure** (test-ns-71-90): terraform, ansible, docker, kubernetes, istio
- **Microservices & Protocols** (test-ns-91-110): spring-cloud, quarkus, REST, GraphQL, gRPC
- **Security & Governance** (test-ns-111-130): compliance, audit, governance, policy, risk
- **Testing Infrastructure** (test-ns-131-200): performance, load, stress, chaos, security testing

#### **Performance Considerations**

For large-scale deployments:

```bash
# Start with moderate scale (50 IPs, 25 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy 50 25

# Gradually increase to maximum scale
./scripts/deploy-test-eips.sh deploy 100 50
./scripts/deploy-test-eips.sh deploy 150 75
./scripts/deploy-test-eips.sh deploy 200 100

# Ultimate scale with 1:1 mapping (200 IPs, 200 namespaces, 1 EIP each)
./scripts/deploy-test-eips.sh deploy 200 200 1
```

#### **Cleanup for Large Deployments**

```bash
# Clean up all test resources (handles up to 200 namespaces)
./scripts/deploy-test-eips.sh cleanup
```

### 1:1 IP to Namespace Mapping

For maximum granularity and namespace isolation testing, you can deploy with a 1:1 mapping where each namespace gets exactly one egress IP:

#### **Perfect Namespace Isolation**

```bash
# Deploy with 1:1 mapping (200 IPs, 200 namespaces, 1 EIP each)
./scripts/deploy-test-eips.sh deploy 200 200 1
```

This configuration provides:
- **Perfect Isolation**: Each namespace has its own dedicated egress IP
- **Individual Testing**: Test egress behavior per namespace independently
- **Maximum Granularity**: 200 unique egress endpoints for testing
- **Real-world Scenarios**: Simulates production environments with dedicated egress per application

#### **Use Cases for 1:1 Mapping**

1. **Security Testing**: Test firewall rules per namespace
2. **Compliance Testing**: Verify egress restrictions per application
3. **Network Isolation**: Test namespace-level network policies
4. **Load Testing**: Test egress capacity per namespace
5. **Monitoring Validation**: Verify metrics collection per namespace

#### **Verification Commands for 1:1 Mapping**

```bash
# Verify 1:1 mapping (should show 200 EgressIPs)
oc get egressip | wc -l

# Check IP distribution (should show 1 IP per EgressIP)
oc get egressip -o jsonpath='{.items[*].spec.egressIPs}' | tr ' ' '\n' | wc -l

# Verify namespace isolation
oc get egressip -o custom-columns="NAME:.metadata.name,NAMESPACE:.metadata.labels.namespace,IPS:.spec.egressIPs"
```

### Testing Different Scenarios

The `deploy-test-eips.sh` script supports various testing scenarios through different IP and namespace combinations:

#### Scenario 1: Basic Testing (Default)
```bash
# Deploy with default settings (15 IPs, 4 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy

# This creates:
# - 4 namespaces with diverse labels
# - 4 EgressIPs with 3-4 IPs each
# - Good for basic monitoring validation
```

#### Scenario 2: High-Density Testing
```bash
# Deploy with many IPs but fewer namespaces (50 IPs, 10 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy 50 10

# This creates:
# - 10 namespaces with diverse labels
# - 10 EgressIPs with 5 IPs each
# - Tests high IP utilization per namespace
```

#### Scenario 3: Fixed Distribution Testing
```bash
# Deploy with fixed EIPs per namespace (20 IPs, 5 namespaces, 3 EIPs each)
./scripts/deploy-test-eips.sh deploy 20 5 3

# This creates:
# - 5 namespaces with diverse labels
# - 5 EgressIPs with exactly 3 IPs each
# - Perfect for testing capacity limits per namespace
```

#### Scenario 4: Maximum Granularity Testing
```bash
# Deploy with 1:1 mapping (200 IPs, 200 namespaces, 1 EIP each)
./scripts/deploy-test-eips.sh deploy 200 200 1

# This creates:
# - 200 namespaces with diverse labels
# - 200 EgressIPs with 1 IP each
# - Perfect for testing namespace isolation
```

#### Scenario 5: Load Testing
```bash
# Deploy with moderate scale (100 IPs, 50 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy 100 50

# This creates:
# - 50 namespaces with diverse labels
# - 50 EgressIPs with 2 IPs each
# - Good for testing distribution and load
```

#### Scenario 5: Gradual Scale Testing
```bash
# Start small and scale up
./scripts/deploy-test-eips.sh deploy 25 10
./scripts/deploy-test-eips.sh deploy 50 20
./scripts/deploy-test-eips.sh deploy 100 40
./scripts/deploy-test-eips.sh deploy 200 100

# This tests:
# - Incremental scaling
# - Performance at different scales
# - Resource management
```

#### What Each Scenario Tests

Each scenario tests different aspects of the EIP monitoring system:

- **Basic Testing**: Validates core metrics collection and basic alerting
- **High-Density Testing**: Tests IP utilization metrics and capacity alerts
- **Maximum Granularity**: Tests namespace isolation and individual egress monitoring
- **Load Testing**: Tests distribution fairness and Gini coefficient calculations
- **Gradual Scale Testing**: Tests performance and resource management at different scales

#### Monitoring Metrics to Watch

After deploying test scenarios, monitor these key metrics:

```bash
# Check EIP configuration metrics
curl http://eip-monitor-service:8080/metrics | grep eips_configured_total

# Check IP assignment metrics
curl http://eip-monitor-service:8080/metrics | grep eips_assigned_total

# Check distribution fairness
curl http://eip-monitor-service:8080/metrics | grep eip_distribution_gini

# Check utilization metrics
curl http://eip-monitor-service:8080/metrics | grep eip_utilization
```

### Cleanup Test Resources

When testing is complete, use the built-in cleanup functionality:

```bash
# Clean up all test resources (handles up to 200 namespaces)
./scripts/deploy-test-eips.sh cleanup
```

The cleanup command automatically:
- Removes all EgressIPs with `test-suite=eip-monitoring` labels
- Deletes all test namespaces (`test-ns-1` through `test-ns-200`)
- Handles both small and large-scale deployments
- Provides feedback on cleanup progress

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
- Test thoroughly in a development cluster before deploying
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

For debugging, use the existing deployment and exec into the pod:

```bash
# Get the pod name
POD_NAME=$(oc get pods -n eip-monitoring -l app=eip-monitor -o jsonpath='{.items[0].metadata.name}')

# Exec into the pod for debugging
oc exec -it $POD_NAME -n eip-monitoring -- /bin/bash

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

## Deployment Considerations

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

### PromQL Query Examples

```promql
# CPIC Error Percentage
(cpic_error_total / (cpic_success_total + cpic_pending_total + cpic_error_total)) * 100

# Node EIP Distribution
sum by (node) (node_eip_assigned_total)

# EIP Utilization
(eips_assigned_total / eips_configured_total) * 100
```

#### **Custom Alert Examples**

```yaml
# Lifecycle-aware EIP utilization alerts
- alert: EIPUtilizationHigh
  expr: eip_utilization_percent > 90 and eip_utilization_percent < 100 and eips_configured_total > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "EIP utilization is very high"
    description: "EIP utilization is at {{ $value }}%. Consider adding more EIP capacity."

- alert: EIPCapacityFullyUtilized
  expr: eip_utilization_percent == 100
  for: 10m
  labels:
    severity: info
  annotations:
    summary: "EIP capacity is fully utilized"
    description: "All configured EIPs are assigned. This is normal for fully deployed environments."

# EIP lifecycle detection
- alert: EIPCountDecreased
  expr: delta(eips_configured_total[5m]) < -1
  for: 1m
  labels:
    severity: info
  annotations:
    summary: "EIP count decreased"
    description: "EIP count has decreased in the last 5 minutes. This may be intentional EIP removal."
```

## Support

For issues with:
- **Container deployment**: Check this documentation and pod logs
- **EIP monitoring configuration**: Review k8s-manifests.yaml and ServiceMonitor setup
- **OpenShift EIP feature**: Consult OpenShift documentation
- **RBAC and permissions**: Check service account permissions and cluster roles
