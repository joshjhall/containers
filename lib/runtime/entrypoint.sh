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
# Source Sub-Modules
# ============================================================================
_RUNTIME_LIB="/opt/container-runtime/lib"

# Exit handlers (cleanup_on_exit, trap setup)
if [ -f "$_RUNTIME_LIB/exit-handlers.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RUNTIME_LIB/exit-handlers.sh"
fi

# Runtime container-user resolution (resolve_container_user). Shared with the
# fs-health cron leg so the two cannot drift — see the sub-module's header.
if [ -f "$_RUNTIME_LIB/resolve-container-user.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RUNTIME_LIB/resolve-container-user.sh"
fi

# ============================================================================
# Startup Time Tracking
# ============================================================================
# Record startup time for observability metrics
STARTUP_BEGIN_TIME=$(date +%s)

# ============================================================================
# Resource Limits
# ============================================================================
# Source resource limits (ulimit configuration)
if [ -f "$_RUNTIME_LIB/resource-limits.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RUNTIME_LIB/resource-limits.sh"
fi

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
# Audit Logging Initialization
# ============================================================================
# Source the audit logger if available. The script auto-initializes on source
# (creates log dir/file, writes init event) and has an internal
# ENABLE_AUDIT_LOGGING != true guard, so sourcing when disabled is safe.
if [ -f "/opt/container-runtime/audit-logger.sh" ]; then
    # shellcheck source=/dev/null
    source "/opt/container-runtime/audit-logger.sh"
fi

# Case-sensitivity detection now lives in the startup script
# 42-workspace-fs-health.sh, which probes the project mount (not /workspace,
# which is the container's own overlay) and repairs what it finds.

# Check if we're running as root
if [ "$(id -u)" -eq 0 ]; then
    RUNNING_AS_ROOT=true
    # Resolve the non-root user to drop into. Editors remap the container
    # user's UID differently — Zed adopts the host UID (e.g. 501 on macOS),
    # VS Code keeps the image-native UID (1000) — so never assume a fixed
    # number. The ladder lives in lib/resolve-container-user.sh because the
    # fs-health cron leg needs the same answer (issue #800); the `|| true`
    # there is what keeps a lookup miss from aborting this `set -e` script
    # before the guard below can report it (silent exit 2).
    USERNAME=""
    if declare -f resolve_container_user >/dev/null 2>&1; then
        USERNAME=$(resolve_container_user) || true
    fi
    if [ -z "$USERNAME" ]; then
        echo "Error: could not determine a non-root container user (set CONTAINER_UID to override)"
        exit 1
    fi
else
    RUNNING_AS_ROOT=false
    USERNAME=$(whoami)
fi

# ============================================================================
# Shared Helper Functions
# ============================================================================
# Run a command with root privileges (directly if root, via sudo otherwise)
run_privileged() {
    if [ "$RUNNING_AS_ROOT" = "true" ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Run all *.sh scripts in a directory with path traversal validation and
# user context switching.  Arguments:
#   $1 - directory containing scripts
#   $2 - label for log messages (e.g. "first-startup", "startup")
run_startup_scripts() {
    local dir="$1"
    local label="$2"

    for script in "${dir}"/*.sh; do
        # Skip if not a regular file or is a symlink
        if [ -f "$script" ] && [ ! -L "$script" ]; then
            # Strict path traversal validation:
            # 1. Resolve canonical path (resolves symlinks and ..)
            # 2. Verify resolved path is within expected directory
            # 3. Verify no .. components remain (paranoid check)
            # 4. Verify not the directory itself (must be file within)
            script_realpath=$(realpath "$script" 2>/dev/null || echo "")
            if [ -n "$script_realpath" ] &&
                [[ "$script_realpath" == "$dir"/* ]] &&
                [[ ! "$script_realpath" =~ \.\. ]] &&
                [ "$script_realpath" != "$dir" ]; then
                echo "Running ${label} script: $(basename "$script")"
                if [ "$RUNNING_AS_ROOT" = "true" ]; then
                    # Running as root, use su to switch to non-root user
                    su "${USERNAME}" -c "bash '$script'" || {
                        echo "⚠️  WARNING: ${label^} script failed: $(basename "$script") (continuing)"
                    }
                else
                    # Already running as non-root user, execute directly
                    bash "$script" || {
                        echo "⚠️  WARNING: ${label^} script failed: $(basename "$script") (continuing)"
                    }
                fi
            else
                echo "⚠️  WARNING: Skipping script outside expected directory: $script"
            fi
        fi
    done
}

# ============================================================================
# Source Concern-Specific Sub-Modules
# ============================================================================
if [ -f "$_RUNTIME_LIB/fix-docker-socket.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RUNTIME_LIB/fix-docker-socket.sh"
fi
if [ -f "$_RUNTIME_LIB/fix-cache-permissions.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RUNTIME_LIB/fix-cache-permissions.sh"
fi
if [ -f "$_RUNTIME_LIB/fix-run-permissions.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RUNTIME_LIB/fix-run-permissions.sh"
fi
if [ -f "$_RUNTIME_LIB/setup-bindfs.sh" ]; then
    # shellcheck source=/dev/null
    source "$_RUNTIME_LIB/setup-bindfs.sh"
fi
unset _RUNTIME_LIB

# ============================================================================
# Startup-only replay mode
# ============================================================================
# ENTRYPOINT_STARTUP_ONLY=true runs ONLY the every-boot startup phase
# (/etc/container/startup/*) and skips the expensive, privileged one-time work
# below: cache/run chowns, docker-socket reconcile, bindfs overlays, cron
# bring-up, and first-time setup. It exists for `recover-entrypoint`, which
# replays this entrypoint on every container start under devcontainer impls
# that skip the image ENTRYPOINT (notably Zed). The full setup ran on the first
# replay and left the ~/.container-initialized marker; subsequent starts only
# need the every-boot scripts (secrets refresh, auth watcher, health check,
# codegraph sync, …) re-run. See docs/troubleshooting/zed-devcontainer.md.

# Assigned outside the guard on purpose: the first-time-setup block below is the
# only writer, but the audit_log call after the every-boot phase reads it on
# BOTH paths. Assigning it inside the guard left it unbound on the startup-only
# replay, where `set -u` aborted the reading subshell and the audit record's
# first_run field came out empty.
FIRST_RUN_MARKER="/home/${USERNAME}/.container-initialized"

if [ "${ENTRYPOINT_STARTUP_ONLY:-false}" != "true" ]; then

    # ============================================================================
    # Sequential Initialization
    # ============================================================================

    # --- Docker socket access ---
    configure_docker_socket "$@"
    if declare -f audit_log >/dev/null 2>&1; then
        audit_log "configuration" "info" "Docker socket configuration complete" \
            "{\"stage\":\"startup\",\"docker_socket_exists\":$([ -S /var/run/docker.sock ] && echo true || echo false)}" 2>/dev/null || true
    fi

    # --- Cache directory permissions ---
    fix_cache_permissions

    # --- /run tmpfs permissions ---
    # The /run tmpfs mounts root-owned (its uid can't be baked into compose because
    # editors remap the runtime UID), so align it to the resolved user like /cache.
    if declare -f fix_run_permissions >/dev/null 2>&1; then
        fix_run_permissions
    fi

    # --- Bindfs overlays + FUSE cleanup ---
    setup_bindfs_overlays

    # ============================================================================
    # Cron Daemon Startup
    # ============================================================================
    # Start cron daemon if installed (requires root privileges)
    # This runs before dropping to non-root user so no sudo is needed
    if command -v cron &>/dev/null; then
        if ! pgrep -x "cron" >/dev/null 2>&1; then
            echo "🔧 Starting cron daemon..."
            if [ "$RUNNING_AS_ROOT" = "true" ]; then
                # Start cron directly as root
                if command -v service &>/dev/null; then
                    service cron start >/dev/null 2>&1 || cron
                else
                    cron
                fi
                if pgrep -x "cron" >/dev/null 2>&1; then
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
    # (FIRST_RUN_MARKER is assigned above the guard — it is read on both paths)
    FIRST_STARTUP_DIR="/etc/container/first-startup"
    if [ ! -f "$FIRST_RUN_MARKER" ]; then
        echo "=== Running first-time setup scripts ==="
        run_startup_scripts "$FIRST_STARTUP_DIR" "first-startup"

        # Create marker file
        if [ "$RUNNING_AS_ROOT" = "true" ]; then
            su "${USERNAME}" -c "touch '$FIRST_RUN_MARKER'"
        else
            touch "$FIRST_RUN_MARKER"
        fi
    fi

fi # end: ENTRYPOINT_STARTUP_ONLY guard (privileged one-time + first-time setup)

# ============================================================================
# Every-Boot Scripts
# ============================================================================
# Run startup scripts every time
STARTUP_DIR="/etc/container/startup"
if [ -d "$STARTUP_DIR" ]; then
    echo "=== Running startup scripts ==="
    run_startup_scripts "$STARTUP_DIR" "startup"
fi

# Audit: startup scripts complete
if declare -f audit_log >/dev/null 2>&1; then
    audit_log "system" "info" "Startup scripts complete" \
        "{\"stage\":\"startup\",\"first_run\":$([ -f "$FIRST_RUN_MARKER" ] && echo false || echo true)}" 2>/dev/null || true
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
METRICS_FILE="$METRICS_DIR/startup-metrics.txt"
# Only pass -o when we can actually chown (root). On the startup-only replay we
# run unprivileged, where `install -o <user>` fails outright and the whole call
# no-ops — leaving a root-owned dir from a previous privileged boot and a
# "Permission denied" on the write below. Non-root just ensures the dir exists;
# if it is already there and owned by someone else, the guarded write is skipped.
if [ "$RUNNING_AS_ROOT" = "true" ]; then
    command install -d -m 0750 -o "${USERNAME}" "$METRICS_DIR" 2>/dev/null || true
else
    command install -d -m 0750 "$METRICS_DIR" 2>/dev/null || true
fi

# Write startup metrics (Prometheus format)
# Fail gracefully if we can't write metrics (non-critical).
# The writability test is not redundant with `2>/dev/null || true`: a FAILED
# REDIRECTION is reported by the shell itself before the redirect is in place,
# so `> unwritable 2>/dev/null` still prints "Permission denied". Testing first
# is the only way to keep the replay path quiet.
#
# Test the FILE when it exists, not just the dir: a privileged first boot leaves
# a root-owned startup-metrics.txt that an unprivileged replay cannot overwrite
# even though the directory itself is writable.
if { [ -e "$METRICS_FILE" ] && [ -w "$METRICS_FILE" ]; } ||
    { [ ! -e "$METRICS_FILE" ] && [ -w "$METRICS_DIR" ]; }; then
    {
        echo "# HELP container_startup_seconds Time taken for container initialization in seconds"
        echo "# TYPE container_startup_seconds gauge"
        echo "container_startup_seconds $STARTUP_DURATION"
    } >"$METRICS_FILE" 2>/dev/null || true
fi

echo "✓ Container initialized in ${STARTUP_DURATION}s"

# ============================================================================
# Main Process Execution
# ============================================================================
# Execute the main command
echo "=== Starting main process ==="

# Audit: about to exec main process
if declare -f audit_log >/dev/null 2>&1; then
    audit_log "process" "info" "Executing main process" \
        "{\"stage\":\"exec\",\"command\":\"$(basename "${1:-unknown}")\",\"startup_duration\":$STARTUP_DURATION}" 2>/dev/null || true
fi

# Build a properly quoted command string to handle arguments with spaces
# Used by su -l, sg docker, and newgrp docker paths to prevent command injection
QUOTED_CMD=""
for arg in "$@"; do
    # Escape single quotes in the argument and wrap in single quotes
    escaped_arg=$(printf '%s' "$arg" | command sed "s/'/'\\\\''/g")
    QUOTED_CMD="$QUOTED_CMD '${escaped_arg}'"
done
# Escape pwd the same way we escape command arguments (prevents injection via crafted directory names)
QUOTED_PWD=$(printf '%s' "$(pwd)" | command sed "s/'/'\\\\''/g")

if [ "$RUNNING_AS_ROOT" = "true" ]; then
    # Drop privileges to non-root user for main process
    # Using 'su -l' ensures a fresh login that picks up updated group memberships
    # from /etc/group (including any groups added for Docker socket access)
    exec su -l "$USERNAME" -c "cd '${QUOTED_PWD}' && exec $QUOTED_CMD"
elif [ "${DOCKER_SOCKET_CONFIGURED:-false}" = "true" ] && getent group docker >/dev/null 2>&1; then
    # We configured docker socket access but need new group membership
    # Use sg to run command with docker group, or newgrp if sg unavailable
    if command -v sg >/dev/null 2>&1; then
        exec sg docker -c "exec $QUOTED_CMD"
    else
        # Fallback: newgrp replaces shell, so we exec into a new shell with docker group
        exec newgrp docker <<<"exec $QUOTED_CMD"
    fi
else
    exec "$@"
fi
