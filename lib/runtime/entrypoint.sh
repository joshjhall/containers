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
# Re-entry Guard
# ============================================================================
# Prevent the entrypoint from running twice when using su -l to drop privileges
# This can happen because su -l starts a login shell which may re-invoke entrypoint
if [ "${ENTRYPOINT_ALREADY_RAN:-}" = "true" ]; then
    # We're being called again after su -l, just exec the command
    exec "$@"
fi
export ENTRYPOINT_ALREADY_RAN=true

# ============================================================================
# Exit Handler - Graceful Shutdown
# ============================================================================
# Cleanup function called on container exit/termination
# Ensures proper cleanup of resources, metrics, and logs
cleanup_on_exit() {
    local exit_code=$?

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

# Check if we're running as root
if [ "$(id -u)" -eq 0 ]; then
    RUNNING_AS_ROOT=true
    # Detect the non-root user in the container
    # The container should have a user with UID 1000 created during build
    USERNAME=$(getent passwd 1000 | cut -d: -f1)
    if [ -z "$USERNAME" ]; then
        echo "Error: No user with UID 1000 found in container"
        exit 1
    fi
else
    RUNNING_AS_ROOT=false
    USERNAME=$(whoami)
fi

# ============================================================================
# Docker Socket Access Fix
# ============================================================================
# Automatically configure Docker socket access if the socket exists
# We create/use a 'docker' group, chown the socket to that group, and add the user
# This is more secure than chmod 666 as it limits access to group members only
#
# This works in two modes:
# 1. Running as root: directly modify socket permissions
# 2. Running as non-root with sudo: use sudo for privileged operations
if [ -S /var/run/docker.sock ]; then
    # Check if we can already access the socket
    if ! test -r /var/run/docker.sock -a -w /var/run/docker.sock 2>/dev/null; then
        echo "🔧 Configuring Docker socket access..."

        # Determine if we can perform privileged operations
        CAN_SUDO=false
        if [ "$RUNNING_AS_ROOT" = "true" ]; then
            CAN_SUDO=true
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            CAN_SUDO=true
        fi

        if [ "$CAN_SUDO" = "true" ]; then
            # Helper function to run commands with appropriate privileges
            run_privileged() {
                if [ "$RUNNING_AS_ROOT" = "true" ]; then
                    "$@"
                else
                    sudo "$@"
                fi
            }

            # Create docker group if it doesn't exist
            if ! getent group docker >/dev/null 2>&1; then
                run_privileged groupadd docker 2>/dev/null || {
                    echo "⚠️  Warning: Could not create docker group"
                }
            fi

            # Change socket ownership to root:docker with 660 permissions
            if ! run_privileged chown root:docker /var/run/docker.sock 2>/dev/null || \
               ! run_privileged chmod 660 /var/run/docker.sock 2>/dev/null; then
                echo "⚠️  Warning: Could not change Docker socket ownership/permissions"
            fi

            # Add user to docker group
            run_privileged usermod -aG docker "$USERNAME" 2>/dev/null || {
                echo "⚠️  Warning: Could not add $USERNAME to docker group"
            }

            echo "✓ Docker socket access configured (user added to docker group)"

            # If running as non-root, we need to re-exec with new group membership
            # The sg command runs a command with a supplementary group
            if [ "$RUNNING_AS_ROOT" = "false" ] && [ -n "$*" ]; then
                # Mark that we've already configured docker so we don't loop
                export DOCKER_SOCKET_CONFIGURED=true
            fi
        else
            echo "⚠️  Warning: Cannot configure Docker socket - no root access or sudo"
            echo "   Docker commands may fail. Run container as root or enable passwordless sudo."
        fi
    fi
fi

# ============================================================================
# Cache Directory Permissions Fix
# ============================================================================
# Fix ownership of /cache directories that may have been created as root
# during Docker build (e.g., npm global installs create cache files as root)
#
# This runs on every startup because:
# 1. Cache volumes may be shared across containers with different UIDs
# 2. New cache subdirectories may be created by root during image updates
# 3. It's idempotent and fast when permissions are already correct
if [ -d "/cache" ]; then
    # Check if we need to fix permissions (any root-owned files in /cache)
    if find /cache -user root -print -quit 2>/dev/null | grep -q .; then
        echo "🔧 Fixing /cache directory permissions..."

        # Determine if we can perform privileged operations
        CAN_FIX_CACHE=false
        if [ "$RUNNING_AS_ROOT" = "true" ]; then
            CAN_FIX_CACHE=true
        elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            CAN_FIX_CACHE=true
        fi

        if [ "$CAN_FIX_CACHE" = "true" ]; then
            # Helper function reused from Docker socket section
            cache_run_privileged() {
                if [ "$RUNNING_AS_ROOT" = "true" ]; then
                    "$@"
                else
                    sudo "$@"
                fi
            }

            # Fix ownership of all cache directories
            if cache_run_privileged chown -R "${USERNAME}:${USERNAME}" /cache 2>/dev/null; then
                echo "✓ Cache directory permissions fixed"
            else
                echo "⚠️  Warning: Could not fix all cache permissions"
                echo "   Some package manager operations may fail"
            fi
        else
            echo "⚠️  Warning: Cannot fix /cache permissions - no root access or sudo"
            echo "   Some package manager operations may fail (npm, pip, etc.)"
            echo "   To fix: run container as root or enable ENABLE_PASSWORDLESS_SUDO=true"
        fi
    fi
fi

# ============================================================================
# Cron Daemon Startup
# ============================================================================
# Start cron daemon if installed (requires root privileges)
# This runs before dropping to non-root user so no sudo is needed
if command -v cron &> /dev/null; then
    if ! pgrep -x "cron" > /dev/null 2>&1; then
        echo "🔧 Starting cron daemon..."
        if [ "$RUNNING_AS_ROOT" = "true" ]; then
            # Start cron directly as root
            if command -v service &> /dev/null; then
                service cron start > /dev/null 2>&1 || cron
            else
                cron
            fi
            if pgrep -x "cron" > /dev/null 2>&1; then
                echo "✓ Cron daemon started"
            else
                echo "⚠️  Warning: Cron daemon may not have started"
            fi
        else
            # Not running as root, cron startup will be attempted by startup script
            echo "   Cron startup deferred to startup scripts (not running as root)"
        fi
    fi
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
                    su "${USERNAME}" -c "bash $script" || {
                        echo "⚠️  WARNING: First-startup script failed: $(basename "$script") (continuing)"
                    }
                else
                    # Already running as non-root user, execute directly
                    bash "$script" || {
                        echo "⚠️  WARNING: First-startup script failed: $(basename "$script") (continuing)"
                    }
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
                    su "${USERNAME}" -c "bash $script" || {
                        echo "⚠️  WARNING: Startup script failed: $(basename "$script") (continuing)"
                    }
                else
                    # Already running as non-root user, execute directly
                    bash "$script" || {
                        echo "⚠️  WARNING: Startup script failed: $(basename "$script") (continuing)"
                    }
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
# Use a subdir under /tmp that we can control permissions for
METRICS_DIR="/tmp/container-metrics"
mkdir -p "$METRICS_DIR" 2>/dev/null || true
chmod 1777 "$METRICS_DIR" 2>/dev/null || true

# Write startup metrics (Prometheus format)
# Fail gracefully if we can't write metrics (non-critical)
{
    echo "# HELP container_startup_seconds Time taken for container initialization in seconds"
    echo "# TYPE container_startup_seconds gauge"
    echo "container_startup_seconds $STARTUP_DURATION"
} > "$METRICS_DIR/startup-metrics.txt" 2>/dev/null || true

echo "✓ Container initialized in ${STARTUP_DURATION}s"

# ============================================================================
# Main Process Execution
# ============================================================================
# Execute the main command
echo "=== Starting main process ==="

if [ "$RUNNING_AS_ROOT" = "true" ]; then
    # Drop privileges to non-root user for main process
    # Using 'su -l' ensures a fresh login that picks up updated group memberships
    # from /etc/group (including any groups added for Docker socket access)
    #
    # Build a properly quoted command string to handle arguments with spaces
    QUOTED_CMD=""
    for arg in "$@"; do
        # Escape single quotes in the argument and wrap in single quotes
        escaped_arg=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
        QUOTED_CMD="$QUOTED_CMD '${escaped_arg}'"
    done
    exec su -l "$USERNAME" -c "cd '$(pwd)' && exec $QUOTED_CMD"
elif [ "${DOCKER_SOCKET_CONFIGURED:-false}" = "true" ] && getent group docker >/dev/null 2>&1; then
    # We configured docker socket access but need new group membership
    # Use sg to run command with docker group, or newgrp if sg unavailable
    if command -v sg >/dev/null 2>&1; then
        exec sg docker -c "exec $*"
    else
        # Fallback: newgrp replaces shell, so we exec into a new shell with docker group
        exec newgrp docker <<< "exec $*"
    fi
else
    exec "$@"
fi
