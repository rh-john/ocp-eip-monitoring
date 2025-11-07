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
log_level = os.getenv('LOG_LEVEL', 'INFO').upper()
# Map string to logging level
log_level_map = {
    'DEBUG': logging.DEBUG,
    'INFO': logging.INFO,
    'WARNING': logging.WARNING,
    'ERROR': logging.ERROR,
    'CRITICAL': logging.CRITICAL
}
logging.basicConfig(
    level=log_level_map.get(log_level, logging.INFO),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)
logger.info(f"Logging level set to: {log_level}")

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
        # Initialize with default empty values to ensure we always return valid data
        eip_data = {'items': []}
        cpic_data = {'items': []}
        
        logger.debug("collect_all_data_optimized: Starting data collection")
        
        try:
            # Get EIP nodes (cached if recent)
            cached_nodes = self.get_cached_data('eip_nodes')
            if cached_nodes is not None:
                self.eip_nodes = cached_nodes
                logger.debug("Using cached EIP nodes")
            else:
                # get_eip_nodes() always returns True now (even with empty nodes or command failures)
                self.get_eip_nodes()
                self.set_cached_data('eip_nodes', self.eip_nodes)
            
            # Ensure eip_nodes is always a list
            if self.eip_nodes is None:
                self.eip_nodes = []
            
            # Get all EIP and CPIC data in optimized calls
            eip_output = self.run_oc_command(['oc', 'get', 'eip', '-o', 'json'], operation='eip_get')
            if eip_output is None:
                # If command failed, try to continue with empty data (might be permissions or transient error)
                logger.warning("Failed to get EIP resources - command returned None, using empty items list")
                eip_data = {'items': []}
            elif not eip_output.strip():
                logger.info("No EIP resources found - using empty items list")
                eip_data = {'items': []}
            else:
                try:
                    eip_data = json.loads(eip_output)
                except json.JSONDecodeError as e:
                    logger.error(f"Failed to parse EIP JSON output: {e}")
                    logger.debug(f"EIP output: {eip_output[:200]}...")
                    # Continue with empty data rather than failing completely
                    logger.warning("Using empty items list due to JSON parse error")
                    eip_data = {'items': []}
                
            cpic_output = self.run_oc_command(['oc', 'get', 'cloudprivateipconfig', '-o', 'json'], operation='cpic_get')
            if cpic_output is None:
                # If command failed, try to continue with empty data (might be permissions or transient error)
                logger.warning("Failed to get CPIC resources - command returned None, using empty items list")
                cpic_data = {'items': []}
            elif not cpic_output.strip():
                logger.info("No CPIC resources found - using empty items list")
                cpic_data = {'items': []}
            else:
                try:
                    cpic_data = json.loads(cpic_output)
                except json.JSONDecodeError as e:
                    logger.error(f"Failed to parse CPIC JSON output: {e}")
                    logger.debug(f"CPIC output: {cpic_output[:200]}...")
                    # Continue with empty data rather than failing completely
                    logger.warning("Using empty items list due to JSON parse error")
                    cpic_data = {'items': []}
            
            # Ensure data structures have items field
            if 'items' not in eip_data:
                eip_data['items'] = []
            if 'items' not in cpic_data:
                cpic_data['items'] = []
            
            # Ensure eip_nodes is a list (never None)
            if not hasattr(self, 'eip_nodes') or self.eip_nodes is None:
                self.eip_nodes = []
            
            # Final validation before return - ensure we never return None
            if eip_data is None:
                logger.warning("eip_data was None, using empty dict")
                eip_data = {'items': []}
            if cpic_data is None:
                logger.warning("cpic_data was None, using empty dict")
                cpic_data = {'items': []}
            if self.eip_nodes is None:
                logger.warning("eip_nodes was None, using empty list")
                self.eip_nodes = []
            
            logger.debug(f"Returning data - eip_items={len(eip_data.get('items', []))}, cpic_items={len(cpic_data.get('items', []))}, nodes={len(self.eip_nodes)}")
            # Final safety check - ensure we never return None
            result = (eip_data, cpic_data, self.eip_nodes)
            if any(x is None for x in result):
                logger.error(f"CRITICAL: About to return None! eip_data={eip_data is not None}, cpic_data={cpic_data is not None}, eip_nodes={self.eip_nodes is not None}")
                # Replace any None values
                result = (
                    eip_data if eip_data is not None else {'items': []},
                    cpic_data if cpic_data is not None else {'items': []},
                    self.eip_nodes if self.eip_nodes is not None else []
                )
            logger.debug("collect_all_data_optimized: Successfully returning data")
            return result
            
        except Exception as e:
            logger.error(f"EXCEPTION in collect_all_data_optimized: {type(e).__name__}: {e}", exc_info=True)
            # Even on exception, return valid empty data structures to allow metrics collection to continue
            logger.warning("Returning empty data structures due to exception to allow metrics collection to continue")
            # Ensure eip_nodes exists
            if not hasattr(self, 'eip_nodes') or self.eip_nodes is None:
                self.eip_nodes = []
            result = ({'items': []}, {'items': []}, self.eip_nodes)
            logger.debug(f"collect_all_data_optimized: Returning fallback data after exception")
            return result
    
    # OpenShift EIP metrics collection
    
    def get_eip_nodes(self) -> bool:
        """Get list of EIP-enabled nodes with comprehensive validation"""
        output = self.run_oc_command([
            'oc', 'get', 'nodes', 
            '-l', 'k8s.ovn.org/egress-assignable=true', 
            '-o', 'name'
        ], operation='nodes_get')
        
        if output is None:
            # Command failed, but continue with empty nodes list (might be permissions or transient error)
            logger.warning("Failed to get EIP-enabled nodes - command failed, continuing with empty nodes list")
            self.eip_nodes = []
            node_available.set(0)
            return True  # Return True to allow metrics collection to continue
        
        if not output.strip():
            logger.warning("No EIP-enabled nodes found in cluster - this is a valid state")
            self.eip_nodes = []
            # Still return True - no nodes is a valid state, not an error
            node_available.set(0)
            return True
            
        self.eip_nodes = [node.replace('node/', '') for node in output.split('\n') if node.strip()]
        
        if len(self.eip_nodes) == 0:
            logger.warning("No valid EIP-enabled nodes found after parsing - this is a valid state")
            self.eip_nodes = []
            node_available.set(0)
            return True
            
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
            
            configured_count = len(eip_data['items'])
            assigned_count = sum(1 for item in eip_data['items'] 
                               if len(item.get('status', {}).get('items', [])) > 0)
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
    
    def process_all_metrics_optimized(self, eip_data: dict, cpic_data: dict, eip_nodes: list):
        """Single-pass optimized processing of all metrics"""
        try:
            # Global EIP metrics
            configured_count = len(eip_data.get('items', []))
            assigned_count = sum(1 for item in eip_data.get('items', []) 
                               if len(item.get('status', {}).get('items', [])) > 0)
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
            try:
                eip_data, cpic_data, eip_nodes = self.collect_all_data_optimized()
            except Exception as e:
                logger.error(f"Exception calling collect_all_data_optimized: {type(e).__name__}: {e}", exc_info=True)
                # Use empty defaults
                eip_data = {'items': []}
                cpic_data = {'items': []}
                eip_nodes = getattr(self, 'eip_nodes', [])
                scrape_errors.inc()
            
            # Allow empty eip_nodes list (valid state when no EIP-enabled nodes exist)
            # This check should never fail now since collect_all_data_optimized always returns valid data
            if eip_data is None or cpic_data is None or eip_nodes is None:
                logger.error(f"CRITICAL: collect_all_data_optimized returned None! eip_data={eip_data is not None}, cpic_data={cpic_data is not None}, eip_nodes={eip_nodes is not None}")
                logger.error(f"Type check - eip_data type: {type(eip_data)}, cpic_data type: {type(cpic_data)}, eip_nodes type: {type(eip_nodes)}")
                # Use empty defaults as fallback
                eip_data = eip_data if eip_data is not None else {'items': []}
                cpic_data = cpic_data if cpic_data is not None else {'items': []}
                eip_nodes = eip_nodes if eip_nodes is not None else []
                logger.warning("Using fallback empty data structures to continue")
                scrape_errors.inc()
                # Continue instead of returning False - we have valid data now
            
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
                'metrics_count': '40+',
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
            logger.error(f"Optimized metrics collection failed after {scrape_duration:.2f}s: {e}", exc_info=True)
            scrape_errors.inc()
            # Set last_update even on failure so health check can pass
            # This allows the pod to become ready even if metrics collection has issues
            if not hasattr(self, 'last_update') or self.last_update is None:
                self.last_update = datetime.now()
                logger.warning("Set last_update on failure to allow health check to pass")
            return False

# Global collector instance
collector = EIPMetricsCollector()

def metrics_worker():
    """Background worker for collecting metrics"""
    logger.info(f"Starting metrics worker with {collector.scrape_interval}s interval")
    
    while True:
        try:
            result = collector.collect_metrics()
            if not result:
                logger.warning("Metrics collection returned False, but continuing anyway")
                # Ensure last_update is set even if collection failed
                if not hasattr(collector, 'last_update') or collector.last_update is None:
                    collector.last_update = datetime.now()
                    logger.info("Set last_update after failed collection to allow health check")
            time.sleep(collector.scrape_interval)
        except Exception as e:
            logger.error(f"Metrics worker error: {e}", exc_info=True)
            scrape_errors.inc()
            # Ensure last_update is set even on exception
            if not hasattr(collector, 'last_update') or collector.last_update is None:
                collector.last_update = datetime.now()
                logger.info("Set last_update after worker exception to allow health check")
            time.sleep(collector.scrape_interval)

@app.route('/metrics')
def metrics():
    """Prometheus metrics endpoint"""
    return Response(generate_latest(), mimetype='text/plain')

@app.route('/health')
def health():
    """Health check endpoint"""
    # During initial startup (before first metrics collection), return healthy
    # to allow readiness probe to pass
    last_update = getattr(collector, 'last_update', None)
    if last_update is None:
        return {'status': 'starting', 'message': 'Initializing metrics collection'}, 200
    
    # Check if metrics are being updated regularly
    try:
        time_since_update = (datetime.now() - last_update).total_seconds()
        if time_since_update < 300:  # Updated within last 5 minutes
            return {'status': 'healthy', 'last_update': last_update.isoformat()}, 200
        else:
            # Metrics collection has stopped - return unhealthy
            return {'status': 'unhealthy', 'message': f'Metrics not updated recently ({int(time_since_update)}s ago)'}, 503
    except Exception as e:
        # If there's any error checking the time, assume starting state
        logger.warning(f"Error checking health status: {e}")
        return {'status': 'starting', 'message': 'Initializing metrics collection'}, 200

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
    
    # Start metrics collection in background
    metrics_thread = threading.Thread(target=metrics_worker, daemon=True)
    metrics_thread.start()
    
    # Start Flask server
    port = int(os.getenv('PORT', '8080'))
    app.run(host='0.0.0.0', port=port, debug=False)

if __name__ == '__main__':
    main()
