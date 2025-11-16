#!/bin/bash
# Container Startup Script - Load Secrets from Secret Management Providers
#
# This script is automatically executed during container startup (via entrypoint.sh)
# and loads secrets from configured secret management providers.
#
# Filename prefix "50-" ensures it runs after basic initialization (10-*, 20-*)
# but before application-specific startup scripts (60-*, 70-*, etc.)
#
# To disable secret loading at startup, set: SECRET_LOADER_ENABLED=false

set -euo pipefail

# Check if secret loader should run
if [ "${SECRET_LOADER_ENABLED:-true}" != "true" ]; then
    echo "[INFO] Secret loader disabled, skipping secret loading"
    exit 0
fi

# Source the universal secret loader
if [ -f "/opt/container-runtime/secrets/load-secrets.sh" ]; then
    # shellcheck source=/dev/null
    source "/opt/container-runtime/secrets/load-secrets.sh"

    # Load all configured secrets
    if load_all_secrets; then
        echo "[INFO] Secret loading completed successfully"
        exit 0
    else
        exit_code=$?
        echo "[ERROR] Secret loading failed with exit code: $exit_code"

        # Allow container to continue if FAIL_ON_ERROR is not set
        if [ "${SECRET_LOADER_FAIL_ON_ERROR:-false}" != "true" ]; then
            echo "[WARNING] Continuing container startup despite secret loading failure"
            exit 0
        fi

        exit "$exit_code"
    fi
else
    echo "[WARNING] Secret loader script not found at /opt/container-runtime/secrets/load-secrets.sh"
    echo "[WARNING] Secret loading skipped"
    exit 0
fi
