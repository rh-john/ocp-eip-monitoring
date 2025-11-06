# 🚀 Enhanced EIP Monitoring - Comprehensive Metrics & Alerting

The EIP monitoring solution now includes **50+ advanced metrics** and **30+ intelligent alerts** for comprehensive OpenShift EIP and CPIC monitoring, capacity planning, and operational excellence.

## 📊 **Complete Metrics Catalog (50+ Metrics)**

### **Core EIP Metrics** (6 metrics)
| Metric | Description | Type |
|--------|-------------|------|
| `eips_configured_total` | Total configured EIPs | Gauge |
| `eips_assigned_total` | Total assigned EIPs | Gauge |
| `eips_unassigned_total` | Total unassigned EIPs | Gauge |
| `eip_utilization_percent` | EIP utilization percentage | Gauge |
| `eip_assignment_rate_per_minute` | EIP assignment rate | Gauge |
| `eip_unassignment_rate_per_minute` | EIP unassignment rate | Gauge |

### **CPIC Status Metrics** (6 metrics)
| Metric | Description | Labels |
|--------|-------------|--------|
| `cpic_success_total` | Successful CPIC resources | - |
| `cpic_pending_total` | Pending CPIC resources | - |
| `cpic_error_total` | Error CPIC resources | - |
| `cpic_transitions_per_minute` | CPIC state transition rate | - |
| `cpic_pending_duration_seconds` | Time in pending state | resource_name |
| `cpic_error_duration_seconds` | Time in error state | resource_name |

### **Per-Node Metrics** (10 metrics)
| Metric | Description | Labels |
|--------|-------------|--------|
| `node_cpic_success_total` | Node CPIC success count | node |
| `node_cpic_pending_total` | Node CPIC pending count | node |
| `node_cpic_error_total` | Node CPIC error count | node |
| `node_eip_assigned_total` | Node EIP assignment count | node |
| `node_eip_primary_total` | Primary EIP count per node (first IP from each resource) | node |
| `node_eip_secondary_total` | Secondary EIP count per node (remaining IPs) | node |
| `node_eip_capacity_total` | Node EIP capacity | node |
| `node_eip_utilization_percent` | Node EIP utilization % | node |
| `eip_nodes_available_total` | Available EIP nodes count | - |
| `eip_nodes_with_errors_total` | Nodes with CPIC errors | - |

### **API Performance Metrics** (3 metrics)
| Metric | Description | Labels |
|--------|-------------|--------|
| `api_response_time_seconds` | API response time | operation |
| `api_success_rate_percent` | API success rate | operation |
| `api_calls_total` | Total API calls (counter) | operation, status |

### **Distribution & Fairness Metrics** (4 metrics)
| Metric | Description | Use Case |
|--------|-------------|----------|
| `eip_distribution_stddev` | Standard deviation of EIP distribution | Load balance analysis |
| `eip_distribution_gini_coefficient` | Gini coefficient (0=fair, 1=unfair) | Inequality measurement |
| `eip_max_per_node` | Maximum EIPs on any node | Hotspot detection |
| `eip_min_per_node` | Minimum EIPs on any node | Underutilization detection |

### **Historical Trend Metrics** (2 metrics)
| Metric | Description | Purpose |
|--------|-------------|---------|
| `eip_changes_last_hour` | EIP changes in last hour | Stability tracking |
| `cpic_recoveries_last_hour` | CPIC recoveries in last hour | Recovery rate analysis |

### **Health & Stability Metrics** (2 metrics)
| Metric | Description | Range |
|--------|-------------|-------|
| `cluster_eip_health_score` | Overall cluster health score | 0-100 |
| `cluster_eip_stability_score` | Stability score (change frequency) | 0-100 |

### **Health Status Metrics** (6 metrics)
| Metric | Description | Use Case |
|--------|-------------|----------|
| `malfunctioning_eip_objects_count` | Number of EIP resources with EIP-CPIC mismatches | Detect misaligned resources |
| `overcommitted_eip_objects_count` | Total overcommitted IPs (when configured > available nodes) | Capacity planning |
| `critical_eip_objects_count` | Number of EIP resources with no working assignments | Critical issue detection |
| `eip_cpic_mismatches_total` | Total count of all EIP-CPIC mismatches | Overall mismatch tracking |
| `eip_cpic_mismatches_node_mismatch` | IPs with different node assignments in EIP vs CPIC | Node assignment issues |
| `eip_cpic_mismatches_missing_in_eip` | IPs in CPIC but missing from EIP status.items | Stale CPIC detection |

### **Monitoring System Metrics** (4 metrics)
| Metric | Description | Purpose |
|--------|-------------|---------|
| `eip_scrape_errors_total` | Total scrape errors (counter) | Error tracking |
| `eip_last_scrape_timestamp_seconds` | Last successful scrape time | Freshness monitoring |
| `eip_scrape_duration_seconds` | Time to complete collection | Performance monitoring |
| `eip_monitoring_info` | Static monitoring information | Metadata |

## 🚨 **Comprehensive Alert Rules (30+ Alerts)**

### **Core EIP Alerts** (6 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `EIPNotAssigned` | Unassigned EIPs > 0 for 5m | Warning | EIPs not fully assigned |
| `EIPAssignmentStuckLongTerm` | Unassigned EIPs > 0 for 15m | Critical | EIP assignment stuck for extended period |
| `EIPCountDecreased` | EIP count decreased in 5m | Info | EIP count decreased (may be intentional removal) |
| `EIPCountIncreased` | EIP count increased in 5m | Info | EIP count increased (may be intentional addition) |
| `EIPUtilizationHigh` | Utilization 90-99% for 5m | Warning | High EIP utilization |
| `EIPUtilizationCritical` | Utilization 95-99% for 2m | Critical | Critical EIP utilization |
| `EIPCapacityFullyUtilized` | Utilization = 100% for 10m | Info | All EIPs assigned (normal for fully deployed) |

#### **🎯 Intelligent Alert Behavior**

The EIP alerts are designed to be **lifecycle-aware** and distinguish between intentional EIP changes and genuine problems:

**✅ Intentional EIP Removal:**
- `EIPCountDecreased` fires (Info level) - "EIP count decreased, may be intentional"
- `EIPNotAssigned` does NOT fire - recognizes EIPs were removed, not stuck
- No false warnings when cleaning up EIPs

**✅ Intentional EIP Addition:**
- `EIPCountIncreased` fires (Info level) - "EIP count increased, may be intentional"
- `EIPNotAssigned` may fire if assignment is slow (Warning level)
- `EIPAssignmentStuckLongTerm` fires if truly stuck (Critical level)

**✅ 100% Utilization (Normal Operation):**
- `EIPCapacityFullyUtilized` fires (Info level) - "All EIPs assigned, this is normal"
- No critical alerts for expected 100% utilization
- Critical alerts only fire for concerning 90-99% utilization

**✅ Stuck EIP Assignment (Real Problem):**
- `EIPNotAssigned` fires after 5 minutes (Warning)
- `EIPAssignmentStuckLongTerm` fires after 15 minutes (Critical)
- Escalating severity for persistent issues

### **CPIC Health Alerts** (3 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `CPICErrors` | Error count > 0 for 2m | Critical | CPIC resources in error |
| `CPICPendingTooLong` | Pending > 0 for 10m | Warning | CPIC pending too long |
| `CPICPendingCritical` | Pending > 0 for 30m | Critical | CPIC stuck in pending |

### **Distribution & Capacity Alerts** (4 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `EIPDistributionUnfair` | Gini > 0.4 for 10m | Warning | Uneven EIP distribution |
| `EIPDistributionExtreme` | Gini > 0.7 for 5m | Critical | Extreme distribution inequality |
| `NodeEIPCapacityWarning` | Node utilization > 80% for 10m | Warning | Node capacity warning |
| `NodeEIPCapacityCritical` | Node utilization > 95% for 5m | Critical | Node capacity critical |

### **Cluster Health Alerts** (3 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `ClusterEIPHealthLow` | Health score < 70 for 10m (only when EIPs configured) | Warning | Low cluster health |
| `ClusterEIPHealthCritical` | Health score < 50 for 5m (only when EIPs configured) | Critical | Critical cluster health |
| `ClusterEIPInstability` | Stability < 70 for 15m (only when EIPs configured) | Warning | Cluster instability |

### **API Performance Alerts** (4 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `APIResponseTimeSlow` | Response time > 10s for 5m | Warning | Slow API responses |
| `APIResponseTimeCritical` | Response time > 30s for 2m | Critical | Critical API slowness |
| `APISuccessRateLow` | Success rate < 95% for 5m | Warning | Low API success rate |
| `APISuccessRateCritical` | Success rate < 80% for 2m | Critical | Critical API failures |

### **Node & Infrastructure Alerts** (2 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `EIPNodesWithErrors` | Error nodes > 0 for 5m | Warning | Nodes have CPIC errors |
| `EIPNodesUnavailable` | Available nodes = 0 for 1m | Critical | No EIP nodes available |

### **Trend & Pattern Alerts** (2 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `HighEIPChangeRate` | Changes/hour > 50 for 10m | Warning | High change rate |
| `FrequentCPICRecoveries` | Recoveries/hour > 10 for 15m | Warning | Frequent recoveries |

### **Duration-Based Alerts** (2 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `CPICPendingTooLongSpecific` | Pending > 30min for 5m | Critical | Specific resource stuck |
| `CPICErrorTooLongSpecific` | Error > 1hr for 10m | Critical | Specific resource failing |

### **Monitoring System Alerts** (4 alerts)
| Alert | Condition | Severity | Description |
|-------|-----------|----------|-------------|
| `EIPMetricsScrapeErrors` | Errors > 3 in 5m for 1m | Warning | Metrics collection errors |
| `EIPMonitoringDown` | Service down for 3m | Critical | Monitoring service down |
| `EIPMetricsStale` | No updates for 5m | Critical | Stale metrics data |
| `SlowMetricsCollection` | Collection > 60s for 5m | Warning | Slow metrics collection |

## 🎯 **Use Cases & Benefits**

### **Capacity Planning**
- **EIP Utilization Tracking**: Monitor current and projected EIP usage
- **Node Capacity Analysis**: Identify nodes approaching EIP limits
- **Distribution Optimization**: Ensure fair EIP distribution across nodes

### **Performance Monitoring**
- **API Response Times**: Track OpenShift API performance for EIP operations
- **Success Rate Monitoring**: Monitor API call reliability
- **Scrape Performance**: Ensure efficient metrics collection

### **Operational Excellence**
- **Health Scoring**: Single metric for overall cluster EIP health
- **Stability Tracking**: Monitor configuration stability over time
- **Trend Analysis**: Historical pattern recognition for proactive management

### **Troubleshooting & Diagnostics**
- **Error Duration Tracking**: Identify resources stuck in error states
- **Recovery Monitoring**: Track how quickly issues resolve
- **Node-Specific Issues**: Pinpoint problematic nodes quickly

### **Fairness & Load Balancing**
- **Gini Coefficient**: Mathematical measure of distribution fairness
- **Standard Deviation**: Statistical measure of distribution consistency
- **Min/Max Tracking**: Identify outlier nodes

## 📈 **Advanced Query Examples**

### **Capacity Planning Queries**
```promql
# EIP exhaustion prediction (linear extrapolation)
predict_linear(eips_assigned_total[1h], 24*3600) > eips_configured_total

# Node capacity headroom
(node_eip_capacity_total - node_eip_assigned_total) / node_eip_capacity_total * 100

# Distribution fairness over time
rate(eip_distribution_gini_coefficient[5m])
```

### **Performance Analysis Queries**
```promql
# API performance degradation
(api_response_time_seconds - api_response_time_seconds offset 1h) / api_response_time_seconds offset 1h * 100

# Success rate trends
rate(api_calls_total{status="success"}[5m]) / rate(api_calls_total[5m]) * 100

# Error correlation analysis
(cpic_error_total > 0) and (api_success_rate_percent < 95)
```

### **Health & Stability Queries**
```promql
# Composite health indicator
(cluster_eip_health_score + cluster_eip_stability_score) / 2

# Change rate correlation with health
rate(eip_changes_last_hour[30m]) and (cluster_eip_health_score < 80)

# Recovery efficiency
cpic_recoveries_last_hour / cpic_error_total
```

### **Mismatch & Health Status Queries**
```promql
# Overall mismatch rate
eip_cpic_mismatches_total / eips_configured_total * 100

# Node mismatch breakdown
eip_cpic_mismatches_node_mismatch

# Critical resources percentage
critical_eip_objects_count / count(count by (namespace, name) (eips_configured_total)) * 100

# Overcommitted IPs per resource
overcommitted_eip_objects_count

# Primary vs Secondary EIP distribution
sum(node_eip_primary_total) / sum(node_eip_secondary_total)

# Malfunctioning resources alert condition
malfunctioning_eip_objects_count > 0
```

## 🔧 **Configuration & Tuning**

### **Alert Thresholds**
All alert thresholds are configurable via the ServiceMonitor. Key parameters:

- **EIP Utilization**: Warning at 90%, Critical at 95%
- **API Performance**: Warning at 10s, Critical at 30s
- **Health Scores**: Warning < 70, Critical < 50
- **Distribution Fairness**: Warning Gini > 0.4, Critical > 0.7

### **Capacity Estimation**
Node EIP capacity is configurable via environment variable. Default is 75 EIPs per node:

```bash
# Set via environment variable
export EIP_CAPACITY_PER_NODE=75  # Default value
export EIP_CAPACITY_PER_NODE=50  # For more conservative capacity
export EIP_CAPACITY_PER_NODE=100 # For higher capacity nodes
```

The capacity affects:
- Node utilization calculations
- Capacity warning/critical alerts
- Health score calculations
- Distribution fairness metrics

### **Historical Data Retention**
- API performance history: Last 100 measurements
- EIP change history: Last 1 hour
- CPIC recovery history: Last 1 hour

## 🎉 **Deployment**

Deploy this comprehensive monitoring solution:

```bash
# Automated deployment with registry
./scripts/build-and-deploy.sh all -r quay.io/your-registry

# Or for manifest updates only (keeps existing image)
./scripts/build-and-deploy.sh deploy

# Create test EgressIPs for monitoring validation  
./scripts/deploy-test-eips.sh deploy

# Create test EgressIPs with fixed distribution (3 EIPs per namespace)
./scripts/deploy-test-eips.sh deploy 20 5 3

# Verify metrics collection
curl http://eip-monitor:8080/metrics | grep eip_
```

For detailed deployment instructions, see [CONTAINER_DEPLOYMENT.md](CONTAINER_DEPLOYMENT.md).

All 50+ metrics and 30+ alerts are immediately available in Prometheus and AlertManager!
