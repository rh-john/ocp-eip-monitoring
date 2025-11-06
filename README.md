# OpenShift EIP Monitoring

A monitoring solution for OpenShift Egress IP (EIP) and CloudPrivateIPConfig (CPIC) resources that exposes Prometheus metrics and alerts.

## Prerequisites

- OpenShift 4.18+
- User Workload Monitoring enabled
- EgressIP feature enabled

## Quick Start

```bash
# Build and deploy
./scripts/build-and-deploy.sh all -r quay.io/your-registry

# Or deploy with existing image
oc apply -f k8s/k8s-manifests.yaml
oc apply -f k8s/servicemonitor.yaml
```

## Architecture

The EIP monitoring solution integrates with OpenShift's User Workload Monitoring to collect metrics and generate alerts for EgressIP and CloudPrivateIPConfig resources.

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
    
    subgraph "User Workload Monitoring"
        PROM[Prometheus<br/>Scrapes Metrics]
        AM[AlertManager<br/>Fires Alerts]
        RULES[PrometheusRule<br/>Alert Definitions]
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
- **ServiceMonitor**: Configures Prometheus to scrape metrics from the eip-monitor service
- **PrometheusRule**: Defines alert rules for EIP utilization, assignment status, CPIC errors, and cluster health
- **Prometheus**: Collects and stores metrics, evaluates alert rules
- **AlertManager**: Handles alert routing and notifications

## User Workload Monitoring Setup

**Required**: Enable User Workload Monitoring in OpenShift:

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

## Installation

### Method 1: Automated Build and Deploy
```bash
git clone https://github.com/rh-john/ocp-eip-monitoring.git
cd ocp-eip-monitoring
./scripts/build-and-deploy.sh all -r quay.io/your-registry
```

### Method 2: Deploy with Pre-built Image
```bash
oc new-project eip-monitoring
oc apply -f k8s/k8s-manifests.yaml
oc apply -f k8s/servicemonitor.yaml
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `SCRAPE_INTERVAL` | Metrics collection interval (seconds) | `30` |
| `PORT` | HTTP server port | `8080` |
| `LOG_LEVEL` | Logging level | `INFO` |

## Key Metrics

- `eips_configured_total` - Total configured EIPs
- `eips_assigned_total` - Total assigned EIPs  
- `eips_unassigned_total` - Total unassigned EIPs
- `eip_utilization_percent` - EIP utilization percentage
- `cpic_success_total` - Successful CPIC resources
- `cpic_error_total` - Error CPIC resources
- `node_eip_assigned_total` - EIPs assigned per node

## Key Alerts

- **EIPUtilizationCritical**: EIP utilization > 95%
- **EIPNotAssigned**: Unassigned EIPs detected
- **CPICErrors**: CPIC resources in error state
- **ClusterEIPHealthCritical**: Cluster health score < 50

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

**Note**: The deployment script intelligently handles changes:
- **Preserves existing IPs**: When increasing distribution, existing IPs remain assigned and new ones are added
- **Smart scaling**: Detects existing configurations and only updates what's needed
- **Distribution changes**: Allows changing IP distribution without full reassignment

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
# Check user workload monitoring
oc get pods -n openshift-user-workload-monitoring

# Test metrics endpoint
oc exec deployment/eip-monitor -n eip-monitoring -- curl -s http://localhost:8080/metrics
```

**Alerts not firing:**
```bash
# Check AlertManager is running
oc get pods -n openshift-user-workload-monitoring | grep alertmanager

# Verify PrometheusRule
oc get prometheusrule eip-monitor-alerts -n eip-monitoring
```

## Project Structure

```
ocp-eip-monitoring/
├── src/metrics_server.py          # Core monitoring application
├── k8s/                           # Kubernetes manifests
│   ├── k8s-manifests.yaml         # Deployment resources
│   └── servicemonitor.yaml        # Prometheus configuration
├── scripts/                       # Operational scripts
│   ├── build-and-deploy.sh        # Build and deployment
│   ├── deploy-test-eips.sh        # Test EIP creation and CPIC redistribution
│   └── discover-eip-ranges.sh     # IP range discovery
└── docs/                          # Documentation
    ├── CONTAINER_DEPLOYMENT.md    # Deployment guide
    └── ENHANCED_METRICS_GUIDE.md  # Metrics reference
```

## Documentation

- **[Deployment Guide](docs/CONTAINER_DEPLOYMENT.md)** - Complete deployment instructions
- **[Metrics Reference](docs/ENHANCED_METRICS_GUIDE.md)** - All metrics and alerts

## License

This project is provided as-is for OpenShift EIP monitoring and analysis.

## About Me

**John Johansson**  
*Specialist Adoption Architect at Red Hat*

I specialize in helping organizations successfully adopt and optimize OpenShift deployments. This EIP monitoring tool was developed to address real-world observability needs for OpenShift Egress IP management.

Connect with me for OpenShift architecture guidance, best practices, and advanced monitoring solutions.