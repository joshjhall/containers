#!/bin/bash
# Exit handler for graceful container shutdown
#
# Provides cleanup on container exit/termination: audit logging of shutdown
# events, metrics flushing, and filesystem sync.
#
# Functions provided:
#   cleanup_on_exit  - Trap handler for graceful shutdown

# Prevent multiple sourcing
if [ -n "${_EXIT_HANDLERS_LOADED:-}" ]; then
    return 0
fi
_EXIT_HANDLERS_LOADED=1

# Cleanup function called on container exit/termination
# Ensures proper cleanup of resources, metrics, and logs
cleanup_on_exit() {
    local exit_code=$?

    # Log shutdown event if audit logging was initialized
    if declare -f audit_log >/dev/null 2>&1; then
        audit_log "system" "info" "Container shutting down" \
            "{\"stage\":\"shutdown\",\"exit_code\":$exit_code}" 2>/dev/null || true
    fi

    echo "=== Container shutting down (exit code: $exit_code) ==="

    # Flush metrics if they exist
    METRICS_DIR="/tmp/container-metrics"
    if [ -d "$METRICS_DIR" ]; then
        # Ensure all metrics are written to disk
        sync 2>/dev/null || true
        echo "✓ Metrics flushed"
    fi

    # Sync any pending filesystem writes
    sync 2>/dev/null || true

    echo "✓ Shutdown complete"

    # Preserve original exit code
    exit $exit_code
}

# Set up trap handlers for graceful shutdown
# EXIT: Normal script exit
# TERM: Termination signal (docker stop)
# INT: Interrupt signal (Ctrl+C)
trap cleanup_on_exit EXIT TERM INT
