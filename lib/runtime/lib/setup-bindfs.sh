#!/bin/bash
# Bindfs Overlay and FUSE Cleanup
# Sourced by entrypoint.sh — do not execute directly
#
# When bindfs is installed and /dev/fuse is available, applies FUSE overlays
# on host bind mounts under /workspace to fix permission issues (e.g., macOS
# VirtioFS where APFS lacks full Linux permission semantics).
#
# Also handles boot-time cleanup of stale .fuse_hidden files left from
# previous sessions.
#
# Modes (BINDFS_ENABLED):
#   auto  - probe permissions on each mount, apply only if broken (default)
#   true  - always apply bindfs to all bind mounts under /workspace
#   false - disabled entirely
#
# BINDFS_SKIP_PATHS: comma-separated paths to exclude from overlay
#
# Requires: --cap-add SYS_ADMIN --device /dev/fuse at container runtime
#
# Depends on globals from entrypoint.sh:
#   RUNNING_AS_ROOT, USERNAME, run_privileged()

# Parse BINDFS_SKIP_PATHS env var into associative array for O(1) lookup
# Sets global: BINDFS_SKIP_MAP
parse_bindfs_skip_paths() {
    declare -gA BINDFS_SKIP_MAP=()
    if [ -n "${BINDFS_SKIP_PATHS:-}" ]; then
        local _skip_arr _skip_path
        IFS=',' read -ra _skip_arr <<< "$BINDFS_SKIP_PATHS"
        for _skip_path in "${_skip_arr[@]}"; do
            # Trim whitespace
            _skip_path="${_skip_path## }"
            _skip_path="${_skip_path%% }"
            [ -n "$_skip_path" ] && BINDFS_SKIP_MAP["$_skip_path"]=1
        done
    fi
}

# Check if a mount point needs a bindfs overlay
# Arguments:
#   $1 - mount target path
#   $2 - mount filesystem type
#   $3 - bindfs mode ("auto" or "true")
# Returns: 0 if fix needed, 1 if not
probe_mount_needs_fix() {
    local mnt_target="$1"
    local mnt_fstype="$2"
    local mode="$3"

    # Skip mounts that are already FUSE overlays
    if [[ "$mnt_fstype" == *fuse* ]]; then
        return 1
    fi

    # Skip paths in BINDFS_SKIP_PATHS
    if [ -n "${BINDFS_SKIP_MAP[$mnt_target]+_}" ]; then
        echo "   Skipping $mnt_target (in BINDFS_SKIP_PATHS)"
        return 1
    fi

    # In "true" mode, always apply
    if [ "$mode" != "auto" ]; then
        return 0
    fi

    # Auto mode: probe permissions before applying
    # Check 1: filesystem type indicates permission faking
    case "$mnt_fstype" in
        fakeowner|virtiofs|grpcfuse|osxfs)
            return 0
            ;;
    esac

    # Check 2: direct permission probe
    local _probe_file="$mnt_target/.bindfs-probe-$$"
    if touch "$_probe_file" 2>/dev/null; then
        chmod 755 "$_probe_file" 2>/dev/null || true
        local _actual_perms
        _actual_perms=$(stat -c '%a' "$_probe_file" 2>/dev/null || echo "000")
        rm -f "$_probe_file" 2>/dev/null || true

        if [ "$_actual_perms" != "755" ]; then
            return 0
        fi
    else
        # Can't write to probe - skip this mount
        return 1
    fi

    return 1
}

# Apply bindfs overlay to a single mount point
# Arguments:
#   $1 - mount target path
# Uses globals: BINDFS_CAN_SUDO, USERNAME, BINDFS_UID, BINDFS_GID
# Returns: 0 on success, 1 on failure
apply_bindfs_overlay() {
    local mnt_target="$1"

    if [ "$BINDFS_CAN_SUDO" = "true" ]; then
        if run_privileged bindfs \
            --force-user="$USERNAME" \
            --force-group="$USERNAME" \
            --create-for-user="$BINDFS_UID" \
            --create-for-group="$BINDFS_GID" \
            --perms=u+rwX,gd+rX,od+rX \
            -o allow_other \
            "$mnt_target" "$mnt_target" 2>/dev/null; then
            echo "   ✓ Applied bindfs overlay on $mnt_target"
            return 0
        else
            echo "   ⚠️  Failed to apply bindfs on $mnt_target"
            return 1
        fi
    else
        echo "   ⚠️  Cannot apply bindfs on $mnt_target - no root access or sudo"
        return 1
    fi
}

# Main entry point: orchestrate bindfs overlays + FUSE cleanup
# Called explicitly by entrypoint.sh
setup_bindfs_overlays() {
    # --- Bindfs overlay application ---
    if command -v bindfs >/dev/null 2>&1; then
        BINDFS_ENABLED="${BINDFS_ENABLED:-auto}"

        if [ "$BINDFS_ENABLED" != "false" ]; then
            if [ -e /dev/fuse ]; then
                echo "🔧 Checking bind mounts for permission fixes (bindfs=$BINDFS_ENABLED)..."

                parse_bindfs_skip_paths

                BINDFS_CAN_SUDO=false
                if [ "$RUNNING_AS_ROOT" = "true" ]; then
                    BINDFS_CAN_SUDO=true
                elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
                    BINDFS_CAN_SUDO=true
                fi

                BINDFS_UID=$(id -u "$USERNAME")
                BINDFS_GID=$(id -g "$USERNAME")

                BINDFS_APPLIED=0
                while IFS=' ' read -r mnt_target mnt_fstype; do
                    [ -z "$mnt_target" ] && continue
                    if probe_mount_needs_fix "$mnt_target" "$mnt_fstype" "$BINDFS_ENABLED"; then
                        apply_bindfs_overlay "$mnt_target" && BINDFS_APPLIED=$((BINDFS_APPLIED + 1))
                    fi
                done < <(findmnt -n -r -o TARGET,FSTYPE 2>/dev/null | command grep -E '^/workspace(/| )' || true)

                if [ "$BINDFS_APPLIED" -gt 0 ]; then
                    echo "✓ Bindfs overlays applied ($BINDFS_APPLIED mount(s))"
                else
                    echo "   No bind mounts needed permission fixes"
                fi

                unset BINDFS_SKIP_MAP BINDFS_CAN_SUDO BINDFS_UID BINDFS_GID BINDFS_APPLIED
            else
                if [ "$BINDFS_ENABLED" = "true" ]; then
                    echo "⚠️  Warning: BINDFS_ENABLED=true but /dev/fuse not available"
                    echo "   Run container with: --cap-add SYS_ADMIN --device /dev/fuse"
                fi
            fi
        fi
    fi

    # --- FUSE hidden file cleanup (boot-time pass) ---
    # FUSE filesystems (including bindfs) create .fuse_hiddenXXXX files when a
    # file is deleted while still held open by a process. Stale ones are left
    # behind after unclean exits or container stops.
    #
    # This boot-time pass cleans up files left from the previous session.
    # Ongoing cleanup during the session is handled by the fuse-cleanup-cron
    # job (every 10 minutes, installed by lib/features/bindfs.sh when cron is
    # available).
    _fuse_cleaned=0
    while IFS= read -r -d '' _hidden_file; do
        # Skip files still held open by a running process
        if command -v fuser >/dev/null 2>&1; then
            fuser "$_hidden_file" >/dev/null 2>&1 && continue
        fi
        rm -f "$_hidden_file" 2>/dev/null && _fuse_cleaned=$((_fuse_cleaned + 1))
    done < <(command find /workspace -maxdepth 3 -name '.fuse_hidden*' -print0 2>/dev/null)
    if [ "$_fuse_cleaned" -gt 0 ]; then
        echo "🧹 Cleaned up $_fuse_cleaned stale .fuse_hidden file(s)"
    fi
    unset _fuse_cleaned _hidden_file
}
