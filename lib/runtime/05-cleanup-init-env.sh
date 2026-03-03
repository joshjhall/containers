#!/bin/bash
# 05-cleanup-init-env.sh — Securely remove .devcontainer/.env after boot
#
# Runs on every container start (before secrets at 50-). By the time this
# executes, Docker Compose has already injected the env vars from the file
# at container creation time, so the file is no longer needed.
#
# Skip with: SKIP_INIT_ENV_CLEANUP=true

# ============================================================================
# Skip gate
# ============================================================================

if [ "${SKIP_INIT_ENV_CLEANUP:-false}" = "true" ]; then
    exit 0
fi

# ============================================================================
# Locate .devcontainer/.env
# ============================================================================

_workspace="${WORKSPACE_ROOT:-${PWD:-/workspace}}"
_env_file="${_workspace}/.devcontainer/.env"

if [ ! -f "$_env_file" ]; then
    exit 0
fi

# ============================================================================
# Securely delete
# ============================================================================

/usr/bin/shred -fz -n 3 "$_env_file" 2>/dev/null || true
/usr/bin/rm -f "$_env_file" 2>/dev/null || true

exit 0
