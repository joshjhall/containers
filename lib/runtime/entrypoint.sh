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
# Bindfs Overlay for Host Bind Mount Permission Fixes
# ============================================================================
# When bindfs is installed and /dev/fuse is available, apply FUSE overlays
# on host bind mounts under /workspace to fix permission issues (e.g., macOS
# VirtioFS where APFS lacks full Linux permission semantics).
#
# Modes (BINDFS_ENABLED):
#   auto  - probe permissions on each mount, apply only if broken (default)
#   true  - always apply bindfs to all bind mounts under /workspace
#   false - disabled entirely
#
# BINDFS_SKIP_PATHS: comma-separated paths to exclude from overlay
#
# Requires: --cap-add SYS_ADMIN --device /dev/fuse at container runtime
if command -v bindfs >/dev/null 2>&1; then
    BINDFS_ENABLED="${BINDFS_ENABLED:-auto}"

    if [ "$BINDFS_ENABLED" != "false" ]; then
        # Check for /dev/fuse
        if [ -e /dev/fuse ]; then
            echo "🔧 Checking bind mounts for permission fixes (bindfs=$BINDFS_ENABLED)..."

            # Parse BINDFS_SKIP_PATHS into associative array for O(1) lookup
            declare -A BINDFS_SKIP_MAP=()
            if [ -n "${BINDFS_SKIP_PATHS:-}" ]; then
                IFS=',' read -ra _skip_arr <<< "$BINDFS_SKIP_PATHS"
                for _skip_path in "${_skip_arr[@]}"; do
                    # Trim whitespace
                    _skip_path="${_skip_path## }"
                    _skip_path="${_skip_path%% }"
                    [ -n "$_skip_path" ] && BINDFS_SKIP_MAP["$_skip_path"]=1
                done
                unset _skip_arr _skip_path
            fi

            # Determine if we can perform privileged operations
            BINDFS_CAN_SUDO=false
            if [ "$RUNNING_AS_ROOT" = "true" ]; then
                BINDFS_CAN_SUDO=true
            elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
                BINDFS_CAN_SUDO=true
            fi

            # Helper to run commands with appropriate privileges
            bindfs_run_privileged() {
                if [ "$RUNNING_AS_ROOT" = "true" ]; then
                    "$@"
                else
                    sudo "$@"
                fi
            }

            # Get the target user's UID/GID
            BINDFS_UID=$(id -u "$USERNAME")
            BINDFS_GID=$(id -g "$USERNAME")

            # Find all mount points under /workspace
            # Note: --submounts requires the path itself to be a mount point,
            # which may not be the case (e.g., /workspace/project is mounted
            # but /workspace is not). List all mounts and filter by prefix.
            BINDFS_APPLIED=0
            while IFS=' ' read -r mnt_target mnt_fstype; do
                # Skip empty lines
                [ -z "$mnt_target" ] && continue

                # Skip mounts that are already FUSE overlays
                if [[ "$mnt_fstype" == *fuse* ]]; then
                    continue
                fi

                # Skip paths in BINDFS_SKIP_PATHS
                if [ -n "${BINDFS_SKIP_MAP[$mnt_target]+_}" ]; then
                    echo "   Skipping $mnt_target (in BINDFS_SKIP_PATHS)"
                    continue
                fi

                # For auto mode: probe permissions before applying
                if [ "$BINDFS_ENABLED" = "auto" ]; then
                    _needs_fix=false

                    # Check 1: filesystem type indicates permission faking.
                    # Docker Desktop uses these filesystem types for host
                    # bind mounts — they lack full Linux permission semantics.
                    #   fakeowner - Docker Desktop FUSE layer that intercepts
                    #               stat/chmod (reports success but underlying
                    #               APFS ignores it)
                    #   virtiofs  - VirtioFS (Docker Desktop 4.x+)
                    #   grpcfuse  - gRPC-FUSE (older Docker Desktop)
                    #   osxfs     - legacy macOS filesystem sharing
                    case "$mnt_fstype" in
                        fakeowner|virtiofs|grpcfuse|osxfs)
                            _needs_fix=true
                            ;;
                    esac

                    # Check 2: direct permission probe (catches other broken
                    # mounts not covered by the filesystem type check above)
                    if [ "$_needs_fix" = "false" ]; then
                        _probe_file="$mnt_target/.bindfs-probe-$$"

                        if touch "$_probe_file" 2>/dev/null; then
                            chmod 755 "$_probe_file" 2>/dev/null || true
                            _actual_perms=$(stat -c '%a' "$_probe_file" 2>/dev/null || echo "000")
                            rm -f "$_probe_file" 2>/dev/null || true

                            if [ "$_actual_perms" != "755" ]; then
                                _needs_fix=true
                            fi
                        else
                            # Can't write to probe - skip this mount
                            continue
                        fi
                        unset _probe_file _actual_perms
                    fi

                    if [ "$_needs_fix" = "false" ]; then
                        continue
                    fi
                    unset _needs_fix
                fi

                # Apply bindfs overlay
                if [ "$BINDFS_CAN_SUDO" = "true" ]; then
                    if bindfs_run_privileged bindfs \
                        --force-user="$USERNAME" \
                        --force-group="$USERNAME" \
                        --create-for-user="$BINDFS_UID" \
                        --create-for-group="$BINDFS_GID" \
                        --perms=u+rwX,gd+rX,od+rX \
                        -o allow_other \
                        "$mnt_target" "$mnt_target" 2>/dev/null; then
                        echo "   ✓ Applied bindfs overlay on $mnt_target"
                        BINDFS_APPLIED=$((BINDFS_APPLIED + 1))
                    else
                        echo "   ⚠️  Failed to apply bindfs on $mnt_target"
                    fi
                else
                    echo "   ⚠️  Cannot apply bindfs on $mnt_target - no root access or sudo"
                fi
            done < <(findmnt -n -r -o TARGET,FSTYPE 2>/dev/null | grep -E '^/workspace(/| )' || true)

            if [ "$BINDFS_APPLIED" -gt 0 ]; then
                echo "✓ Bindfs overlays applied ($BINDFS_APPLIED mount(s))"
            else
                echo "   No bind mounts needed permission fixes"
            fi

            unset BINDFS_SKIP_MAP BINDFS_CAN_SUDO BINDFS_UID BINDFS_GID BINDFS_APPLIED
        else
            # /dev/fuse not available
            if [ "$BINDFS_ENABLED" = "true" ]; then
                echo "⚠️  Warning: BINDFS_ENABLED=true but /dev/fuse not available"
                echo "   Run container with: --cap-add SYS_ADMIN --device /dev/fuse"
            fi
            # In auto mode, silently skip when /dev/fuse is missing
        fi
    fi
fi

# ============================================================================
# FUSE Hidden File Cleanup (boot-time pass)
# ============================================================================
# FUSE filesystems (including bindfs) create .fuse_hiddenXXXX files when a file
# is deleted while still held open by a process. Stale ones are left behind
# after unclean exits or container stops.
#
# This boot-time pass cleans up files left from the previous session. Ongoing
# cleanup during the session is handled by the fuse-cleanup-cron job (every 10
# minutes, installed by lib/features/bindfs.sh when cron is available).
_fuse_cleaned=0
while IFS= read -r -d '' _hidden_file; do
    # Skip files still held open by a running process
    if command -v fuser >/dev/null 2>&1; then
        fuser "$_hidden_file" >/dev/null 2>&1 && continue
    fi
    rm -f "$_hidden_file" 2>/dev/null && _fuse_cleaned=$((_fuse_cleaned + 1))
done < <(find /workspace -maxdepth 3 -name '.fuse_hidden*' -print0 2>/dev/null)
if [ "$_fuse_cleaned" -gt 0 ]; then
    echo "🧹 Cleaned up $_fuse_cleaned stale .fuse_hidden file(s)"
fi
unset _fuse_cleaned _hidden_file

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
                    su "${USERNAME}" -c "bash '$script'" || {
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
        su "${USERNAME}" -c "touch '$FIRST_RUN_MARKER'"
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
                    su "${USERNAME}" -c "bash '$script'" || {
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

# Build a properly quoted command string to handle arguments with spaces
# Used by su -l, sg docker, and newgrp docker paths to prevent command injection
QUOTED_CMD=""
for arg in "$@"; do
    # Escape single quotes in the argument and wrap in single quotes
    escaped_arg=$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")
    QUOTED_CMD="$QUOTED_CMD '${escaped_arg}'"
done

if [ "$RUNNING_AS_ROOT" = "true" ]; then
    # Drop privileges to non-root user for main process
    # Using 'su -l' ensures a fresh login that picks up updated group memberships
    # from /etc/group (including any groups added for Docker socket access)
    exec su -l "$USERNAME" -c "cd '$(pwd)' && exec $QUOTED_CMD"
elif [ "${DOCKER_SOCKET_CONFIGURED:-false}" = "true" ] && getent group docker >/dev/null 2>&1; then
    # We configured docker socket access but need new group membership
    # Use sg to run command with docker group, or newgrp if sg unavailable
    if command -v sg >/dev/null 2>&1; then
        exec sg docker -c "exec $QUOTED_CMD"
    else
        # Fallback: newgrp replaces shell, so we exec into a new shell with docker group
        exec newgrp docker <<< "exec $QUOTED_CMD"
    fi
else
    exec "$@"
fi
