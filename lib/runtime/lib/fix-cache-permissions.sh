#!/bin/bash
# Cache Directory Permissions Fix
# Sourced by entrypoint.sh — do not execute directly
#
# Reconciles /cache ownership with the runtime user. Cache contents may end
# up owned by a different UID/GID than the running user for several reasons:
#   1. Build-time chowns used the build-arg USER_UID, which differs from the
#      runtime UID when the same image is consumed by tools that pick a
#      different default (e.g., VS Code dev containers vs. Zed dev containers).
#   2. A persistent /cache volume may be shared across containers built with
#      different USER_UID values.
#   3. Some package manager installs (npm, etc.) create files as root during
#      image build.
#
# Any of these break tools that refuse to operate on directories they don't
# own — most notably the 1Password CLI, which errors out hard when
# OP_CONFIG_DIR isn't owned by the current user.
#
# Idempotent: a no-op when /cache is already aligned with the runtime user.
#
# Depends on globals from entrypoint.sh:
#   RUNNING_AS_ROOT, USERNAME, run_privileged()

fix_cache_permissions() {
    [ -d "/cache" ] || return 0

    # Resolve target UID/GID by name once. We chown by number so the fix
    # still works for cache files owned by an orphaned UID with no passwd
    # entry, and so a user whose primary group name differs from their
    # username (uncommon but possible) is handled correctly.
    local target_uid target_gid
    target_uid=$(id -u "${USERNAME}" 2>/dev/null) || target_uid=""
    target_gid=$(id -g "${USERNAME}" 2>/dev/null) || target_gid=""
    if [ -z "$target_uid" ] || [ -z "$target_gid" ]; then
        echo "⚠️  Warning: Could not resolve UID/GID for ${USERNAME}; skipping /cache permission check"
        return 0
    fi

    # Trigger if anything under /cache has a UID OR GID that doesn't match
    # the runtime target. -print -quit bails on the first divergence so this
    # stays cheap on already-aligned caches.
    if ! command find /cache \( ! -uid "$target_uid" -o ! -gid "$target_gid" \) -print -quit 2>/dev/null | command grep -q .; then
        return 0
    fi

    echo "🔧 Aligning /cache ownership to ${USERNAME} (${target_uid}:${target_gid})..."

    local can_fix=false
    if [ "$RUNNING_AS_ROOT" = "true" ]; then
        can_fix=true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        can_fix=true
    fi

    if [ "$can_fix" = "true" ]; then
        if run_privileged chown -R "${target_uid}:${target_gid}" /cache 2>/dev/null; then
            echo "✓ Cache directory ownership aligned"
        else
            echo "⚠️  Warning: Could not fix all cache permissions"
            echo "   Some package manager operations may fail"
        fi
    else
        echo "⚠️  Warning: Cannot fix /cache permissions - no root access or sudo"
        echo "   /cache contains files owned by a UID/GID that doesn't match ${USERNAME} (${target_uid}:${target_gid})"
        echo "   Affected tools: 1Password CLI (op), npm, pip, and other cache-using tools"
        echo "   To fix: run container as root or enable ENABLE_PASSWORDLESS_SUDO=true"
    fi
}
