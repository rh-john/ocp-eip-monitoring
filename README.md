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
# Deploy test EgressIPs
./scripts/deploy-test-eips.sh deploy

# Clean up test resources  
./scripts/deploy-test-eips.sh cleanup
```

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
│   ├── deploy-test-eips.sh        # Test EIP creation
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