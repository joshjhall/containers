#!/bin/bash
# 42-workspace-fs-health.sh — Repair worktree damage caused by the host mount
#
# Runs on every container start. Two independent repairs, both idempotent,
# both non-destructive, neither ever fatal to startup:
#
#   1. git core.ignorecase alignment. Bind mounts from macOS/Windows hosts are
#      usually case-insensitive, but a repo cloned on a case-sensitive
#      filesystem carries core.ignorecase=false. Git then treats "Catalog.rs"
#      and "catalog.rs" — one inode, two cached dentry spellings — as two
#      files, so the uppercase spelling shows up as untracked. That is not
#      cosmetic: `git clean -fd` would "remove" the untracked spelling and
#      unlink the shared inode, destroying tracked source.
#
#   2. Stale symlink attributes. Long-lived symlinks on virtiofs can end up
#      cached with nlink=0/size=0 — impossible values for a live symlink. Git
#      compares the index's recorded size against st_size, so such a symlink
#      reports as permanently modified even though its target is byte-correct.
#      Rewriting the link in place with the same target restores sane metadata.
#
# Both repairs run against the superproject AND every initialized submodule,
# recursively (issue #827). `git ls-files` stops at a 160000 gitlink, so a
# superproject-only pass never even enumerates a submodule's symlinks — they
# decay forever. A submodule's core.ignorecase is likewise its own config.
#
# Skip everything with:   SKIP_CASE_CHECK=true
# Detect and report, but never write:  SKIP_CASE_FIX=true
#
# Repair 2 fixes a *time-driven* decay, so a boot-only run is not enough: a
# container left up long enough re-accumulates the bad attributes with nothing
# to re-trigger the repair (issue #794). The same script therefore also runs
# hourly from cron via /usr/local/bin/workspace-fs-health-cron, and on demand
# as /usr/local/bin/workspace-fs-health.
#
# Cron sees none of the container environment, so the BOOT run records the two
# values the cron leg cannot re-derive — PROJECT_ROOT and SKIP_CASE_FIX — into
# an env snapshot. Its ABSENCE is what disables the cron leg, which is why the
# skip gate removes it rather than leaving a stale copy behind.
#
# Only the boot run maintains that snapshot. The cron and on-demand legs pass
# FS_HEALTH_UPDATE_ENV=false, because both run with an environment that would
# poison it: an on-demand run's PROJECT_ROOT is whatever directory the user
# happened to be in, and a run in a non-repo directory exits before it could
# record anything useful.

# ============================================================================
# Environment snapshot for the cron leg
# ============================================================================
# Under $HOME rather than /run: fix_run_permissions sits inside the
# ENTRYPOINT_STARTUP_ONLY guard, so /run is not reliably user-writable on an
# editor's later boots (see .claude/memory/zed-every-boot-startup-replay.md).

FS_HEALTH_ENV_FILE="${FS_HEALTH_ENV_FILE:-${HOME:-/tmp}/.cache/container/fs-health.env}"
FS_HEALTH_UPDATE_ENV="${FS_HEALTH_UPDATE_ENV:-true}"

remove_env_snapshot() {
    [ "$FS_HEALTH_UPDATE_ENV" = "true" ] || return 0
    /usr/bin/rm -f "$FS_HEALTH_ENV_FILE" 2>/dev/null || true
}

write_env_snapshot() {
    [ "$FS_HEALTH_UPDATE_ENV" = "true" ] || return 0

    local dir
    dir=$(command dirname "$FS_HEALTH_ENV_FILE")
    /usr/bin/mkdir -p "$dir" 2>/dev/null || return 0

    # Single-quote the values so a path containing spaces round-trips, and
    # escape any embedded single quote via the standard '\'' idiom. Without the
    # escape, a project path like /workspace/my's-project would terminate the
    # quoting early and turn the rest of the line into shell syntax rather than
    # data — the reader parses these values, so unescaped input there is a code
    # path, not just a wrong string.
    local escaped_root="${PROJECT_ROOT//\'/\'\\\'\'}"
    local escaped_skip="${SKIP_CASE_FIX:-false}"
    escaped_skip="${escaped_skip//\'/\'\\\'\'}"

    # Write to a temp file and rename into place. The hourly cron leg may read
    # this while a fast container restart is rewriting it; rename is atomic on
    # the same filesystem, so the reader sees either the old or the new file,
    # never a half-written one.
    local tmp="${FS_HEALTH_ENV_FILE}.tmp.$$"
    {
        command echo "PROJECT_ROOT='${escaped_root}'"
        command echo "SKIP_CASE_FIX='${escaped_skip}'"
    } >"$tmp" 2>/dev/null || {
        /usr/bin/rm -f "$tmp" 2>/dev/null || true
        return 0
    }
    /usr/bin/mv -f "$tmp" "$FS_HEALTH_ENV_FILE" 2>/dev/null || {
        /usr/bin/rm -f "$tmp" 2>/dev/null || true
        return 0
    }
}

# ============================================================================
# Skip gate
# ============================================================================

if [ "${SKIP_CASE_CHECK:-false}" = "true" ]; then
    # Drop any snapshot from a boot before the opt-out was set — otherwise the
    # cron leg would keep repairing for a user who explicitly opted out.
    remove_env_snapshot
    exit 0
fi

# ============================================================================
# Configuration
# ============================================================================

PROJECT_ROOT="${PROJECT_ROOT:-$PWD}"
CASE_DETECT_SCRIPT="${CASE_DETECT_SCRIPT:-/usr/local/bin/detect-case-sensitivity.sh}"
LOG_PREFIX="[fs-health]"

# Injection seam for the symlink staleness probe. Neither nlink=0 nor size=0 can
# be produced on demand — they are filesystem cache artifacts — so the only way
# to exercise the repair (rather than just its inaction) is to substitute the
# stat call. Matches the CASE_DETECT_SCRIPT / FS_HEALTH_SU seams already here.
FS_HEALTH_STAT="${FS_HEALTH_STAT:-/usr/bin/stat}"

# Submodule recursion depth cap. Purely a containment backstop: a gitlink graph
# is acyclic in practice, but this script must never be the reason a container
# fails to start, and 8 is far past any real nesting.
FS_HEALTH_MAX_DEPTH="${FS_HEALTH_MAX_DEPTH:-8}"

# Report-only mode: detect and warn, but make no changes.
FIX_ENABLED=true
if [ "${SKIP_CASE_FIX:-false}" = "true" ]; then
    FIX_ENABLED=false
fi

# ============================================================================
# Project root validation
# ============================================================================

# A worktree's .git is a *file* pointing at the real git dir, not a directory,
# so accept either shape.
#
# Both bail-outs clear the snapshot: there is nothing here for the cron leg to
# repair, and a snapshot left from an earlier boot would point it at a project
# that is no longer mounted.
if [ ! -e "${PROJECT_ROOT}/.git" ]; then
    remove_env_snapshot
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    remove_env_snapshot
    exit 0
fi

# ============================================================================
# Filesystem case-sensitivity detection
# ============================================================================
# Exposed as an override so tests can force a verdict without needing a real
# case-insensitive filesystem. Values: sensitive | insensitive | unknown.
#
# detect-case-sensitivity.sh exit codes: 0=case-sensitive, 1=case-insensitive,
# 2=error (missing path, not writable). An error is NOT evidence of either
# state, so it must not trigger a repair.

if [ -z "${FS_CASE_STATE+x}" ]; then
    FS_CASE_STATE=unknown
    if [ -x "$CASE_DETECT_SCRIPT" ] && [ -w "$PROJECT_ROOT" ]; then
        QUIET=true "$CASE_DETECT_SCRIPT" "$PROJECT_ROOT" >/dev/null 2>&1
        case "$?" in
            0) FS_CASE_STATE=sensitive ;;
            1) FS_CASE_STATE=insensitive ;;
            *) FS_CASE_STATE=unknown ;;
        esac
    fi
fi

# ============================================================================
# Repair 1: align git core.ignorecase with the actual filesystem
# ============================================================================

# Args: $1 = repo root (superproject or a submodule worktree)
#
# The filesystem verdict is deliberately NOT re-detected per submodule: a
# submodule lives inside the superproject's worktree, so it is on the same
# mount by construction. Only the git config differs, and that is what this
# aligns — a submodule carries its own core.ignorecase, cloned from wherever it
# came from, and is equally wrong on a case-insensitive mount (#827).
check_ignorecase() {
    local root="$1"

    if [ "$FS_CASE_STATE" != "insensitive" ]; then
        return 0
    fi

    local current
    current=$(git -C "$root" config --get core.ignorecase 2>/dev/null) || true

    # Already correct — say nothing.
    if [ "$current" = "true" ]; then
        return 0
    fi

    local shown="${current:-unset}"
    echo "$LOG_PREFIX $root is on a case-insensitive mount" >&2
    echo "$LOG_PREFIX git core.ignorecase is '$shown' (incorrect for this mount)" >&2

    if [ "$FIX_ENABLED" != "true" ]; then
        echo "$LOG_PREFIX SKIP_CASE_FIX=true — not changing it. To fix manually:" >&2
        echo "$LOG_PREFIX   git -C $root config core.ignorecase true" >&2
        return 0
    fi

    if git -C "$root" config core.ignorecase true 2>/dev/null; then
        echo "$LOG_PREFIX set core.ignorecase=true (opt out with SKIP_CASE_FIX=true)" >&2
    else
        echo "$LOG_PREFIX Warning: could not write core.ignorecase (read-only .git?)" >&2
    fi
}

# ============================================================================
# Repair 2: refresh symlinks with stale filesystem attributes
# ============================================================================

# Classify a symlink's cached attributes.
#
# Args: $1 = absolute path to a symlink, $2 = its readlink target (non-empty)
# Prints the reason string and returns 0 when stale; returns 1 when healthy.
#
# Two independent arms, because the two observables decay for the same reason
# but are not known to decay together:
#
#   nlink=0    — impossible for a live symlink. A *broken* link (target does
#                not exist) still reports nlink=1, so this can never fire on
#                one, which is what makes it safe.
#
#   st_size=0  — what git actually keys on. It sizes a symlink from st_size
#                before reading the target, so a zero size makes git read zero
#                bytes and diff the link against the empty blob (issue #827
#                captured exactly that: ":120000 120000 681311eb 00000000 M").
#                A live symlink's st_size IS strlen(target), so size=0 paired
#                with a NON-EMPTY target is a self-contradiction — that pairing
#                is the whole guard, and it is why the caller resolves the
#                target before probing.
#
# #827 observed st_size=0 directly but relinked before sampling %h, so whether
# nlink had also decayed on those links is unconfirmed. Both arms are checked
# rather than assuming they move together: if they always do, the second arm
# costs one extra comparison; if they do not, it is the only thing that fires.
symlink_stale_reason() {
    local path="$1" target="$2"
    local nlink size

    # One stat for both values — the probe runs per tracked symlink per repo.
    read -r nlink size < <("$FS_HEALTH_STAT" -c '%h %s' "$path" 2>/dev/null) || return 1

    [ -n "$nlink" ] && [ -n "$size" ] || return 1

    if [ "$nlink" = "0" ]; then
        command printf '%s\n' "nlink=0"
        return 0
    fi

    if [ "$size" = "0" ] && [ -n "$target" ]; then
        command printf '%s\n' "st_size=0, target '$target'"
        return 0
    fi

    return 1
}

# Args: $1 = repo root, $2 = display prefix for log lines ("" for the
#       superproject, "containers/" for a submodule) so a path is unambiguous
#       once several roots are in play.
check_symlinks() {
    local root="$1" label_prefix="$2"
    local rel path target reason

    # Enumerate tracked symlinks straight from the index (mode 120000). Far
    # cheaper and more precise than walking the worktree, and it inherently
    # skips ignored/untracked links we have no business touching. `ls-files -s`
    # emits "<mode> <sha> <stage>\tpath", so the awk below splits on the tab to
    # keep paths containing spaces intact.
    #
    # This stops at a 160000 gitlink and does NOT descend into submodules —
    # that is the #827 bug. The caller supplies each submodule worktree as its
    # own root instead.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        path="${root}/${rel}"

        [ -L "$path" ] || continue

        # Resolve the target BEFORE the staleness probe: the st_size arm is only
        # meaningful against a non-empty target, and a link we cannot read is
        # one we must not rewrite.
        target=$(/usr/bin/readlink "$path" 2>/dev/null) || continue
        [ -n "$target" ] || continue

        reason=$(symlink_stale_reason "$path" "$target") || continue

        echo "$LOG_PREFIX ${label_prefix}${rel}: stale symlink attributes ($reason)" >&2

        if [ "$FIX_ENABLED" != "true" ]; then
            echo "$LOG_PREFIX SKIP_CASE_FIX=true — not repairing. To fix manually:" >&2
            echo "$LOG_PREFIX   ln -sfn $target $path" >&2
            continue
        fi

        # -n is load-bearing: without it, relinking a symlink that points at a
        # directory would create the new link *inside* that directory.
        # The target is unchanged, so content and git blob identity are intact.
        if /usr/bin/ln -sfn "$target" "$path" 2>/dev/null; then
            echo "$LOG_PREFIX refreshed ${label_prefix}${rel} -> $target" >&2
        else
            echo "$LOG_PREFIX Warning: could not refresh ${label_prefix}${rel} (read-only mount?)" >&2
        fi
    done < <(git -C "$root" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^120000 / { print $2 }')

    return 0
}

# ============================================================================
# Repo traversal: superproject + every initialized submodule, recursively
# ============================================================================

# Run both repairs against one root, then recurse into its submodules.
#
# Args: $1 = repo root, $2 = display prefix for log lines, $3 = current depth
#
# Written as a manual gitlink walk rather than `git submodule foreach
# --recursive` on purpose: foreach spawns a shell per submodule, and both its
# failure semantics and its noise on uninitialized entries would need extra
# containment to satisfy "never fatal to startup, silent when healthy". This
# reuses the same `ls-files -s` idiom the symlink repair already relies on and
# keeps every failure path a local `continue`.
repair_repo_tree() {
    local root="$1" label_prefix="$2" depth="$3"
    local rel sub_root

    check_ignorecase "$root"
    check_symlinks "$root" "$label_prefix"

    # Containment backstop, not an expected condition.
    [ "$depth" -lt "$FS_HEALTH_MAX_DEPTH" ] || return 0

    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        sub_root="${root}/${rel}"

        # The gitlink is in the index whether or not the submodule was ever
        # initialized. An uninitialized (or empty) one has no .git, and this
        # single check is what makes it a silent non-event — no warning, no
        # error, nothing to fix. A submodule worktree's .git is a *file*
        # pointing into the superproject's .git/modules, so test -e, not -d.
        [ -e "${sub_root}/.git" ] || continue

        repair_repo_tree "$sub_root" "${label_prefix}${rel}/" "$((depth + 1))"
    done < <(git -C "$root" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^160000 / { print $2 }')

    return 0
}

# ============================================================================
# Run
# ============================================================================

repair_repo_tree "$PROJECT_ROOT" "" 0

# Record the resolved environment so the hourly cron leg can re-run this same
# script against the same project with the same opt-out. Written last, so the
# snapshot only ever describes a run that actually reached a healthy repo.
write_env_snapshot
