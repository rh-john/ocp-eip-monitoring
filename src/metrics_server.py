#!/usr/bin/env python3
"""
EIP Metrics Server for Prometheus
Exposes OpenShift EIP and CPIC metrics in Prometheus format
"""

import json
import logging
import os
import subprocess
import sys
import threading
import time
from datetime import datetime
from typing import Dict, Optional

import prometheus_client
from flask import Flask, Response
from prometheus_client import Counter, Gauge, Info, generate_latest

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Flask app
app = Flask(__name__)

# Core EIP metrics
eips_configured = Gauge('eips_configured_total', 'Total number of configured EIPs')
eips_assigned = Gauge('eips_assigned_total', 'Total number of assigned EIPs')
eips_unassigned = Gauge('eips_unassigned_total', 'Total number of unassigned EIPs')

# EIP utilization and capacity metrics
eip_utilization_percent = Gauge('eip_utilization_percent', 'Percentage of EIPs currently assigned')
eip_assignment_rate = Gauge('eip_assignment_rate_per_minute', 'Rate of EIP assignments per minute')
eip_unassignment_rate = Gauge('eip_unassignment_rate_per_minute', 'Rate of EIP unassignments per minute')

# CPIC status metrics
cpic_success = Gauge('cpic_success_total', 'Total number of successful CPIC resources')
cpic_pending = Gauge('cpic_pending_total', 'Total number of pending CPIC resources')
cpic_error = Gauge('cpic_error_total', 'Total number of error CPIC resources')

# CPIC performance metrics
cpic_transition_rate = Gauge('cpic_transitions_per_minute', 'Rate of CPIC status transitions per minute')
cpic_pending_duration = Gauge('cpic_pending_duration_seconds', 'Time CPIC resources spend in pending state', ['resource_name'])
cpic_error_duration = Gauge('cpic_error_duration_seconds', 'Time CPIC resources spend in error state', ['resource_name'])

# Per-node EIP metrics
node_cpic_success = Gauge('node_cpic_success_total', 'CPIC success count per node', ['node'])
node_cpic_pending = Gauge('node_cpic_pending_total', 'CPIC pending count per node', ['node'])
node_cpic_error = Gauge('node_cpic_error_total', 'CPIC error count per node', ['node'])
node_eip_assigned = Gauge('node_eip_assigned_total', 'EIP assigned count per node', ['node'])
node_eip_primary = Gauge('node_eip_primary_total', 'Primary EIP count per node (first IP from each resource)', ['node'])
node_eip_secondary = Gauge('node_eip_secondary_total', 'Secondary EIP count per node (remaining IPs)', ['node'])

# Node capacity and distribution metrics
node_eip_capacity = Gauge('node_eip_capacity_total', 'Maximum EIP capacity per node', ['node'])
node_eip_utilization = Gauge('node_eip_utilization_percent', 'EIP utilization percentage per node', ['node'])
node_available = Gauge('eip_nodes_available_total', 'Number of EIP-enabled nodes available')
node_with_errors = Gauge('eip_nodes_with_errors_total', 'Number of EIP-enabled nodes with CPIC errors')

# API performance metrics
api_response_time = Gauge('api_response_time_seconds', 'API response time for EIP operations', ['operation'])
api_call_success_rate = Gauge('api_success_rate_percent', 'Success rate of API calls', ['operation'])
api_calls_total = Counter('api_calls_total', 'Total number of API calls made', ['operation', 'status'])

# Distribution and fairness metrics
eip_distribution_stddev = Gauge('eip_distribution_stddev', 'Standard deviation of EIP distribution across nodes')
eip_distribution_gini = Gauge('eip_distribution_gini_coefficient', 'Gini coefficient of EIP distribution (0=perfect equality, 1=perfect inequality)')
eip_max_per_node = Gauge('eip_max_per_node', 'Maximum EIPs assigned to any single node')
eip_min_per_node = Gauge('eip_min_per_node', 'Minimum EIPs assigned to any single node')

# Historical trend metrics
eip_changes_last_hour = Gauge('eip_changes_last_hour', 'Number of EIP state changes in the last hour')
cpic_recoveries_last_hour = Gauge('cpic_recoveries_last_hour', 'Number of CPIC error recoveries in the last hour')

# Resource health indicators
cluster_eip_health_score = Gauge('cluster_eip_health_score', 'Overall EIP cluster health score (0-100)')
cluster_eip_stability_score = Gauge('cluster_eip_stability_score', 'EIP stability score based on change frequency')

# Health status metrics
malfunctioning_eip_objects_count = Gauge('malfunctioning_eip_objects_count', 'Number of EIP resources with EIP-CPIC mismatches')
overcommitted_eip_objects_count = Gauge('overcommitted_eip_objects_count', 'Total overcommitted IPs (when configured > available nodes)')
critical_eip_objects_count = Gauge('critical_eip_objects_count', 'Number of EIP resources with no working assignments')
eip_cpic_mismatches_total = Gauge('eip_cpic_mismatches_total', 'Total count of all EIP-CPIC mismatches')
eip_cpic_mismatches_node_mismatch = Gauge('eip_cpic_mismatches_node_mismatch', 'IPs with different node assignments in EIP vs CPIC')
eip_cpic_mismatches_missing_in_eip = Gauge('eip_cpic_mismatches_missing_in_eip', 'IPs in CPIC but missing from EIP status.items')

# Monitoring system metrics
monitoring_info = Info('eip_monitoring', 'EIP monitoring information')
scrape_errors = Counter('eip_scrape_errors_total', 'Total number of scrape errors')
last_scrape_timestamp = Gauge('eip_last_scrape_timestamp_seconds', 'Unix timestamp of last successful scrape')
scrape_duration_seconds = Gauge('eip_scrape_duration_seconds', 'Time taken to complete metrics collection')

class EIPMetricsCollector:
    """Collects EIP and CPIC metrics from OpenShift"""
    
    def __init__(self):
        self.scrape_interval = int(os.getenv('SCRAPE_INTERVAL', '30'))
        self.eip_nodes = []
        self.last_update = None
        
        # Data caching for performance optimization
        self.data_cache = {}
        self.cache_ttl = 10  # 10 seconds cache TTL
        self.last_cache_time = 0
        
        # Historical tracking for trend analysis (with size limits)
        self.previous_eip_counts = {}
        self.previous_cpic_states = {}
        self.eip_changes_history = []
        self.cpic_recoveries_history = []
        
        # Performance tracking (limited to 50 items per operation)
        self.api_performance_history = {
            'eip_get': [],
            'cpic_get': [],
            'nodes_get': [],
            'bulk_get': []  # New optimized operation
        }
    
    def run_oc_command(self, cmd: list, operation: str = 'unknown') -> Optional[str]:
        """Run oc command and return output with comprehensive error handling and performance tracking"""
        start_time = time.time()
        try:
            logger.debug(f"Executing command: {' '.join(cmd)}")
            result = subprocess.run(
                cmd, 
                capture_output=True, 
                text=True, 
                timeout=30,
                check=True
            )
            output = result.stdout.strip()
            
            # Track successful API call
            execution_time = time.time() - start_time
            api_response_time.labels(operation=operation).set(execution_time)
            api_calls_total.labels(operation=operation, status='success').inc()
            
            # Update performance history (keep last 50 measurements for memory efficiency)
            if operation in self.api_performance_history:
                self.api_performance_history[operation].append(execution_time)
                if len(self.api_performance_history[operation]) > 50:
                    self.api_performance_history[operation].pop(0)
            
            logger.debug(f"Command succeeded in {execution_time:.2f}s, output length: {len(output)} characters")
            return output
            
        except subprocess.CalledProcessError as e:
            execution_time = time.time() - start_time
            api_calls_total.labels(operation=operation, status='error').inc()
            logger.error(f"OpenShift command failed: {' '.join(cmd)}")
            logger.error(f"Return code: {e.returncode}, execution time: {execution_time:.2f}s")
            logger.error(f"Stderr: {e.stderr}")
            if e.stdout:
                logger.debug(f"Stdout: {e.stdout}")
            return None
        except subprocess.TimeoutExpired:
            api_calls_total.labels(operation=operation, status='timeout').inc()
            logger.error(f"OpenShift command timed out after 30s: {' '.join(cmd)}")
            return None
        except Exception as e:
            api_calls_total.labels(operation=operation, status='exception').inc()
            logger.error(f"Unexpected error running command {' '.join(cmd)}: {e}")
            return None
    
    def get_cached_data(self, data_type: str):
        """Get cached data if still valid"""
        current_time = time.time()
        if current_time - self.last_cache_time < self.cache_ttl:
            return self.data_cache.get(data_type)
        return None
    
    def set_cached_data(self, data_type: str, data):
        """Cache data with timestamp"""
        self.data_cache[data_type] = data
        self.last_cache_time = time.time()
    
    def cleanup_old_data(self):
        """Clean up old historical data to prevent memory leaks"""
        current_time = time.time()
        
        # Keep only last hour of EIP changes
        self.eip_changes_history = [
            change for change in self.eip_changes_history 
            if current_time - change['timestamp'] < 3600
        ]
        
        # Keep only last hour of CPIC recoveries
        self.cpic_recoveries_history = [
            recovery for recovery in self.cpic_recoveries_history 
            if current_time - recovery['timestamp'] < 3600
        ]
        
        # Limit performance history to 50 items per operation
        for operation in self.api_performance_history:
            if len(self.api_performance_history[operation]) > 50:
                self.api_performance_history[operation] = \
                    self.api_performance_history[operation][-50:]
    
    def collect_all_data_optimized(self) -> tuple:
        """Optimized single-pass data collection - reduces API calls from 5+ to 2"""
        try:
            # Get EIP nodes (cached if recent)
            cached_nodes = self.get_cached_data('eip_nodes')
            if cached_nodes:
                self.eip_nodes = cached_nodes
                logger.debug("Using cached EIP nodes")
            else:
                if not self.get_eip_nodes():
                    return None, None, None
                self.set_cached_data('eip_nodes', self.eip_nodes)
            
            # Get all EIP and CPIC data in optimized calls
            eip_output = self.run_oc_command(['oc', 'get', 'eip', '-o', 'json'], operation='eip_get')
            if eip_output is None:
                return None, None, None
                
            cpic_output = self.run_oc_command(['oc', 'get', 'cloudprivateipconfig', '-o', 'json'], operation='cpic_get')
            if cpic_output is None:
                return None, None, None
            
            # Parse JSON once
            eip_data = json.loads(eip_output)
            cpic_data = json.loads(cpic_output)
            
            return eip_data, cpic_data, self.eip_nodes
            
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON output: {e}")
            return None, None, None
        except Exception as e:
            logger.error(f"Failed to collect optimized data: {e}")
            return None, None, None
    
    # OpenShift EIP metrics collection
    
    def get_eip_nodes(self) -> bool:
        """Get list of EIP-enabled nodes with comprehensive validation"""
        output = self.run_oc_command([
            'oc', 'get', 'nodes', 
            '-l', 'k8s.ovn.org/egress-assignable', 
            '-o', 'name'
        ], operation='nodes_get')
        
        if output is None:
            logger.error("Failed to get EIP-enabled nodes - command failed")
            return False
        
        if not output.strip():
            logger.warning("No EIP-enabled nodes found in cluster")
            self.eip_nodes = []
            return False
            
        self.eip_nodes = [node.replace('node/', '') for node in output.split('\n') if node.strip()]
        
        if len(self.eip_nodes) == 0:
            logger.warning("No valid EIP-enabled nodes found after parsing")
            return False
            
        logger.info(f"Found {len(self.eip_nodes)} EIP-enabled nodes: {self.eip_nodes}")
        
        # Update node availability metrics
        node_available.set(len(self.eip_nodes))
        
        return True
    
    def collect_global_metrics(self) -> bool:
        """Collect global EIP and CPIC metrics"""
        try:
            # Get EIP metrics
            eip_output = self.run_oc_command(['oc', 'get', 'eip', '-o', 'json'], operation='eip_get')
            if eip_output is None:
                logger.error("Failed to get EIP resources")
                return False
            
            if not eip_output.strip():
                logger.warning("Empty response when getting EIP resources")
                return False
                
            eip_data = json.loads(eip_output)
            
            if 'items' not in eip_data:
                logger.error("Invalid EIP data structure - missing 'items' field")
                return False
            
            # Count IP addresses, not resources
            configured_count = 0
            assigned_count = 0
            
            for item in eip_data['items']:
                # Count configured IPs from spec.egressIPs[]
                egress_ips = item.get('spec', {}).get('egressIPs', [])
                configured_count += len(egress_ips)
                
                # Count assigned IPs from status.items[] where node exists and is not nil
                status_items = item.get('status', {}).get('items', [])
                for status_item in status_items:
                    if status_item.get('node') is not None and status_item.get('node') != '':
                        assigned_count += 1
            
            unassigned_count = configured_count - assigned_count
            
            # Set basic EIP metrics
            eips_configured.set(configured_count)
            eips_assigned.set(assigned_count)
            eips_unassigned.set(unassigned_count)
            
            # Calculate utilization percentage
            if configured_count > 0:
                utilization = (assigned_count / configured_count) * 100
                eip_utilization_percent.set(utilization)
            else:
                eip_utilization_percent.set(0)
            
            # Track EIP changes for rate calculation
            current_time = time.time()
            if hasattr(self, 'previous_eip_assigned'):
                eip_change = abs(assigned_count - self.previous_eip_assigned)
                if eip_change > 0:
                    self.eip_changes_history.append({
                        'timestamp': current_time,
                        'change': eip_change
                    })
            
            self.previous_eip_assigned = assigned_count
            
            # Calculate assignment rate (changes per minute)
            hour_ago = current_time - 3600
            recent_changes = [change for change in self.eip_changes_history if change['timestamp'] > hour_ago]
            self.eip_changes_history = recent_changes  # Clean up old entries
            
            changes_last_hour = sum(change['change'] for change in recent_changes)
            eip_changes_last_hour.set(changes_last_hour)
            
            # Calculate rate per minute
            if len(recent_changes) > 0:
                time_span_minutes = (current_time - recent_changes[0]['timestamp']) / 60
                if time_span_minutes > 0:
                    rate_per_minute = changes_last_hour / time_span_minutes
                    eip_assignment_rate.set(rate_per_minute)
                else:
                    eip_assignment_rate.set(0)
            else:
                eip_assignment_rate.set(0)
            
            # Get CPIC metrics
            cpic_output = self.run_oc_command(['oc', 'get', 'cloudprivateipconfig', '-o', 'json'], operation='cpic_get')
            if cpic_output is None:
                logger.error("Failed to get CPIC resources")
                return False
            
            if not cpic_output.strip():
                logger.warning("Empty response when getting CPIC resources")
                return False
                
            cpic_data = json.loads(cpic_output)
            
            if 'items' not in cpic_data:
                logger.error("Invalid CPIC data structure - missing 'items' field")
                return False
            
            success_count = 0
            pending_count = 0
            error_count = 0
            recoveries_count = 0
            
            for item in cpic_data['items']:
                conditions = item.get('status', {}).get('conditions', [])
                resource_name = item.get('metadata', {}).get('name', 'unknown')
                
                # Get the latest condition (should be the last one in the list)
                if conditions:
                    latest_condition = conditions[-1]
                    reason = latest_condition.get('reason', '')
                    condition_time = latest_condition.get('lastTransitionTime', '')
                    
                    if reason == 'CloudResponseSuccess':
                        success_count += 1
                        # Check if this was a recovery from error
                        if len(conditions) > 1:
                            previous_condition = conditions[-2]
                            if previous_condition.get('reason') == 'CloudResponseError':
                                recoveries_count += 1
                                self.cpic_recoveries_history.append({
                                    'timestamp': current_time,
                                    'resource': resource_name
                                })
                    elif reason == 'CloudResponsePending':
                        pending_count += 1
                        # Track how long it's been pending
                        if condition_time:
                            try:
                                from datetime import datetime
                                transition_time = datetime.fromisoformat(condition_time.replace('Z', '+00:00'))
                                pending_duration = current_time - transition_time.timestamp()
                                cpic_pending_duration.labels(resource_name=resource_name).set(pending_duration)
                            except Exception as e:
                                logger.debug(f"Failed to parse condition time for {resource_name}: {e}")
                    elif reason == 'CloudResponseError':
                        error_count += 1
                        # Track how long it's been in error
                        if condition_time:
                            try:
                                from datetime import datetime
                                transition_time = datetime.fromisoformat(condition_time.replace('Z', '+00:00'))
                                error_duration = current_time - transition_time.timestamp()
                                cpic_error_duration.labels(resource_name=resource_name).set(error_duration)
                            except Exception as e:
                                logger.debug(f"Failed to parse condition time for {resource_name}: {e}")
            
            # Set CPIC metrics
            cpic_success.set(success_count)
            cpic_pending.set(pending_count)
            cpic_error.set(error_count)
            
            # Clean up old recovery history (keep last hour)
            hour_ago = current_time - 3600
            recent_recoveries = [r for r in self.cpic_recoveries_history if r['timestamp'] > hour_ago]
            self.cpic_recoveries_history = recent_recoveries
            cpic_recoveries_last_hour.set(len(recent_recoveries))
            
            logger.info(f"Global metrics - EIPs: {configured_count}C/{assigned_count}A/{unassigned_count}U, "
                       f"CPIC: {success_count}S/{pending_count}P/{error_count}E")
            
            return True
            
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON output: {e}")
            return False
        except Exception as e:
            logger.error(f"Failed to collect global metrics: {e}")
            return False
    
    def collect_node_metrics(self) -> bool:
        """Collect per-node metrics"""
        try:
            # Get CPIC data for node filtering
            cpic_output = self.run_oc_command(['oc', 'get', 'cloudprivateipconfig', '-o', 'json'])
            if cpic_output is None:
                return False
                
            cpic_data = json.loads(cpic_output)
            
            # Get EIP data for node filtering
            eip_output = self.run_oc_command(['oc', 'get', 'eip', '-o', 'json'])
            if eip_output is None:
                return False
                
            eip_data = json.loads(eip_output)
            
            # Process each node
            for node in self.eip_nodes:
                # Count CPIC statuses for this node
                node_cpic_success_count = 0
                node_cpic_pending_count = 0
                node_cpic_error_count = 0
                
                for item in cpic_data['items']:
                    if item.get('spec', {}).get('node') == node:
                        conditions = item.get('status', {}).get('conditions', [])
                        # Get the latest condition (should be the last one in the list)
                        if conditions:
                            latest_condition = conditions[-1]
                            reason = latest_condition.get('reason', '')
                            if reason == 'CloudResponseSuccess':
                                node_cpic_success_count += 1
                            elif reason == 'CloudResponsePending':
                                node_cpic_pending_count += 1
                            elif reason == 'CloudResponseError':
                                node_cpic_error_count += 1
                
                # Count EIPs assigned to this node
                node_eip_count = 0
                for item in eip_data['items']:
                    status_items = item.get('status', {}).get('items', [])
                    node_eip_count += sum(1 for status_item in status_items 
                                        if status_item.get('node') == node)
                
                # Set OpenShift metrics
                node_cpic_success.labels(node=node).set(node_cpic_success_count)
                node_cpic_pending.labels(node=node).set(node_cpic_pending_count)
                node_cpic_error.labels(node=node).set(node_cpic_error_count)
                node_eip_assigned.labels(node=node).set(node_eip_count)
                
                logger.debug(f"Node {node} - CPIC: {node_cpic_success_count}S/"
                           f"{node_cpic_pending_count}P/{node_cpic_error_count}E, "
                           f"EIP: {node_eip_count}")
            
            return True
            
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON output: {e}")
            return False
        except Exception as e:
            logger.error(f"Failed to collect node metrics: {e}")
            return False
    
    def calculate_distribution_metrics(self, node_eip_counts: dict):
        """Calculate EIP distribution fairness metrics"""
        if not node_eip_counts:
            return
            
        counts = list(node_eip_counts.values())
        n = len(counts)
        
        if n == 0:
            return
            
        # Basic distribution stats
        max_eips = max(counts)
        min_eips = min(counts)
        mean_eips = sum(counts) / n
        
        eip_max_per_node.set(max_eips)
        eip_min_per_node.set(min_eips)
        
        # Standard deviation
        if n > 1:
            variance = sum((x - mean_eips) ** 2 for x in counts) / (n - 1)
            std_dev = variance ** 0.5
            eip_distribution_stddev.set(std_dev)
        else:
            eip_distribution_stddev.set(0)
        
        # Gini coefficient for inequality measurement
        if sum(counts) > 0:
            sorted_counts = sorted(counts)
            cumulative_sum = 0
            gini_sum = 0
            
            for i, count in enumerate(sorted_counts):
                cumulative_sum += count
                gini_sum += (2 * (i + 1) - n - 1) * count
            
            total_sum = sum(counts)
            if total_sum > 0:
                gini = gini_sum / (n * total_sum)
                eip_distribution_gini.set(abs(gini))  # Ensure positive value
            else:
                eip_distribution_gini.set(0)
        else:
            eip_distribution_gini.set(0)
    
    def calculate_health_scores(self, total_eips: int, assigned_eips: int, 
                               cpic_success: int, cpic_error: int, cpic_pending: int):
        """Calculate overall cluster health scores"""
        
        # EIP Health Score (0-100)
        eip_score = 0
        if total_eips > 0:
            # Base score from assignment ratio
            assignment_ratio = assigned_eips / total_eips
            eip_score += assignment_ratio * 50  # Max 50 points for assignments
            
            # Penalty for unassigned EIPs
            unassigned_penalty = ((total_eips - assigned_eips) / total_eips) * 20
            eip_score -= unassigned_penalty
            
            # Bonus for high utilization
            if assignment_ratio > 0.8:
                eip_score += 20
            elif assignment_ratio > 0.6:
                eip_score += 10
            
            # Distribution fairness bonus
            if hasattr(self, 'last_gini_coefficient'):
                if self.last_gini_coefficient < 0.1:  # Very fair distribution
                    eip_score += 15
                elif self.last_gini_coefficient < 0.3:  # Reasonably fair
                    eip_score += 10
            
            eip_score = max(0, min(100, eip_score))  # Clamp to 0-100
        
        cluster_eip_health_score.set(eip_score)
        
        # Stability Score (based on change frequency)
        stability_score = 100
        if hasattr(self, 'eip_changes_history') and len(self.eip_changes_history) > 0:
            recent_changes = len(self.eip_changes_history)
            # Penalize frequent changes
            change_penalty = min(50, recent_changes * 2)
            stability_score -= change_penalty
        
        cluster_eip_stability_score.set(max(0, stability_score))
    
    def calculate_api_success_rates(self):
        """Calculate API call success rates"""
        try:
            # Get total counts for each operation from prometheus counter
            for operation in ['eip_get', 'cpic_get', 'nodes_get']:
                try:
                    # This is a simplified calculation - in production you'd want to track this more precisely
                    success_metric = api_calls_total.labels(operation=operation, status='success')
                    error_metric = api_calls_total.labels(operation=operation, status='error')
                    
                    # Calculate success rate percentage
                    total_calls = success_metric._value._value + error_metric._value._value
                    if total_calls > 0:
                        success_rate = (success_metric._value._value / total_calls) * 100
                        api_call_success_rate.labels(operation=operation).set(success_rate)
                    else:
                        api_call_success_rate.labels(operation=operation).set(100)  # No calls yet
                        
                except Exception as e:
                    logger.debug(f"Error calculating success rate for {operation}: {e}")
                    api_call_success_rate.labels(operation=operation).set(100)  # Default to 100%
                    
        except Exception as e:
            logger.error(f"Error calculating API success rates: {e}")
    
    def update_node_capacity_metrics(self, node_eip_counts: dict):
        """Update per-node capacity and utilization metrics"""
        for node in self.eip_nodes:
            current_eips = node_eip_counts.get(node, 0)
            
            # Estimate capacity (configurable via environment variable)
            # This is tricky to determine for ARO cluster as their is an undocumented limit on the number of EIPs per node.
            # The limit is dependent on security rules and is triggered because the eip is added to the loadbalancers backend pool.
            # There is a fix being worked on to remove this limitation, but for now we use a configurable default.
            # Set EIP_CAPACITY_PER_NODE environment variable to override the default (default: 75)
            try:
                estimated_capacity = int(os.getenv('EIP_CAPACITY_PER_NODE', '75'))
                if estimated_capacity <= 0:
                    logger.warning(f"Invalid EIP_CAPACITY_PER_NODE value: {estimated_capacity}, using default 75")
                    estimated_capacity = 75
            except (ValueError, TypeError) as e:
                logger.warning(f"Invalid EIP_CAPACITY_PER_NODE value, using default 75: {e}")
                estimated_capacity = 75
            node_eip_capacity.labels(node=node).set(estimated_capacity)
            
            # Calculate utilization percentage
            if estimated_capacity > 0:
                utilization_pct = (current_eips / estimated_capacity) * 100
                node_eip_utilization.labels(node=node).set(min(100, utilization_pct))
            else:
                node_eip_utilization.labels(node=node).set(0)
    
    def update_error_node_count(self, cpic_data: dict):
        """Count nodes with CPIC errors"""
        nodes_with_errors = set()
        
        for item in cpic_data.get('items', []):
            conditions = item.get('status', {}).get('conditions', [])
            if conditions:
                latest_condition = conditions[-1]
                if latest_condition.get('reason') == 'CloudResponseError':
                    node_name = item.get('spec', {}).get('node', '')
                    if node_name:
                        nodes_with_errors.add(node_name)
        
        node_with_errors.set(len(nodes_with_errors))
    
    def detect_mismatches(self, eip_data: dict, cpic_data: dict, available_nodes: int) -> dict:
        """
        Detect mismatches between EIP and CPIC assignments.
        Returns dict with mismatch counts and details.
        """
        mismatches = {
            'total': 0,
            'node_mismatch': 0,
            'missing_in_eip': 0,
            'missing_in_cpic': 0,
            'mismatch_by_resource': {},  # resource_name -> set of IPs with mismatches
            'mismatch_by_ip': {}  # ip -> mismatch_type
        }
        
        # Build CPIC IP -> node mapping (priority: status.node > spec.node)
        cpic_ip_to_node = {}
        for item in cpic_data.get('items', []):
            ip = item.get('metadata', {}).get('name', '')
            if ip:
                # Prefer status.node over spec.node
                node = item.get('status', {}).get('node') or item.get('spec', {}).get('node', '')
                if node:
                    cpic_ip_to_node[ip] = node
        
        # Build EIP IP -> node mapping from status.items
        eip_ip_to_node = {}
        eip_ip_to_resource = {}
        resource_assigned_counts = {}  # Track assigned IP count per resource
        
        for item in eip_data.get('items', []):
            resource_name = f"{item.get('metadata', {}).get('namespace', '')}/{item.get('metadata', {}).get('name', '')}"
            status_items = item.get('status', {}).get('items', [])
            assigned_count = 0
            
            for status_item in status_items:
                ip = status_item.get('egressIP') or status_item.get('ip', '')
                node = status_item.get('node', '')
                if ip and node:
                    eip_ip_to_node[ip] = node
                    eip_ip_to_resource[ip] = resource_name
                    assigned_count += 1
            
            resource_assigned_counts[resource_name] = assigned_count
        
        # Build IP -> resource mapping from spec.egressIPs (for finding resource when IP is missing from status.items)
        ip_to_resource_from_spec = {}
        for item in eip_data.get('items', []):
            resource_name = f"{item.get('metadata', {}).get('namespace', '')}/{item.get('metadata', {}).get('name', '')}"
            egress_ips = item.get('spec', {}).get('egressIPs', [])
            for ip in egress_ips:
                ip_to_resource_from_spec[ip] = resource_name
        
        # Detect mismatches
        for ip, cpic_node in cpic_ip_to_node.items():
            eip_node = eip_ip_to_node.get(ip)
            resource_name = eip_ip_to_resource.get(ip)
            
            # If not found in status.items, try to find resource from spec.egressIPs
            if not resource_name:
                resource_name = ip_to_resource_from_spec.get(ip, 'unknown')
            
            if eip_node:
                if eip_node != cpic_node:
                    # Node mismatch
                    mismatches['total'] += 1
                    mismatches['node_mismatch'] += 1
                    mismatches['mismatch_by_ip'][ip] = 'node_mismatch'
                    if resource_name not in mismatches['mismatch_by_resource']:
                        mismatches['mismatch_by_resource'][resource_name] = set()
                    mismatches['mismatch_by_resource'][resource_name].add(ip)
            else:
                # IP in CPIC but not in EIP status.items
                # Check if resource is at capacity
                if resource_name != 'unknown':
                    assigned_count = resource_assigned_counts.get(resource_name, 0)
                    if assigned_count < available_nodes:
                        # Not at capacity, so this is a mismatch
                        mismatches['total'] += 1
                        mismatches['missing_in_eip'] += 1
                        mismatches['mismatch_by_ip'][ip] = 'missing_in_eip'
                        if resource_name not in mismatches['mismatch_by_resource']:
                            mismatches['mismatch_by_resource'][resource_name] = set()
                        mismatches['mismatch_by_resource'][resource_name].add(ip)
        
        # Check for IPs in EIP but not in CPIC
        for ip, eip_node in eip_ip_to_node.items():
            if ip not in cpic_ip_to_node:
                mismatches['total'] += 1
                mismatches['missing_in_cpic'] += 1
                mismatches['mismatch_by_ip'][ip] = 'missing_in_cpic'
                resource_name = eip_ip_to_resource.get(ip, 'unknown')
                if resource_name not in mismatches['mismatch_by_resource']:
                    mismatches['mismatch_by_resource'][resource_name] = set()
                mismatches['mismatch_by_resource'][resource_name].add(ip)
        
        return mismatches
    
    def calculate_overcommitted(self, eip_data: dict, available_nodes: int) -> int:
        """Calculate total overcommitted IPs across all EIP resources"""
        overcommitted_ips = 0
        
        for item in eip_data.get('items', []):
            egress_ips = item.get('spec', {}).get('egressIPs', [])
            configured_count = len(egress_ips)
            
            if configured_count > available_nodes:
                overcommitted_ips += (configured_count - available_nodes)
        
        return overcommitted_ips
    
    def detect_critical_eips(self, eip_data: dict, mismatches: dict) -> int:
        """
        Count EIP resources with no working assignments.
        A resource is critical if:
        1. status.items is empty or has no items with node assignments
        2. All IPs in status.items have mismatches
        """
        critical_count = 0
        
        for item in eip_data.get('items', []):
            resource_name = f"{item.get('metadata', {}).get('namespace', '')}/{item.get('metadata', {}).get('name', '')}"
            status_items = item.get('status', {}).get('items', [])
            
            if not status_items:
                # No assignments at all
                critical_count += 1
                continue
            
            # Check if all assigned IPs have mismatches
            all_have_mismatches = True
            has_any_assignment = False
            
            for status_item in status_items:
                node = status_item.get('node', '')
                ip = status_item.get('egressIP') or status_item.get('ip', '')
                
                if node:  # Has a node assignment
                    has_any_assignment = True
                    # Check if this IP has a mismatch
                    if ip not in mismatches.get('mismatch_by_ip', {}):
                        all_have_mismatches = False
                        break
            
            if has_any_assignment and all_have_mismatches:
                critical_count += 1
            elif not has_any_assignment:
                # No assignments with nodes
                critical_count += 1
        
        return critical_count
    
    def calculate_primary_secondary_eips(self, eip_data: dict, eip_nodes: list) -> tuple:
        """
        Calculate primary and secondary EIPs per node.
        Returns: (primary_by_node, secondary_by_node)
        """
        primary_by_node = {node: 0 for node in eip_nodes}
        secondary_by_node = {node: 0 for node in eip_nodes}
        
        for item in eip_data.get('items', []):
            status_items = item.get('status', {}).get('items', [])
            
            if not status_items:
                continue
            
            # Primary EIP is the first item (status.items[0])
            first_item = status_items[0]
            primary_node = first_item.get('node', '')
            if primary_node and primary_node in primary_by_node:
                primary_by_node[primary_node] += 1
            
            # Secondary EIPs are all remaining items (status.items[1..n])
            for status_item in status_items[1:]:
                node = status_item.get('node', '')
                if node and node in secondary_by_node:
                    secondary_by_node[node] += 1
        
        return primary_by_node, secondary_by_node
    
    def process_all_metrics_optimized(self, eip_data: dict, cpic_data: dict, eip_nodes: list):
        """Single-pass optimized processing of all metrics"""
        try:
            # Global EIP metrics - count IP addresses, not resources
            configured_count = 0
            assigned_count = 0
            
            for item in eip_data.get('items', []):
                # Count configured IPs from spec.egressIPs[]
                egress_ips = item.get('spec', {}).get('egressIPs', [])
                configured_count += len(egress_ips)
                
                # Count assigned IPs from status.items[] where node exists and is not nil
                status_items = item.get('status', {}).get('items', [])
                for status_item in status_items:
                    if status_item.get('node') is not None and status_item.get('node') != '':
                        assigned_count += 1
            
            unassigned_count = configured_count - assigned_count
            
            # Set basic EIP metrics
            eips_configured.set(configured_count)
            eips_assigned.set(assigned_count)
            eips_unassigned.set(unassigned_count)
            
            # Calculate utilization percentage
            if configured_count > 0:
                utilization = (assigned_count / configured_count) * 100
                eip_utilization_percent.set(utilization)
            else:
                eip_utilization_percent.set(0)
            
            # Process CPIC data in single pass
            success_count = 0
            pending_count = 0
            error_count = 0
            recoveries_count = 0
            current_time = time.time()
            
            # Node statistics for distribution analysis
            node_eip_counts = {}
            node_cpic_stats = {}
            
            # Initialize node stats
            for node in eip_nodes:
                node_eip_counts[node] = 0
                node_cpic_stats[node] = {'success': 0, 'pending': 0, 'error': 0}
            
            # Process CPIC items
            for item in cpic_data.get('items', []):
                conditions = item.get('status', {}).get('conditions', [])
                resource_name = item.get('metadata', {}).get('name', 'unknown')
                node_name = item.get('spec', {}).get('node', '')
                
                if conditions:
                    latest_condition = conditions[-1]
                    reason = latest_condition.get('reason', '')
                    condition_time = latest_condition.get('lastTransitionTime', '')
                    
                    if reason == 'CloudResponseSuccess':
                        success_count += 1
                        if node_name in node_cpic_stats:
                            node_cpic_stats[node_name]['success'] += 1
                        
                        # Check for recovery
                        if len(conditions) > 1:
                            previous_condition = conditions[-2]
                            if previous_condition.get('reason') == 'CloudResponseError':
                                recoveries_count += 1
                                self.cpic_recoveries_history.append({
                                    'timestamp': current_time,
                                    'resource': resource_name
                                })
                    elif reason == 'CloudResponsePending':
                        pending_count += 1
                        if node_name in node_cpic_stats:
                            node_cpic_stats[node_name]['pending'] += 1
                        
                        # Track pending duration
                        if condition_time:
                            try:
                                from datetime import datetime
                                transition_time = datetime.fromisoformat(condition_time.replace('Z', '+00:00'))
                                pending_duration = current_time - transition_time.timestamp()
                                cpic_pending_duration.labels(resource_name=resource_name).set(pending_duration)
                            except Exception as e:
                                logger.debug(f"Failed to parse condition time for {resource_name}: {e}")
                    elif reason == 'CloudResponseError':
                        error_count += 1
                        if node_name in node_cpic_stats:
                            node_cpic_stats[node_name]['error'] += 1
                        
                        # Track error duration
                        if condition_time:
                            try:
                                from datetime import datetime
                                transition_time = datetime.fromisoformat(condition_time.replace('Z', '+00:00'))
                                error_duration = current_time - transition_time.timestamp()
                                cpic_error_duration.labels(resource_name=resource_name).set(error_duration)
                            except Exception as e:
                                logger.debug(f"Failed to parse condition time for {resource_name}: {e}")
            
            # Set CPIC metrics
            cpic_success.set(success_count)
            cpic_pending.set(pending_count)
            cpic_error.set(error_count)
            
            # Process EIP data for node distribution
            for item in eip_data.get('items', []):
                status_items = item.get('status', {}).get('items', [])
                for status_item in status_items:
                    node = status_item.get('node')
                    if node in node_eip_counts:
                        node_eip_counts[node] += 1
            
            # Set per-node metrics
            for node in eip_nodes:
                node_eip_assigned.labels(node=node).set(node_eip_counts[node])
                node_cpic_success.labels(node=node).set(node_cpic_stats[node]['success'])
                node_cpic_pending.labels(node=node).set(node_cpic_stats[node]['pending'])
                node_cpic_error.labels(node=node).set(node_cpic_stats[node]['error'])
            
            # Calculate distribution metrics
            self.calculate_distribution_metrics(node_eip_counts)
            
            # Update node capacity metrics
            self.update_node_capacity_metrics(node_eip_counts)
            
            # Update error node count
            self.update_error_node_count(cpic_data)
            
            # Calculate mismatch detection, overcommitted, critical, and primary/secondary metrics
            available_nodes = len(eip_nodes)
            
            # Detect mismatches
            mismatches = self.detect_mismatches(eip_data, cpic_data, available_nodes)
            eip_cpic_mismatches_total.set(mismatches['total'])
            eip_cpic_mismatches_node_mismatch.set(mismatches['node_mismatch'])
            eip_cpic_mismatches_missing_in_eip.set(mismatches['missing_in_eip'])
            
            # Count malfunctioning EIP objects (unique resources with mismatches)
            malfunctioning_count = len(mismatches['mismatch_by_resource'])
            malfunctioning_eip_objects_count.set(malfunctioning_count)
            
            # Calculate overcommitted IPs
            overcommitted_ips = self.calculate_overcommitted(eip_data, available_nodes)
            overcommitted_eip_objects_count.set(overcommitted_ips)
            
            # Detect critical EIP resources
            critical_count = self.detect_critical_eips(eip_data, mismatches)
            critical_eip_objects_count.set(critical_count)
            
            # Calculate primary and secondary EIPs per node
            primary_by_node, secondary_by_node = self.calculate_primary_secondary_eips(eip_data, eip_nodes)
            for node in eip_nodes:
                node_eip_primary.labels(node=node).set(primary_by_node[node])
                node_eip_secondary.labels(node=node).set(secondary_by_node[node])
            
            # Calculate health scores
            self.calculate_health_scores(configured_count, assigned_count, 
                                      success_count, error_count, pending_count)
            
            # Track EIP changes for rate calculation
            if hasattr(self, 'previous_eip_assigned'):
                eip_change = abs(assigned_count - self.previous_eip_assigned)
                if eip_change > 0:
                    self.eip_changes_history.append({
                        'timestamp': current_time,
                        'change': eip_change
                    })
            
            self.previous_eip_assigned = assigned_count
            
            # Calculate assignment rate (changes per minute)
            hour_ago = current_time - 3600
            recent_changes = [change for change in self.eip_changes_history if change['timestamp'] > hour_ago]
            self.eip_changes_history = recent_changes  # Clean up old entries
            
            changes_last_hour = sum(change['change'] for change in recent_changes)
            eip_changes_last_hour.set(changes_last_hour)
            
            # Calculate rate per minute
            if len(recent_changes) > 0:
                time_span_minutes = (current_time - recent_changes[0]['timestamp']) / 60
                if time_span_minutes > 0:
                    rate_per_minute = changes_last_hour / time_span_minutes
                    eip_assignment_rate.set(rate_per_minute)
                else:
                    eip_assignment_rate.set(0)
            else:
                eip_assignment_rate.set(0)
            
            # Clean up old recovery history
            recent_recoveries = [r for r in self.cpic_recoveries_history if r['timestamp'] > hour_ago]
            self.cpic_recoveries_history = recent_recoveries
            cpic_recoveries_last_hour.set(len(recent_recoveries))
            
            # Update node availability metrics
            node_available.set(len(eip_nodes))
            
            logger.info(f"Optimized processing - EIPs: {configured_count}C/{assigned_count}A/{unassigned_count}U, "
                       f"CPIC: {success_count}S/{pending_count}P/{error_count}E")
            
        except Exception as e:
            logger.error(f"Failed to process metrics in optimized mode: {e}")
            raise
    
    # OpenShift node metrics collection and processing
    
    def collect_metrics(self):
        """Optimized metrics collection function - reduced from 5+ to 2 API calls"""
        start_time = time.time()
        try:
            logger.info("Starting optimized metrics collection")
            
            # Clean up old data to prevent memory leaks
            self.cleanup_old_data()
            
            # Get all data in optimized single pass (2 API calls instead of 5+)
            eip_data, cpic_data, eip_nodes = self.collect_all_data_optimized()
            if not all([eip_data, cpic_data, eip_nodes]):
                logger.error("Failed to collect optimized data")
                scrape_errors.inc()
                return False
            
            # Process all metrics in single pass
            self.process_all_metrics_optimized(eip_data, cpic_data, eip_nodes)
            
            # Calculate API success rates
            self.calculate_api_success_rates()
            
            # Update monitoring info
            scrape_duration = time.time() - start_time
            monitoring_info.info({
                'version': '1.0.0',
                'nodes': ','.join(self.eip_nodes),
                'node_count': str(len(self.eip_nodes)),
                'metrics_count': '50+',
                'last_update': datetime.now().isoformat(),
                'scrape_duration': f"{scrape_duration:.2f}s",
                'optimization': 'enabled'
            })
            
            # Record metrics
            scrape_duration_seconds.set(scrape_duration)
            last_scrape_timestamp.set(time.time())
            self.last_update = datetime.now()
            
            logger.info(f"Optimized metrics collection completed in {scrape_duration:.2f}s")
            logger.info(f"Collected metrics for {len(self.eip_nodes)} nodes")
            
            return True
            
        except Exception as e:
            scrape_duration = time.time() - start_time
            scrape_duration_seconds.set(scrape_duration)
            logger.error(f"Optimized metrics collection failed after {scrape_duration:.2f}s: {e}")
            scrape_errors.inc()
            return False

# Global collector instance
collector = EIPMetricsCollector()

def metrics_worker():
    """Background worker for collecting metrics"""
    logger.info(f"Starting metrics worker with {collector.scrape_interval}s interval")
    
    while True:
        try:
            collector.collect_metrics()
            time.sleep(collector.scrape_interval)
        except Exception as e:
            logger.error(f"Metrics worker error: {e}")
            scrape_errors.inc()
            time.sleep(collector.scrape_interval)

@app.route('/metrics')
def metrics():
    """Prometheus metrics endpoint"""
    return Response(generate_latest(), mimetype='text/plain')

@app.route('/health')
def health():
    """Health check endpoint"""
    if collector.last_update and (datetime.now() - collector.last_update).total_seconds() < 300:
        return {'status': 'healthy', 'last_update': collector.last_update.isoformat()}, 200
    else:
        return {'status': 'unhealthy', 'message': 'Metrics not updated recently'}, 503

@app.route('/')
def root():
    """Root endpoint with basic info"""
    return {
        'service': 'EIP Metrics Server',
        'version': '1.0.0',
        'endpoints': {
            'metrics': '/metrics',
            'health': '/health'
        },
        'last_update': collector.last_update.isoformat() if collector.last_update else None
    }

def main():
    """Main function"""
    logger.info("Starting EIP Metrics Server")
    
    # Initialize metrics with default values to ensure they're always present
    # This ensures metrics are available immediately, even before first collection
    eips_configured.set(0)
    eips_assigned.set(0)
    eips_unassigned.set(0)
    eip_utilization_percent.set(0)
    cpic_success.set(0)
    cpic_pending.set(0)
    cpic_error.set(0)
    node_available.set(0)
    node_with_errors.set(0)
    # Counters start at 0 by default, no need to initialize
    last_scrape_timestamp.set(0)
    scrape_duration_seconds.set(0)
    
    # Set initial monitoring info
    monitoring_info.info({
        'version': '1.0.0',
        'status': 'initializing',
        'node_count': '0'
    })
    
    logger.info("Metrics initialized with default values")
    
    # Start metrics collection in background
    metrics_thread = threading.Thread(target=metrics_worker, daemon=True)
    metrics_thread.start()
    
    # Trigger immediate metrics collection (non-blocking)
    # This ensures metrics are available as soon as possible
    def initial_collection():
        time.sleep(2)  # Give the server a moment to start
        logger.info("Performing initial metrics collection...")
        try:
            collector.collect_metrics()
            logger.info("Initial metrics collection completed")
        except Exception as e:
            logger.warning(f"Initial metrics collection failed (will retry): {e}")
    
    initial_thread = threading.Thread(target=initial_collection, daemon=True)
    initial_thread.start()
    
    # Start Flask server
    port = int(os.getenv('PORT', '8080'))
    app.run(host='0.0.0.0', port=port, debug=False)

if __name__ == '__main__':
    main()
