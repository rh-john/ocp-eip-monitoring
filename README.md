# OpenShift EIP Monitoring

> **⚠️ DISCLAIMER: This is a Proof of Concept (PoC) application intended for learning purposes only.**
> 
> This monitoring solution should **ONLY** be deployed in well-contained, sandboxed environments for educational and testing purposes. It is **NOT** intended for production use or enterprise deployments.

Monitoring solution for OpenShift Egress IP (EIP) and CloudPrivateIPConfig (CPIC) resources. Exposes Prometheus metrics and alerts.

## Prerequisites

- OpenShift 4.18+
- Monitoring infrastructure: Either **Cluster Observability Operator (COO)** or **User Workload Monitoring (UWM)** enabled
- EgressIP feature enabled

## Quick Start

```bash
# Build and deploy
./scripts/deploy-eip.sh all -r quay.io/your-registry

# Or deploy with existing image
oc apply -f k8s/deployment/k8s-manifests.yaml
```

## Architecture

Integrates with OpenShift monitoring infrastructure (COO or UWM) to collect metrics and generate alerts for EgressIP and CloudPrivateIPConfig resources. Supports both **Cluster Observability Operator (COO)** and **User Workload Monitoring (UWM)** monitoring stacks, and can run both simultaneously.

```mermaid
graph TB
    subgraph "OpenShift Cluster"
        subgraph "Worker Nodes"
            N1[Node 1<br/>Egress Assignable]
            N2[Node 2<br/>Egress Assignable]
            N3[Node 3<br/>Egress Assignable]
        end
        
        subgraph "EgressIP Resources"
            EIP1[EgressIP 1<br/>Namespace: app-1]
            EIP2[EgressIP 2<br/>Namespace: app-2]
            EIPN[EgressIP N<br/>Namespace: app-n]
        end
        
        subgraph "CloudPrivateIPConfig"
            CPIC1[CPIC 10.0.2.100<br/>Node: N1]
            CPIC2[CPIC 10.0.2.101<br/>Node: N2]
            CPICN[CPIC 10.0.2.X<br/>Node: N3]
        end
        
        subgraph "eip-monitoring Namespace"
            MONITOR[eip-monitor Pod<br/>Metrics Server]
            SERVICE[Service<br/>eip-monitor:8080]
        end
    end
    
    subgraph "Monitoring Infrastructure"
        subgraph "COO or UWM"
            PROM[Prometheus<br/>Scrapes Metrics]
            AM[AlertManager<br/>Fires Alerts]
            RULES[PrometheusRule<br/>Alert Definitions]
        end
    end
    
    subgraph "External"
        USER[Administrator<br/>Views Metrics/Alerts]
        GRAFANA[Grafana<br/>Dashboards]
    end
    
    N1 --> EIP1
    N2 --> EIP2
    N3 --> EIPN
    
    EIP1 --> CPIC1
    EIP2 --> CPIC2
    EIPN --> CPICN
    
    CPIC1 --> N1
    CPIC2 --> N2
    CPICN --> N3
    
    MONITOR -->|Queries API| EIP1
    MONITOR -->|Queries API| EIP2
    MONITOR -->|Queries API| EIPN
    MONITOR -->|Queries API| CPIC1
    MONITOR -->|Queries API| CPIC2
    MONITOR -->|Queries API| CPICN
    
    MONITOR -->|Exposes| SERVICE
    SERVICE -->|Scrapes| PROM
    RULES -->|Evaluates| PROM
    PROM -->|Sends Alerts| AM
    AM -->|Notifies| USER
    PROM -->|Queries| GRAFANA
    GRAFANA -->|Visualizes| USER
    
    style MONITOR fill:#e1f5ff
    style PROM fill:#fff4e1
    style AM fill:#ffe1e1
    style SERVICE fill:#e1f5ff
```

### Component Overview

- **eip-monitor**: Python Flask application that queries the OpenShift API for EgressIP and CPIC resources and exposes Prometheus metrics
- **ServiceMonitor**: Configures Prometheus to scrape metrics from the eip-monitor service (supports both COO and UWM)
- **PrometheusRule**: Defines alert rules for EIP utilization, assignment status, CPIC errors, and cluster health
- **Prometheus**: Collects and stores metrics, evaluates alert rules (COO or UWM)
- **AlertManager**: Handles alert routing and notifications

## Monitoring Infrastructure Setup

The EIP monitoring solution supports two monitoring stack options:

### Option 1: Cluster Observability Operator (COO)

COO provides a dedicated monitoring stack in your namespace with full control over Prometheus configuration.

**Deploy COO monitoring:**
```bash
# Install COO operator (if not already installed)
oc apply -f k8s/monitoring/coo/operator/coo-operator-subscription.yaml

# Deploy COO monitoring infrastructure
./scripts/deploy-monitoring.sh coo
```

**Benefits:**
- Dedicated Prometheus instance in your namespace
- Full control over Prometheus configuration
- High availability with multiple replicas
- Persistent storage support
- Ideal for sandbox and development environments

### Option 2: User Workload Monitoring (UWM)

UWM uses the cluster's shared monitoring infrastructure for user workloads.

**Enable UWM (requires cluster-admin):**
```bash
# Enable user workload monitoring
oc -n openshift-monitoring edit configmap cluster-monitoring-config
```

Add to the ConfigMap:
```yaml
data:
  config.yaml: |
    enableUserWorkload: true
```

```bash
# Enable alerting
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    alertmanager:
      enabled: true
      enableAlertmanagerConfig: true
EOF
```

**Deploy UWM monitoring:**
```bash
./scripts/deploy-monitoring.sh uwm
```

**Benefits:**
- Uses cluster-managed monitoring infrastructure
- No additional operator installation required
- Shared Prometheus for multiple workloads
- Ideal for production environments

### Option 3: Both COO and UWM (Simultaneous)

You can run both monitoring stacks simultaneously for redundancy and comparison:

```bash
# Deploy both stacks
./scripts/deploy-monitoring.sh coo
./scripts/deploy-monitoring.sh uwm
```

See [Deploying Both COO and UWM](docs/DEPLOY_BOTH_MONITORING.md) for detailed instructions.

## Installation

### Method 1: Automated Build and Deploy
```bash
git clone https://github.com/rh-john/ocp-eip-monitoring.git
cd ocp-eip-monitoring
./scripts/deploy-eip.sh all -r quay.io/your-registry
```

### Method 2: Deploy with Pre-built Image
```bash
oc new-project eip-monitoring
oc apply -f k8s/deployment/k8s-manifests.yaml
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `SCRAPE_INTERVAL` | Metrics collection interval (seconds) | `30` |
| `PORT` | HTTP server port | `8080` |
| `LOG_LEVEL` | Logging level | `INFO` |
| `EIP_CAPACITY_PER_NODE` | Maximum EIPs per node for capacity calculations | `75` |

## Metrics

Exposes metrics for EIP and CPIC monitoring. Core metrics:

- `eips_configured_total` - Total configured EIPs
- `eips_assigned_total` - Total assigned EIPs  
- `eips_unassigned_total` - Total unassigned EIPs
- `eip_utilization_percent` - EIP utilization percentage
- `cpic_success_total` - Successful CPIC resources
- `cpic_error_total` - Error CPIC resources
- `node_eip_assigned_total` - EIPs assigned per node

Additional metrics include distribution fairness (Gini coefficient), health scores, API performance, and historical trends.

See [Metrics Reference](docs/ENHANCED_METRICS_GUIDE.md) for complete metrics catalog.

## Alerts

Alert rules for EIP and CPIC monitoring. Core alerts:

- **EIPUtilizationCritical**: EIP utilization > 95%
- **EIPNotAssigned**: Unassigned EIPs detected
- **CPICErrors**: CPIC resources in error state
- **ClusterEIPHealthCritical**: Cluster health score < 50

Additional alerts cover distribution, capacity, API performance, node health, trends, and monitoring system status.

See [Metrics Reference](docs/ENHANCED_METRICS_GUIDE.md) for complete alert catalog.

## Usage

### View Metrics
```bash
# Port-forward to access metrics
oc port-forward service/eip-monitor 8080:8080 -n eip-monitoring
curl http://localhost:8080/metrics
```

### Testing
```bash
# Deploy test EgressIPs with default settings (15 IPs, 4 namespaces, auto-distribute)
./scripts/deploy-test-eips.sh deploy

# Deploy with custom IP and namespace counts (auto-distribute)
./scripts/deploy-test-eips.sh deploy 20 5

# Deploy with fixed EIPs per namespace (3 EIPs each)
./scripts/deploy-test-eips.sh deploy 20 5 3

# Scale up/down: Change IP count or namespace count (preserves existing assignments)
./scripts/deploy-test-eips.sh deploy 50 10  # Scale to 50 IPs, 10 namespaces
./scripts/deploy-test-eips.sh deploy 30 6   # Scale down to 30 IPs, 6 namespaces

# Change distribution: Adjust EIPs per namespace (preserves existing IPs, adds new ones)
./scripts/deploy-test-eips.sh deploy 90 30   # Change from 3 IPs/ns to auto-distribute 90 IPs over 30 namespaces

# Clean up test resources  
./scripts/deploy-test-eips.sh cleanup

# Redistribute failed CPICs to healthy nodes (excludes nodes with CPIC errors)
./scripts/deploy-test-eips.sh redistribute
```

**Note**: The deployment script preserves existing IPs when scaling and only updates what's needed.

### Verification
```bash
# Check deployment
oc get pods -n eip-monitoring

# Check metrics
oc exec deployment/eip-monitor -n eip-monitoring -- curl -s http://localhost:8080/metrics | head -10
```

## Troubleshooting

**No metrics appearing:**
```bash
# Check monitoring infrastructure (COO or UWM)
# For COO:
oc get pods -n eip-monitoring -l app.kubernetes.io/name=prometheus

# For UWM:
oc get pods -n openshift-user-workload-monitoring

# Test metrics endpoint
oc exec deployment/eip-monitor -n eip-monitoring -- curl -s http://localhost:8080/metrics
```

**Alerts not firing:**
```bash
# Check AlertManager is running
# For COO:
oc get pods -n eip-monitoring -l app.kubernetes.io/name=alertmanager

# For UWM:
oc get pods -n openshift-user-workload-monitoring | grep alertmanager

# Verify PrometheusRule
# For COO:
oc get prometheusrule -n eip-monitoring -l coo=eip-monitoring

# For UWM:
oc get prometheusrule eip-monitor-alerts-uwm -n eip-monitoring
```

## Project Structure

```
ocp-eip-monitoring/
├── src/metrics_server.py          # Core monitoring application
├── k8s/                           # Kubernetes manifests
│   ├── deployment/
│   │   └── k8s-manifests.yaml     # Deployment resources (includes Service, Deployment, RBAC, etc.)
│   ├── monitoring/                # Monitoring infrastructure (COO/UWM)
│   └── grafana/                   # Grafana dashboards and configuration
├── scripts/                       # Operational scripts
│   ├── deploy-eip.sh              # Build and deployment
│   ├── deploy-monitoring.sh       # Deploy monitoring infrastructure (COO/UWM)
│   ├── deploy-grafana.sh          # Deploy Grafana operator and dashboards
│   ├── deploy-test-eips.sh        # Test EIP creation and CPIC redistribution
│   ├── test/
│   │   ├── test-monitoring-deployment.sh  # Monitoring tests
│   └── lib/                       # Shared script library
│       └── common.sh              # Common functions (pod finding, logging, prerequisites)
├── tests/                         # Test suites
│   └── e2e/                       # End-to-end tests
│       ├── test-monitoring-e2e.sh # E2E monitoring tests
│       └── test-uwm-grafana-e2e.sh # E2E Grafana tests
└── docs/                          # Documentation
    ├── CONTAINER_DEPLOYMENT.md    # Deployment guide
    └── ENHANCED_METRICS_GUIDE.md  # Complete metrics and alerts reference (50+ metrics, 30+ alerts)
```

## Scripts and Automation

### Shared Library

The project includes a shared library (`scripts/lib/common.sh`) that provides reusable functions for:
- **Pod Finding**: Locate Prometheus, ThanosQuerier, and Grafana pods using multiple selector strategies
- **Logging**: Consistent logging functions (`log_info`, `log_success`, `log_warn`, `log_error`)
- **Prerequisites**: Check for required tools (`oc`, `jq`) and cluster connectivity
- **Resource Waiting**: Wait for Kubernetes resources and pods to become ready
- **Helper Functions**: `oc_cmd()` and `oc_cmd_silent()` for verbose mode handling

**Usage in scripts:**
```bash
# Source the common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "${PROJECT_ROOT}/scripts/lib/common.sh"

# Use shared functions
find_prometheus_pod "$NAMESPACE" "true"
find_query_pod "$NAMESPACE" "true"
check_prerequisites
```

### Key Scripts

- **`scripts/deploy-monitoring.sh`**: Deploy COO or UWM monitoring infrastructure
- **`scripts/deploy-grafana.sh`**: Deploy Grafana operator, instance, and dashboards
- **`scripts/test/test-monitoring-deployment.sh`**: Monitoring verification
- **`tests/e2e/test-monitoring-e2e.sh`**: End-to-end monitoring tests
- **`tests/e2e/test-uwm-grafana-e2e.sh`**: End-to-end Grafana deployment tests

All scripts use the shared `common.sh` library for consistent behavior and reduced code duplication.

## Documentation

- [Deployment Guide](docs/CONTAINER_DEPLOYMENT.md) - Deployment instructions
- [Metrics Reference](docs/ENHANCED_METRICS_GUIDE.md) - Metrics and alerts catalog
- [E2E Tests](tests/e2e/README.md) - End-to-end testing
- [Grafana Dashboards](k8s/grafana/README.md) - Dashboard documentation

## License

This project is provided as-is for OpenShift EIP monitoring and analysis.

## About Me

**John Johansson**  
*Specialist Adoption Architect at Red Hat*

I specialize in helping organizations successfully adopt and optimize OpenShift deployments. This EIP monitoring tool was developed to address real-world observability needs for OpenShift Egress IP management.

Connect with me for OpenShift architecture guidance, best practices, and advanced monitoring solutions.