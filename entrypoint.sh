#!/bin/bash
#
# Container entrypoint for EIP Monitoring
#

set -euo pipefail

# Default values
MODE="${1:-server}"
PORT="${PORT:-8080}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-30}"

# Logging function
log() {
    echo "[$(date -Iseconds)] $*" >&2
}

# OpenShift environment configuration
check_env_vars() {
    log "No additional environment variables required for OpenShift-only monitoring"
}

# Wait for cluster connectivity
wait_for_cluster() {
    local max_retries=30
    local retry_interval=5
    local retries=0
    
    log "Waiting for OpenShift cluster connectivity..."
    
    while [[ $retries -lt $max_retries ]]; do
        if oc whoami &>/dev/null; then
            log "Successfully connected to OpenShift cluster as: $(oc whoami)"
            return 0
        fi
        
        log "Waiting for cluster connectivity... (attempt $((retries + 1))/$max_retries)"
        sleep $retry_interval
        ((retries++))
    done
    
    log "ERROR: Failed to connect to OpenShift cluster after $max_retries attempts"
    log "Please ensure:"
    log "  1. The pod has a valid service account with appropriate permissions"
    log "  2. The cluster is accessible from the pod"
    log "  3. Network policies allow connectivity"
    exit 1
}

# OpenShift authentication validation
check_openshift_auth() {
    log "OpenShift authentication will be validated by service account"
}

# Run pre-flight checks
preflight_checks() {
    log "Running pre-flight checks..."
    
    check_env_vars
    wait_for_cluster
    check_openshift_auth
    
    log "Pre-flight checks completed successfully"
}

# Show usage information
show_usage() {
    cat << EOF
EIP Monitoring Container

Usage: $0 <mode> [options]

Modes:
  server      Run Prometheus metrics server (default)
  monitor     Run one-time monitoring and exit
  shell       Start interactive shell for debugging

Environment Variables (optional):
  PORT                Metrics server port (default: 8080)
  SCRAPE_INTERVAL     Metrics collection interval in seconds (default: 30)

Examples:
  # Run metrics server (default)
  docker run eip-monitor

  # Run one-time monitoring
  docker run eip-monitor monitor

  # Interactive shell for debugging
  docker run -it eip-monitor shell

EOF
}

# Run the Prometheus metrics server
run_server() {
    log "Starting EIP Prometheus metrics server"
    log "Server will be available on port $PORT"
    log "Metrics collection interval: ${SCRAPE_INTERVAL}s"
    
    preflight_checks
    
    export PORT
    export SCRAPE_INTERVAL
    
    log "Starting metrics server..."
    exec python3 /app/metrics_server.py
}

# Run one-time monitoring (using Python metrics collector)
run_monitor() {
    log "Running one-time EIP monitoring"
    
    preflight_checks
    
    log "Running metrics collection once..."
    export PORT
    export SCRAPE_INTERVAL=1  # Run once
    
    # Run Python collector once and exit
    python3 -c "
import sys
sys.path.append('/app')
from metrics_server import EIPMetricsCollector
import logging

logging.basicConfig(level=logging.INFO)
collector = EIPMetricsCollector()
if collector.collect_metrics():
    print('✅ Metrics collection completed successfully')
    sys.exit(0)
else:
    print('❌ Metrics collection failed')
    sys.exit(1)
"
}

# Start interactive shell
run_shell() {
    log "Starting interactive shell for debugging"
    log "Available commands:"
    log "  oc           - OpenShift CLI"
    log "  python3 /app/metrics_server.py - Metrics server"
    log "  curl         - HTTP client for testing endpoints"
    log "  jq           - JSON processor for API responses"
    
    exec /bin/bash
}

# Main function
main() {
    case "$MODE" in
        server|metrics)
            run_server
            ;;
        monitor|once)
            run_monitor
            ;;
        shell|bash|debug)
            run_shell
            ;;
        help|-h|--help)
            show_usage
            exit 0
            ;;
        *)
            log "ERROR: Unknown mode '$MODE'"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Handle signals gracefully
trap 'log "Received termination signal, shutting down..."; exit 0' TERM INT

# Run main function
main "$@"
