#!/bin/bash
# Container Entrypoint - Manages startup sequence and command execution
#
# FIXED VERSION: Uses non-login shells to avoid triggering shell initialization
# that might cause circular dependencies with language runtimes
#
# Description:
#   Universal entrypoint that handles container initialization, runs startup
#   scripts, and executes the main command. Ensures proper environment setup
#   for both first-time and subsequent container starts.
#
# Features:
#   - Graceful shutdown with cleanup handlers (EXIT, TERM, INT signals)
#   - Resource limits (file descriptors, processes, core dumps)
#   - First-time setup script execution (run once per container)
#   - Every-boot script execution (run on each start)
#   - Main command execution with proper user context
#   - Persistent first-run tracking
#
# Startup Script Organization:
#   - /etc/container/first-startup/ : Run once when container is first started
#   - /etc/container/startup/       : Run on every container start
#
# Note:
#   Scripts are executed in alphabetical order (use numeric prefixes like 10-, 20-)
#   All scripts run as the container user, not root.
#   The first-run marker persists across restarts but not image rebuilds.
#
set -euo pipefail

# ============================================================================
# Exit Handler - Graceful Shutdown
# ============================================================================
# Cleanup function called on container exit/termination
# Ensures proper cleanup of resources, metrics, and logs
cleanup_on_exit() {
    local exit_code=$?

    echo "=== Container shutting down (exit code: $exit_code) ==="

    # Flush metrics if they exist
    METRICS_DIR="/var/run/container-metrics"
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

# ============================================================================
# Startup Time Tracking
# ============================================================================
# Record startup time for observability metrics
STARTUP_BEGIN_TIME=$(date +%s)

# ============================================================================
# Resource Limits
# ============================================================================
# Set file descriptor limits to prevent resource exhaustion
# - Prevents accidental fork bombs and file descriptor leaks
# - Configurable via environment variables
# - Fails gracefully if ulimit command is not available or restricted

# File descriptors (open files)
FILE_DESCRIPTOR_LIMIT="${FILE_DESCRIPTOR_LIMIT:-4096}"
ulimit -n "$FILE_DESCRIPTOR_LIMIT" 2>/dev/null || {
    echo "⚠️  Warning: Could not set file descriptor limit to $FILE_DESCRIPTOR_LIMIT"
    echo "   Current limit: $(ulimit -n 2>/dev/null || echo 'unknown')"
}

# Max user processes (prevent fork bombs)
MAX_USER_PROCESSES="${MAX_USER_PROCESSES:-2048}"
ulimit -u "$MAX_USER_PROCESSES" 2>/dev/null || {
    echo "⚠️  Warning: Could not set max user processes limit to $MAX_USER_PROCESSES"
    echo "   Current limit: $(ulimit -u 2>/dev/null || echo 'unknown')"
}

# Core dump size (disabled by default for security)
CORE_DUMP_SIZE="${CORE_DUMP_SIZE:-0}"
ulimit -c "$CORE_DUMP_SIZE" 2>/dev/null || true

# ============================================================================
# Configuration Validation
# ============================================================================
# Validate configuration before starting (opt-in via VALIDATE_CONFIG=true)
if [ -f "/opt/container-runtime/validate-config.sh" ]; then
    # shellcheck source=/dev/null
    source "/opt/container-runtime/validate-config.sh"
    validate_configuration || {
        echo "Configuration validation failed. Container startup aborted."
        exit 1
    }
fi

# ============================================================================
# Case-Sensitivity Detection
# ============================================================================
# Detect case-insensitive filesystems and warn users (opt-out via SKIP_CASE_CHECK=true)
if [ "${SKIP_CASE_CHECK:-false}" != "true" ] && [ -f "/usr/local/bin/detect-case-sensitivity.sh" ]; then
    # Check if /workspace exists and is writable
    if [ -d "/workspace" ] && [ -w "/workspace" ]; then
        # Run detection in quiet mode, capture exit code
        if ! QUIET=true /usr/local/bin/detect-case-sensitivity.sh /workspace; then
            # Case-insensitive filesystem detected
            echo ""
            echo "======================================================================"
            echo "  ⚠ Case-Insensitive Filesystem Detected"
            echo "======================================================================"
            echo ""
            echo "The /workspace directory is mounted from a case-insensitive filesystem."
            echo "This can cause issues with:"
            echo "  - Git case-only renames (e.g., README.md → readme.md)"
            echo "  - Case-sensitive imports (Python, Go, etc.)"
            echo "  - Build tools expecting exact case matches"
            echo ""
            echo "Platform: Likely macOS or Windows host"
            echo "Container: Linux (expects case-sensitive filesystems)"
            echo ""
            echo "Recommendations:"
            echo "  1. Use case-sensitive APFS volume (macOS)"
            echo "  2. Use WSL2 filesystem (Windows)"
            echo "  3. Use Docker volumes instead of bind mounts"
            echo "  4. Follow strict naming conventions"
            echo ""
            echo "For detailed solutions, see:"
            echo "  docs/troubleshooting/case-sensitive-filesystems.md"
            echo ""
            echo "To disable this check, set: SKIP_CASE_CHECK=true"
            echo "======================================================================"
            echo ""
        fi
    fi
fi

# Detect the non-root user in the container
# Don't rely on environment variables which might come from the host
# The container should have a user with UID 1000 created during build
USERNAME=$(getent passwd 1000 | cut -d: -f1)
if [ -z "$USERNAME" ]; then
    echo "Error: No user with UID 1000 found in container"
    exit 1
fi

# Check if we're running as root
if [ "$(id -u)" -eq 0 ]; then
    RUNNING_AS_ROOT=true
else
    RUNNING_AS_ROOT=false
fi

# ============================================================================
# First-Time Setup
# ============================================================================
# Run first-time setup scripts if marker doesn't exist
FIRST_RUN_MARKER="/home/${USERNAME}/.container-initialized"
FIRST_STARTUP_DIR="/etc/container/first-startup"
if [ ! -f "$FIRST_RUN_MARKER" ]; then
    echo "=== Running first-time setup scripts ==="

    # Run all first-startup scripts
    for script in "${FIRST_STARTUP_DIR}"/*.sh; do
        # Skip if not a regular file or is a symlink
        if [ -f "$script" ] && [ ! -L "$script" ]; then
            # Strict path traversal validation:
            # 1. Resolve canonical path (resolves symlinks and ..)
            # 2. Verify resolved path is within expected directory
            # 3. Verify no .. components remain (paranoid check)
            # 4. Verify not the directory itself (must be file within)
            script_realpath=$(realpath "$script" 2>/dev/null || echo "")
            if [ -n "$script_realpath" ] && \
               [[ "$script_realpath" == "$FIRST_STARTUP_DIR"/* ]] && \
               [[ ! "$script_realpath" =~ \.\. ]] && \
               [ "$script_realpath" != "$FIRST_STARTUP_DIR" ]; then
                echo "Running first-startup script: $(basename "$script")"
                if [ "$RUNNING_AS_ROOT" = "true" ]; then
                    # Running as root, use su to switch to non-root user
                    su "${USERNAME}" -c "bash $script"
                else
                    # Already running as non-root user, execute directly
                    bash "$script"
                fi
            else
                echo "⚠️  WARNING: Skipping script outside expected directory: $script"
            fi
        fi
    done

    # Create marker file
    if [ "$RUNNING_AS_ROOT" = "true" ]; then
        su "${USERNAME}" -c "touch $FIRST_RUN_MARKER"
    else
        touch "$FIRST_RUN_MARKER"
    fi
fi

# ============================================================================
# Every-Boot Scripts
# ============================================================================
# Run startup scripts every time
STARTUP_DIR="/etc/container/startup"
if [ -d "$STARTUP_DIR" ]; then
    echo "=== Running startup scripts ==="
    for script in "${STARTUP_DIR}"/*.sh; do
        # Skip if not a regular file or is a symlink
        if [ -f "$script" ] && [ ! -L "$script" ]; then
            # Strict path traversal validation:
            # 1. Resolve canonical path (resolves symlinks and ..)
            # 2. Verify resolved path is within expected directory
            # 3. Verify no .. components remain (paranoid check)
            # 4. Verify not the directory itself (must be file within)
            script_realpath=$(realpath "$script" 2>/dev/null || echo "")
            if [ -n "$script_realpath" ] && \
               [[ "$script_realpath" == "$STARTUP_DIR"/* ]] && \
               [[ ! "$script_realpath" =~ \.\. ]] && \
               [ "$script_realpath" != "$STARTUP_DIR" ]; then
                echo "Running startup script: $(basename "$script")"
                if [ "$RUNNING_AS_ROOT" = "true" ]; then
                    # Running as root, use su to switch to non-root user
                    su "${USERNAME}" -c "bash $script"
                else
                    # Already running as non-root user, execute directly
                    bash "$script"
                fi
            else
                echo "⚠️  WARNING: Skipping script outside expected directory: $script"
            fi
        fi
    done
fi

# ============================================================================
# Startup Time Metrics
# ============================================================================
# Calculate and record startup duration for observability
STARTUP_END_TIME=$(date +%s)
STARTUP_DURATION=$((STARTUP_END_TIME - STARTUP_BEGIN_TIME))

# Create metrics directory if it doesn't exist
METRICS_DIR="/var/run/container-metrics"
mkdir -p "$METRICS_DIR"

# Write startup metrics (Prometheus format)
{
    echo "# HELP container_startup_seconds Time taken for container initialization in seconds"
    echo "# TYPE container_startup_seconds gauge"
    echo "container_startup_seconds $STARTUP_DURATION"
} > "$METRICS_DIR/startup-metrics.txt"

echo "✓ Container initialized in ${STARTUP_DURATION}s"

# ============================================================================
# Main Process Execution
# ============================================================================
# Execute the main command
echo "=== Starting main process ==="
exec "$@"