#!/bin/bash
# Runtime /run tmpfs Permissions Fix
# Sourced by entrypoint.sh — do not execute directly
#
# Reconciles ownership of the /run tmpfs with the runtime user. The
# devcontainer compose mounts /run as a tmpfs so the runtime user can write
# its sockets/pidfiles there, but the mount lands root-owned: Docker's tmpfs
# `uid=`/`gid=` options are literal numbers baked at mount time, and editors
# remap the runtime user's UID *after* build (Zed adopts the host UID, e.g.
# 501; VS Code keeps the image-native 1000). Any number hardcoded in compose
# is therefore wrong for one of them — the same class of bug that the
# resolve-user-by-shape change fixed in the entrypoint, and that
# fix_cache_permissions handles for /cache.
#
# So we mount /run neutrally (no uid=/gid=) and align it here to whatever the
# entrypoint resolved the runtime user to be.
#
# Idempotent: a no-op when /run is already owned by the runtime user.
#
# Depends on globals from entrypoint.sh:
#   RUNNING_AS_ROOT, USERNAME, run_privileged()

fix_run_permissions() {
    [ -d "/run" ] || return 0

    # Resolve target UID/GID by name. We chown by number so the fix works even
    # when the runtime UID has no matching passwd entry, and so a user whose
    # primary group name differs from their username is handled correctly.
    local target_uid target_gid
    target_uid=$(id -u "${USERNAME}" 2>/dev/null) || target_uid=""
    target_gid=$(id -g "${USERNAME}" 2>/dev/null) || target_gid=""
    if [ -z "$target_uid" ] || [ -z "$target_gid" ]; then
        echo "⚠️  Warning: Could not resolve UID/GID for ${USERNAME}; skipping /run permission check"
        return 0
    fi

    # Only act when the /run mountpoint itself is misowned. We deliberately
    # check just the top-level dir (not -R find) — /run accumulates entries
    # from system services at runtime, and we only need the runtime user to own
    # the mountpoint to create its own sockets/pidfiles under it.
    local cur_uid cur_gid
    cur_uid=$(command stat -c '%u' /run 2>/dev/null) || cur_uid=""
    cur_gid=$(command stat -c '%g' /run 2>/dev/null) || cur_gid=""
    if [ "$cur_uid" = "$target_uid" ] && [ "$cur_gid" = "$target_gid" ]; then
        return 0
    fi

    echo "🔧 Aligning /run ownership to ${USERNAME} (${target_uid}:${target_gid})..."

    local can_fix=false
    if [ "$RUNNING_AS_ROOT" = "true" ]; then
        can_fix=true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        can_fix=true
    fi

    if [ "$can_fix" = "true" ]; then
        if run_privileged chown "${target_uid}:${target_gid}" /run 2>/dev/null; then
            echo "✓ /run ownership aligned"
        else
            echo "⚠️  Warning: Could not align /run ownership"
            echo "   Services that write sockets/pidfiles under /run may fail"
        fi
    else
        echo "⚠️  Warning: Cannot fix /run permissions - no root access or sudo"
        echo "   /run is owned by a UID/GID that doesn't match ${USERNAME} (${target_uid}:${target_gid})"
        echo "   To fix: run container as root or enable ENABLE_PASSWORDLESS_SUDO=true"
    fi
}
