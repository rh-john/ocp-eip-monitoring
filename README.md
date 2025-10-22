# OpenShift EIP Monitoring Tool

[![OpenShift](https://img.shields.io/badge/OpenShift-4.18+-red?logo=redhat)](https://openshift.com)
[![Prometheus](https://img.shields.io/badge/Prometheus-Metrics-orange?logo=prometheus)](https://prometheus.io)
[![Container](https://img.shields.io/badge/Container-Ready-blue?logo=podman)](https://podman.io)
[![License](https://img.shields.io/badge/License-Apache%202.0-green)](LICENSE)

A comprehensive monitoring solution for OpenShift Egress IP (EIP) and CloudPrivateIPConfig (CPIC) resources that exposes **40+ advanced Prometheus metrics** and **25+ intelligent alerts** for cluster observability.

## 🚀 Quick Start

**⚠️ First**: Ensure [User Workload Monitoring and Alerting](#-user-workload-monitoring-setup) are enabled in your cluster

```bash
# Build and deploy to OpenShift
./scripts/build-and-deploy.sh all -r quay.io/your-registry

# Or deploy with existing image
oc apply -f k8s/k8s-manifests.yaml
oc apply -f k8s/servicemonitor.yaml
```

## 📋 Table of Contents

- [Features](#-features)
- [Architecture](#-architecture)
- [Prerequisites](#-prerequisites)
- [User Workload Monitoring and Alerting Setup](#-user-workload-monitoring-and-alerting-setup)
- [Installation](#-installation)
- [Troubleshooting](#-troubleshooting)
- [Configuration](#-configuration)
- [Metrics](#-metrics)
- [Alerts](#-alerts)
- [Usage](#-usage)
- [Contributing](#-contributing)
- [Important Notice](#-important-notice)

## ✨ Features

### **Comprehensive Monitoring**
- **EIP Status Tracking**: Real-time monitoring of configured, assigned, and unassigned EIPs
- **CPIC Health Monitoring**: Complete CloudPrivateIPConfig resource status tracking
- **Per-Node Metrics**: Granular monitoring of EIP assignment per OpenShift node
- **Distribution Analysis**: Fairness and balance metrics with Gini coefficient calculations
- **Performance Tracking**: API response times and success rates

### **Advanced Observability**
- **40+ Prometheus Metrics**: Covering all aspects of EIP operations
- **25+ Alert Rules**: Proactive alerting for capacity, health, and performance issues
- **Health Scoring**: Intelligent cluster health and stability scoring algorithms
- **Historical Tracking**: Trend analysis for changes and recoveries

## 🏗️ Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Prometheus    │────│   EIP Monitor    │────│   OpenShift     │
│   Server        │    │   Container      │    │   API Server    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
         │                        │                        │
         │              ┌─────────▼─────────┐              │
         │              │  Metrics Server   │              │
         │              │  (Python Flask)   │              │
         │              └─────────┬─────────┘              │
         │                        │                        │
         └────── HTTP :8080 ──────┘              oc get ──┘
                 /metrics                        eip, cpic
                 /health
```

### **Components**
- **Metrics Server**: Python Flask application collecting and exposing metrics
- **Entrypoint Script**: Container lifecycle management and health checks
- **Deployment Manifests**: Complete Kubernetes/OpenShift resource definitions
- **Monitoring Configuration**: ServiceMonitor and PrometheusRule for automated setup

## 📚 Prerequisites

### **OpenShift Environment**
- OpenShift 4.18 or later
- **User Workload Monitoring and Alerting enabled** (see [User Workload Monitoring Setup](#user-workload-monitoring-setup))
- Prometheus Operator installed (included with OpenShift)
- EIP and CPIC features enabled

### **Build Requirements** (for local build)
- Podman or Docker
- OpenShift CLI (`oc`)
- Container registry access

### **RBAC Permissions**
The monitoring tool requires cluster-level read access to EIP and CPIC resources. All necessary permissions are included in the deployment manifests.

## 🔧 User Workload Monitoring and Alerting Setup

**⚠️ CRITICAL PREREQUISITE**: This EIP monitoring tool uses `ServiceMonitor` and `PrometheusRule` resources which require **User Workload Monitoring and Alerting** to be enabled in OpenShift.

### **What is User Workload Monitoring?**

OpenShift has two separate monitoring stacks:
1. **Cluster Monitoring Stack** - Monitors OpenShift platform components (nodes, operators, etc.)
2. **User Workload Monitoring Stack** - Monitors user applications and custom metrics

By default, only the cluster monitoring stack is enabled. User applications like this EIP monitor need the **User Workload Monitoring** stack to be enabled to:
- Scrape custom metrics via `ServiceMonitor`
- Process custom alerts via `PrometheusRule` 
- Store and query custom metrics in user workload Prometheus
- **Enable alerting** for custom PrometheusRule resources

### **Enable User Workload Monitoring and Alerting**

**Step 1: Enable user workload monitoring**
```bash
# Create or edit the cluster-monitoring-config ConfigMap
oc -n openshift-monitoring edit configmap cluster-monitoring-config
```

Add or modify the ConfigMap data to include:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

**Step 2: Enable alerting for user workloads**
```bash
# Create the user workload monitoring config to enable alerting
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

**⚠️ Critical**: This ConfigMap is **REQUIRED** for:
- PrometheusRule alerts (including the stale CPIC alert) to be processed and fired
- Custom alerts to be sent to AlertManager for notification routing
- Alert rules to appear in the Prometheus rules API

**Step 3: Configure additional user workload settings (optional)**
```bash
# Optional: Configure additional settings like retention and resources
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
    prometheus:
      retention: 7d
      resources:
        requests:
          cpu: 200m
          memory: 2Gi
EOF
```

**Step 4: Verify the setup**
```bash
# Check that user workload monitoring pods are running
oc get pods -n openshift-user-workload-monitoring

# Expected output should include pods like:
# alertmanager-user-workload-*  (these are key for alerting!)
# prometheus-operator-* 
# prometheus-user-workload-*
# thanos-ruler-user-workload-*

# Verify the user workload monitoring config was created
oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o yaml

# Check that AlertManager for user workloads is running
oc get alertmanager -n openshift-user-workload-monitoring
```

### **Verify ServiceMonitor and AlertRule Discovery**

After deploying the EIP monitor, verify it's being discovered:

```bash
# Check if the ServiceMonitor is created
oc get servicemonitor -n eip-monitoring

# Check if the PrometheusRule is created
oc get prometheusrule -n eip-monitoring

# Check if Prometheus is scraping the target
oc -n openshift-user-workload-monitoring exec -c prometheus prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="eip-monitor")'

# Verify that alert rules (including StaleCPICDetected) are loaded
oc -n openshift-user-workload-monitoring exec -c prometheus prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[].rules[] | select(.name=="StaleCPICDetected")'
```


## 🛠️ Installation

### **Method 1: Automated Build and Deploy**

```bash
# Clone the repository
git clone https://github.com/rh-john/ocp-eip-monitoring.git
cd ocp-eip-monitoring

# Build and deploy (replace with your registry)
./scripts/build-and-deploy.sh all -r quay.io/your-registry

# Verify deployment
./scripts/test-deployment.sh
```

### **Method 2: Deploy with Pre-built Image**

```bash
# Clone the repository for manifests
git clone https://github.com/rh-john/ocp-eip-monitoring.git
cd ocp-eip-monitoring

# Create namespace
oc new-project eip-monitoring

# Deploy using pre-built image from Quay.io
oc apply -f k8s/k8s-manifests.yaml
oc patch deployment eip-monitor -n eip-monitoring -p '{"spec":{"template":{"spec":{"containers":[{"name":"eip-monitor","image":"quay.io/rh_ee_jjohanss/eip-monitor:latest"}]}}}}'

# Apply monitoring configuration
oc apply -f k8s/servicemonitor.yaml

# Verify deployment
oc get pods -n eip-monitoring
oc logs -f deployment/eip-monitor -n eip-monitoring
```

### **Method 3: Manual Deployment**

```bash
# Apply Kubernetes manifests
oc new-project eip-monitoring
oc apply -f k8s/k8s-manifests.yaml

# Apply monitoring configuration
oc apply -f k8s/servicemonitor.yaml

# Check deployment status
oc get pods -n eip-monitoring
```

### **Method 4: Local Development**

```bash
# Build container locally
podman build -t eip-monitor:latest .

# Run locally (requires oc login)
podman run -p 8080:8080 eip-monitor:latest
```

## 🔧 Troubleshooting

### **User Workload Monitoring Issues**

**Issue**: `ServiceMonitor` created but no metrics appear
```bash
# Check if user workload monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml

# Verify the user workload Prometheus is running
oc get prometheus -n openshift-user-workload-monitoring

# Check ServiceMonitor labels match Prometheus selectors
oc get servicemonitor eip-monitor -n eip-monitoring -o yaml
```

**Issue**: Permission denied errors
```bash
# Verify RBAC for user workload monitoring
oc adm policy who-can create servicemonitors -n eip-monitoring
oc adm policy who-can create prometheusrules -n eip-monitoring
```

**Issue**: Metrics not being scraped
```bash
# Check if the EIP monitor service is accessible
oc port-forward service/eip-monitor 8080:8080 -n eip-monitoring
curl http://localhost:8080/metrics

# Verify ServiceMonitor selector matches service labels
oc get service eip-monitor -n eip-monitoring --show-labels
oc get servicemonitor eip-monitor -n eip-monitoring -o yaml
```

**Issue**: Alerts not firing (PrometheusRule created but no alerts)
```bash
# Check if user workload monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload

# Check if user workload alerting is configured
oc get configmap user-workload-monitoring-config -n openshift-user-workload-monitoring -o yaml

# Verify AlertManager for user workloads is running
oc get pods -n openshift-user-workload-monitoring | grep alertmanager
oc get alertmanager -n openshift-user-workload-monitoring

# Verify PrometheusRule is valid and loaded
oc get prometheusrule eip-monitor-alerts -n eip-monitoring -o yaml

# Check alert rules are loaded into Prometheus
oc -n openshift-user-workload-monitoring exec -c prometheus prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.name=="eip-monitoring")'

# Check current alert status
oc -n openshift-user-workload-monitoring exec -c prometheus prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.rule.name | contains("CPIC"))'
```

### **Common Deployment Issues**

**Pod not starting:**
```bash
# Check pod status and logs
oc get pods -n eip-monitoring
oc logs -f deployment/eip-monitor -n eip-monitoring

# Verify RBAC permissions
oc auth can-i get egressips --as=system:serviceaccount:eip-monitoring:eip-monitor
```

**No metrics appearing:**
```bash
# Test metrics endpoint
oc exec deployment/eip-monitor -n eip-monitoring -- curl -s http://localhost:8080/metrics

# Check OpenShift API connectivity
oc exec deployment/eip-monitor -n eip-monitoring -- oc get eip
```

**High memory usage:**
```bash
# Check resource limits
oc describe pod -l app=eip-monitor -n eip-monitoring

# Adjust scrape interval
oc patch configmap eip-monitor-config -n eip-monitoring -p '{"data":{"scrape-interval":"60"}}'
```

### **Log Analysis**
```bash
# View detailed logs
oc logs deployment/eip-monitor -n eip-monitoring --tail=100 -f

# Filter error logs
oc logs deployment/eip-monitor -n eip-monitoring | grep ERROR
```

**📖 [Complete Deployment Guide](docs/CONTAINER_DEPLOYMENT.md)** - Detailed deployment and troubleshooting

## ⚙️ Configuration

### **Environment Variables**
| Variable | Description | Default |
|----------|-------------|---------|
| `SCRAPE_INTERVAL` | Metrics collection interval (seconds) | `30` |
| `PORT` | HTTP server port | `8080` |
| `LOG_LEVEL` | Logging level (INFO, DEBUG, WARNING, ERROR) | `INFO` |

### **ConfigMap Settings**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: eip-monitor-config
data:
  scrape-interval: "30"
  log-level: "INFO"
```

## 📊 Metrics

### **Core EIP Metrics** (6 metrics)
| Metric | Description | Type |
|--------|-------------|------|
| `eips_configured_total` | Total configured EIPs | Gauge |
| `eips_assigned_total` | Total assigned EIPs | Gauge |
| `eips_unassigned_total` | Total unassigned EIPs | Gauge |
| `eip_utilization_percent` | EIP utilization percentage | Gauge |

### **CPIC Status Metrics** (6 metrics)
| Metric | Description | Labels |
|--------|-------------|--------|
| `cpic_success_total` | Successful CPIC resources | - |
| `cpic_pending_total` | Pending CPIC resources | - |
| `cpic_error_total` | Error CPIC resources | - |
| `cpic_transitions_per_minute` | CPIC state transition rate | - |

### **Per-Node Metrics** (8 metrics)
| Metric | Description | Labels |
|--------|-------------|--------|
| `node_cpic_success_total` | CPIC success per node | `node` |
| `node_eip_assigned_total` | EIPs assigned per node | `node` |
| `node_eip_capacity_total` | Node EIP capacity | `node` |
| `node_eip_utilization_percent` | Node EIP utilization | `node` |

### **Distribution & Health Metrics** (10 metrics)
| Metric | Description | Purpose |
|--------|-------------|---------|
| `eip_distribution_gini_coefficient` | Distribution fairness (0=fair, 1=unfair) | Load balancing analysis |
| `cluster_eip_health_score` | Overall cluster health (0-100) | Health monitoring |
| `cluster_eip_stability_score` | Stability score (0-100) | Change frequency analysis |

### **API Performance Metrics** (6 metrics)
| Metric | Description | Labels |
|--------|-------------|--------|
| `api_response_time_seconds` | API response times | `operation` |
| `api_success_rate_percent` | API success rates | `operation` |
| `api_calls_total` | Total API calls | `operation`, `status` |

**📈 [Complete Metrics Guide](docs/ENHANCED_METRICS_GUIDE.md)** - Detailed documentation of all 40+ metrics

## 🚨 Alerts

### **Critical Alerts**
- **EIPUtilizationCritical**: EIP utilization > 95%
- **CPICErrors**: CPIC resources in error state
- **ClusterEIPHealthCritical**: Cluster health score < 50
- **NodeEIPCapacityCritical**: Node EIP capacity > 95%

### **Warning Alerts**
- **EIPNotAssigned**: Unassigned EIPs detected
- **CPICPendingTooLong**: CPIC resources pending > 10 minutes
- **EIPDistributionUnfair**: Uneven EIP distribution
- **APIResponseTimeSlow**: API responses > 10 seconds

**🔔 [Complete Alerts Guide](docs/ENHANCED_METRICS_GUIDE.md#-comprehensive-alert-rules-25-alerts)** - Full alert reference

## 🎯 Usage

### **View Metrics**
```bash
# Port-forward to access metrics
oc port-forward service/eip-monitor 8080:8080 -n eip-monitoring

# View Prometheus metrics
curl http://localhost:8080/metrics

# Check health status
curl http://localhost:8080/health
```

### **Query Examples**
```promql
# EIP utilization rate
rate(eips_assigned_total[5m])

# CPIC error percentage
(cpic_error_total / (cpic_success_total + cpic_pending_total + cpic_error_total)) * 100

# Per-node EIP distribution
sum by (node) (node_eip_assigned_total)

# Cluster health trend
avg_over_time(cluster_eip_health_score[1h])
```

### **Testing with EgressIPs**
```bash
# Automatically discover and deploy test EgressIPs
./scripts/deploy-test-eips.sh deploy

# Discover available IP ranges in your cluster
./scripts/discover-eip-ranges.sh

# Clean up test resources
./scripts/deploy-test-eips.sh cleanup
```

### **Debug Mode**
```bash
# Interactive debugging
oc run eip-debug --image=eip-monitor:latest --rm -it --restart=Never -- shell

# One-time metrics collection
oc run eip-test --image=eip-monitor:latest --rm --restart=Never -- monitor
```


## 📁 Project Structure

```
ocp-eip-monitoring/
├── README.md                           # Project overview and quick start
├── Dockerfile                          # Container build configuration  
├── .containerignore                    # Container build exclusions
├── docs/                               # 📚 Documentation
│   ├── CONTAINER_DEPLOYMENT.md         # Complete deployment and operations guide
│   └── ENHANCED_METRICS_GUIDE.md       # Comprehensive metrics and alerts reference
├── src/                                # 💻 Application source code
│   ├── metrics_server.py               # Core monitoring application (Python Flask)
│   └── entrypoint.sh                   # Container startup script
├── k8s/                                # ☸️ Kubernetes manifests
│   ├── k8s-manifests.yaml              # OpenShift deployment resources
│   └── servicemonitor.yaml             # Prometheus monitoring configuration
└── scripts/                            # 🔧 Operational scripts
    ├── build-and-deploy.sh             # Automated build and deployment
    ├── test-deployment.sh              # Deployment validation and testing
    ├── discover-eip-ranges.sh          # Dynamic EgressIP range discovery
    └── deploy-test-eips.sh             # Automated test EgressIP creation
```

## 🤝 Contributing

### **Development Setup**
```bash
# Local development
git clone https://github.com/rh-john/ocp-eip-monitoring.git
cd ocp-eip-monitoring

# Test Python syntax
python3 -m py_compile metrics_server.py

# Build and test locally
podman build -t eip-monitor:dev .
podman run -p 8080:8080 eip-monitor:dev
```

### **Code Standards**
- Python 3.12+ compatibility
- Prometheus metrics best practices
- OpenShift security compliance
- Comprehensive error handling

### **Testing**
```bash
# Run deployment tests
./test-deployment.sh

# Validate configuration
oc apply --dry-run=client -f k8s-manifests.yaml
```

## ⚠️ Important Notice

This monitoring tool is provided as-is for OpenShift EIP monitoring and analysis. Please:

- **Test thoroughly** in development environments before deploying to critical systems
- **Validate metrics accuracy** against your specific OpenShift configuration
- **Review and adapt alerts** to match your operational requirements
- **Monitor resource usage** and adjust scrape intervals as needed

## 📜 License

This project is provided as-is for OpenShift EIP monitoring and analysis.

## 🆘 Support

### **Documentation**
- **[Deployment Guide](docs/CONTAINER_DEPLOYMENT.md)** - Complete deployment instructions
- **[Metrics Reference](docs/ENHANCED_METRICS_GUIDE.md)** - All metrics and alerts

### **Getting Help**
For issues with:
- **Container deployment**: Check deployment documentation and logs
- **OpenShift EIP feature**: Consult OpenShift documentation  
- **OpenShift integration**: Check service account permissions and RBAC

## 👨‍💻 About Me

**John Johansson**  
*Specialist Adoption Architect at Red Hat*

I specialize in helping organizations successfully adopt and optimize OpenShift deployments. This EIP monitoring tool was developed to address real-world observability needs for OpenShift Egress IP management.

Connect with me for OpenShift architecture guidance, best practices, and advanced monitoring solutions.

---

**Built for OpenShift 4.18+**
