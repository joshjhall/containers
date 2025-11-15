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
# Main Process Execution
# ============================================================================
# Execute the main command
echo "=== Starting main process ==="
exec "$@"