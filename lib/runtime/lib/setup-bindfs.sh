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
        IFS=',' read -ra _skip_arr <<<"$BINDFS_SKIP_PATHS"
        for _skip_path in "${_skip_arr[@]}"; do
            # Trim leading and trailing whitespace (spaces and tabs)
            _skip_path="${_skip_path#"${_skip_path%%[! $'\t']*}"}"
            _skip_path="${_skip_path%"${_skip_path##*[! $'\t']}"}"
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
        fakeowner | virtiofs | grpcfuse | osxfs)
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
        # --xattr-none is the #977 fix, not a gratuitous capability reduction.
        #
        # BuildKit's context sender calls lgetxattr(2) on every path it walks.
        # On the virtiofs lower backing /workspace, that call returns ELOOP (40)
        # for ANY symlink, and bindfs RELAYS it — so `docker build` from the repo
        # root aborts before a single build step runs:
        #
        #   error from sender: failed to xattr .codegraph:
        #     too many levels of symbolic links
        #
        # That blocked every integration test that builds an image, and the only
        # workaround was deleting the repo's tracked symlinks around each build.
        #
        # The ELOOP is NOT bindfs's own behavior: bindfs over tmpfs answers a
        # symlink's lgetxattr cleanly. It comes from the lower layer. --xattr-none
        # makes bindfs answer the call ITSELF with EOPNOTSUPP (95), which is what
        # BuildKit expects for "this file has no xattrs" — so the walk continues.
        #
        # --xattr-ro was tried and does NOT work: it still relays ELOOP for
        # symlinks (only regular files answer). --xattr-none is the only option
        # that fixes it.
        #
        # Safe here ONLY because nothing in this image reads xattrs: there is no
        # setfattr/getfattr/listxattr anywhere in lib/, tests/, or bin/, and the
        # sole xattr present on the mount is com.apple.provenance — a macOS host
        # artifact with no meaning inside the container. Re-check that before
        # removing this flag; dropping it silently restores the build failure.
        if run_privileged bindfs \
            --force-user="$USERNAME" \
            --force-group="$USERNAME" \
            --create-for-user="$BINDFS_UID" \
            --create-for-group="$BINDFS_GID" \
            --perms=u+rwX,gd+rX,od+rX \
            --xattr-none \
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
    #
    # Both legs delegate to the same /usr/local/bin/fuse-cleanup. They used to
    # carry two copies of the walk, which drifted: this one hardcoded /workspace
    # as its root and so burned one depth level on the <repo> directory, making
    # it strictly weaker than the cron pass it is meant to complement (#948).
    # The shared GC discovers roots from findmnt like the cron leg does;
    # /workspace survives only as the fallback for the case this leg uniquely
    # handles — files stranded by a previous session whose mounts are now gone.
    #
    # The missing-binary branch is REPORTED, not silent (#951). The GC is
    # installed unconditionally by the Dockerfile, so its absence means a broken
    # image (partial build, bad permissions, a stale layer cache predating that
    # Dockerfile change) — and a silent skip here disables the boot leg
    # permanently while looking exactly like a clean run. That is the same
    # invisible-stranded-files failure #948 was filed against, reintroduced
    # through the fix for it.
    # This call runs ROOT-PRIVILEGED (the entrypoint has not yet dropped to
    # $USERNAME) and the GC's walk is not depth-bounded, so whatever names its
    # roots names the scope of a recursive `rm -f`. Three of the GC's inputs can
    # redirect that walk, and all three exist ONLY as testing seams:
    #
    #   FUSE_CLEANUP_ROOTS         - names the roots outright
    #   FUSE_CLEANUP_FINDMNT       - names the discovery binary, so a stub that
    #                                prints / grants the same arbitrary root
    #   FUSE_CLEANUP_FALLBACK_ROOT - grants a root when discovery finds nothing
    #
    # Read from the ambient environment they would let anyone who can influence
    # container env (compose `environment:`, .env, a runtime arg) point a
    # root-executed walk-and-delete at a directory of their choosing (#953). So
    # they are dropped HERE, at the production call point, rather than validated
    # inside the GC: a validating GC still accepts an attacker-chosen live mount,
    # and an in-GC allow-flag would just be a second env var that whoever sets
    # ROOTS can set too. A variable unset in this subshell cannot be read by the
    # process that does the deleting — that is the whole boundary.
    #
    # FUSE_CLEANUP_DISABLE is deliberately NOT dropped: it is a documented
    # operator control, not a walk-redirector. The set is defined by what can
    # redirect the walk, not by the name prefix.
    #
    # FUSE_CLEANUP_BIN is a known larger hole left open on purpose (#968): it is
    # read HERE rather than by the GC, both callers' test suites inject through
    # it, and it grants arbitrary root code execution rather than deletion of
    # .fuse_hidden* — a different fix with a different design.
    #
    # The unset precedes the assignment on purpose, so this leg's own
    # FUSE_CLEANUP_FALLBACK_ROOT=/workspace still reaches the GC. That fallback
    # is what makes the boot pass able to clear files a previous session
    # stranded, which is the one thing this leg uniquely does.
    _fuse_cleanup_bin="${FUSE_CLEANUP_BIN:-/usr/local/bin/fuse-cleanup}"
    if [ -x "$_fuse_cleanup_bin" ]; then
        _fuse_cleaned=$(
            unset FUSE_CLEANUP_ROOTS FUSE_CLEANUP_FINDMNT FUSE_CLEANUP_FALLBACK_ROOT
            FUSE_CLEANUP_FALLBACK_ROOT=/workspace "$_fuse_cleanup_bin" 2>/dev/null || echo 0
        )
        if [ "${_fuse_cleaned:-0}" -gt 0 ] 2>/dev/null; then
            echo "🧹 Cleaned up $_fuse_cleaned stale .fuse_hidden file(s)"
        fi
    else
        echo "   ⚠️  FUSE cleanup skipped - $_fuse_cleanup_bin missing or not executable"
        echo "      Stale .fuse_hidden* files will accumulate (issue #951)"
    fi
    unset _fuse_cleaned _fuse_cleanup_bin
}
