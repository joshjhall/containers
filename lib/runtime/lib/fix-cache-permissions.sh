#!/bin/bash
# Cache Directory Permissions Fix
# Sourced by entrypoint.sh — do not execute directly
#
# Fixes ownership of /cache directories that may have been created as root
# during Docker build (e.g., npm global installs create cache files as root).
#
# This runs on every startup because:
#   1. Cache volumes may be shared across containers with different UIDs
#   2. New cache subdirectories may be created by root during image updates
#   3. It's idempotent and fast when permissions are already correct
#
# Depends on globals from entrypoint.sh:
#   RUNNING_AS_ROOT, USERNAME, run_privileged()

fix_cache_permissions() {
    [ -d "/cache" ] || return 0

    # Check if we need to fix permissions (any root-owned files in /cache)
    if ! command find /cache -user root -print -quit 2>/dev/null | command grep -q .; then
        return 0
    fi

    echo "🔧 Fixing /cache directory permissions..."

    # Determine if we can perform privileged operations
    local can_fix=false
    if [ "$RUNNING_AS_ROOT" = "true" ]; then
        can_fix=true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        can_fix=true
    fi

    if [ "$can_fix" = "true" ]; then
        # Fix ownership of all cache directories
        if run_privileged chown -R "${USERNAME}:${USERNAME}" /cache 2>/dev/null; then
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
}
