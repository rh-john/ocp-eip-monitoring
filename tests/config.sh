#!/bin/bash
#
# Test configuration
# Loads environment variables from ~/aro-current-config.env for test environment access
#

set -euo pipefail

# Load test environment configuration (in-flight only, no persistence)
if [[ -f ~/aro-current-config.env ]]; then
    # Source the config file to load variables into shell environment
    # Note: Variables are only loaded at runtime, not stored or committed
    source ~/aro-current-config.env
    echo "Loaded test environment configuration from ~/aro-current-config.env"
else
    echo "Warning: ~/aro-current-config.env not found. Some tests may fail."
    echo "Create ~/aro-current-config.env with required variables:"
    echo "  - OpenShift cluster connection details"
    echo "  - Test namespace configuration"
    echo "  - Registry URLs (if needed)"
fi

# Test configuration defaults
TEST_NAMESPACE="${TEST_NAMESPACE:-eip-monitoring}"
TEST_TIMEOUT="${TEST_TIMEOUT:-300}"  # 5 minutes default timeout
TEST_SKIP_UWM="${TEST_SKIP_UWM:-false}"
TEST_SKIP_COO="${TEST_SKIP_COO:-false}"
TEST_SKIP_GRAFANA="${TEST_SKIP_GRAFANA:-false}"

# Validate required variables (if using ~/aro-current-config.env)
# These should be set in the config file if needed
# Example variables that might be needed:
# - OPENSHIFT_API_SERVER
# - OPENSHIFT_USERNAME
# - OPENSHIFT_PASSWORD or OPENSHIFT_TOKEN
# - REGISTRY_URL

echo "Test configuration:"
echo "  Namespace: $TEST_NAMESPACE"
echo "  Timeout: ${TEST_TIMEOUT}s"
echo "  Skip UWM: $TEST_SKIP_UWM"
echo "  Skip COO: $TEST_SKIP_COO"
echo "  Skip Grafana: $TEST_SKIP_GRAFANA"

