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

check_ignorecase() {
    if [ "$FS_CASE_STATE" != "insensitive" ]; then
        return 0
    fi

    local current
    current=$(git -C "$PROJECT_ROOT" config --get core.ignorecase 2>/dev/null) || true

    # Already correct — say nothing.
    if [ "$current" = "true" ]; then
        return 0
    fi

    local shown="${current:-unset}"
    echo "$LOG_PREFIX $PROJECT_ROOT is on a case-insensitive mount" >&2
    echo "$LOG_PREFIX git core.ignorecase is '$shown' (incorrect for this mount)" >&2

    if [ "$FIX_ENABLED" != "true" ]; then
        echo "$LOG_PREFIX SKIP_CASE_FIX=true — not changing it. To fix manually:" >&2
        echo "$LOG_PREFIX   git -C $PROJECT_ROOT config core.ignorecase true" >&2
        return 0
    fi

    if git -C "$PROJECT_ROOT" config core.ignorecase true 2>/dev/null; then
        echo "$LOG_PREFIX set core.ignorecase=true (opt out with SKIP_CASE_FIX=true)" >&2
    else
        echo "$LOG_PREFIX Warning: could not write core.ignorecase (read-only .git?)" >&2
    fi
}

# ============================================================================
# Repair 2: refresh symlinks with stale filesystem attributes
# ============================================================================

check_symlinks() {
    local rel path target nlink repaired=0

    # Enumerate tracked symlinks straight from the index (mode 120000). Far
    # cheaper and more precise than walking the worktree, and it inherently
    # skips ignored/untracked links we have no business touching. `ls-files -s`
    # emits "<mode> <sha> <stage>\tpath", so the awk below splits on the tab to
    # keep paths containing spaces intact.
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        path="${PROJECT_ROOT}/${rel}"

        [ -L "$path" ] || continue

        nlink=$(/usr/bin/stat -c '%h' "$path" 2>/dev/null) || continue

        # A healthy symlink has nlink>=1 — including a *broken* one, whose
        # target simply doesn't exist. Only the impossible nlink=0 indicates
        # corrupt cached attributes, so this cannot fire on a broken link.
        [ "$nlink" = "0" ] || continue

        target=$(/usr/bin/readlink "$path" 2>/dev/null) || continue
        [ -n "$target" ] || continue

        echo "$LOG_PREFIX $rel: stale symlink attributes (nlink=0)" >&2

        if [ "$FIX_ENABLED" != "true" ]; then
            echo "$LOG_PREFIX SKIP_CASE_FIX=true — not repairing. To fix manually:" >&2
            echo "$LOG_PREFIX   ln -sfn $target $path" >&2
            continue
        fi

        # -n is load-bearing: without it, relinking a symlink that points at a
        # directory would create the new link *inside* that directory.
        # The target is unchanged, so content and git blob identity are intact.
        if /usr/bin/ln -sfn "$target" "$path" 2>/dev/null; then
            echo "$LOG_PREFIX refreshed $rel -> $target" >&2
            repaired=$((repaired + 1))
        else
            echo "$LOG_PREFIX Warning: could not refresh $rel (read-only mount?)" >&2
        fi
    done < <(git -C "$PROJECT_ROOT" ls-files -s 2>/dev/null |
        /usr/bin/awk -F'\t' '$1 ~ /^120000 / { print $2 }')

    return 0
}

# ============================================================================
# Run
# ============================================================================

check_ignorecase
check_symlinks

# Record the resolved environment so the hourly cron leg can re-run this same
# script against the same project with the same opt-out. Written last, so the
# snapshot only ever describes a run that actually reached a healthy repo.
write_env_snapshot
