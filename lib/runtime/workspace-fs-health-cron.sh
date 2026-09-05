#!/bin/bash
# workspace-fs-health-cron — hourly re-run of the workspace filesystem repair
#
# 42-workspace-fs-health.sh repairs symlinks whose virtiofs attributes have
# gone stale (nlink=0/size=0). That decay is time-driven, not boot-driven: a
# container left up long enough drifts back into the broken state, and with the
# links reading as empty a `git add -A` / `git commit -a` / `git stash` stages
# the DELETION of those symlinks. Running the repair only at container start
# therefore fixes it once and then loses to uptime (issue #794).
#
# This wrapper is the cron leg of that repair. It re-runs the same script,
# unmodified, against the same project the boot run resolved.
#
# Cron invokes it as ROOT and it drops to the container user itself, rather than
# letting cron's user column name that user: the column is written at build time
# and the runtime user is not knowable then (issue #800). See the re-exec stage
# below.
#
# Cron jobs inherit none of the container environment, so the values that cannot
# be re-derived here — which scope to inspect, and whether the user opted out of
# writes — are read from the snapshot the boot run recorded. No snapshot means
# "do not run": either SKIP_CASE_CHECK=true was set or the boot script never
# ran. Both should be silent no-ops rather than a guess at a root (under cron,
# $PWD is the user's home).
#
# "No repo was mounted" is deliberately NOT in that list any more (issue #828).
# The boot run now writes the snapshot even when the workspace holds zero repos,
# precisely so this leg keeps running and picks up a repo mounted later. It used
# to remove the snapshot in that case, which disabled the hourly repair for the
# life of the container.
#
# The snapshot is PARSED, never sourced. Sourcing it would make every byte in
# the file executable shell, so a project path containing a quote plus shell
# syntax would run as code on the hourly timer. Parsing keeps those values as
# the strings they are meant to be.

set -uo pipefail

FS_HEALTH_SCRIPT="${FS_HEALTH_SCRIPT:-/etc/container/startup/42-workspace-fs-health.sh}"
CRON_ENV_FILE="${CRON_ENV_FILE:-/etc/container/cron-env}"
FS_HEALTH_RESOLVE_USER_LIB="${FS_HEALTH_RESOLVE_USER_LIB:-/opt/container-runtime/lib/resolve-container-user.sh}"
FS_HEALTH_SU="${FS_HEALTH_SU:-su}"

# ============================================================================
# Drop from root to the resolved container user
# ============================================================================
# The /etc/cron.d entry runs this as ROOT on purpose. Cron's user column is
# written at image build time, but the runtime user is not knowable then —
# editors remap it (Zed adopts the host UID, VS Code keeps 1000), so a baked
# ${USERNAME} can name the wrong user. That failure is silent rather than loud:
# the build-time user always exists, so cron happily runs the job as it, HOME
# resolves to that user's home, the snapshot below is not found, and the job
# exits 0 by the "no snapshot means do not run" contract — the hourly repair
# never fires and nothing reports it (issue #800).
#
# So resolve the user HERE, hourly, at run time, and re-exec as them. `su -l`
# rather than plain `su` is load-bearing: the login shell is what sets the
# right HOME, and HOME is exactly what the snapshot lookup depends on.
#
# The guard is an ARGUMENT, not an environment variable, because `su -l` wipes
# the environment — an env-var guard would not survive the re-exec and the
# second pass would loop.
#
# CONTAINER_UID parity, precisely. The ladder's first arm honors CONTAINER_UID,
# but cron inherits none of `docker run -e`, so under cron that arm is reachable
# ONLY via $CRON_ENV_FILE (sourced just below, ahead of the resolution).
#
# Nothing in the repo writes CONTAINER_UID into that file today — lib/features/
# cron.sh generates it at build time, and CONTAINER_UID is a runtime value — so
# in practice this leg resolves by SHAPE MATCH. That is correct for every image
# we ship, each of which has exactly one regular login user. The divergence
# needs a second such account AND a CONTAINER_UID naming the other one.
#
# The sourcing order is still deliberate, not decorative: it is what lets an
# operator (or a later change) make the arm live by exporting CONTAINER_UID into
# that file, and $CRON_ENV_FILE is the only source safe to grant that power —
# it is root-owned. This value decides which account a ROOT process drops into,
# so a user-writable source would be a privilege-escalation vector. That is why
# the boot run's env snapshot is deliberately NOT consulted for it: it is
# written by the unprivileged user, and it lives under the very HOME resolution
# has not determined yet. See docs/troubleshooting/case-sensitive-filesystems.md.
AS_USER=false
case "${1:-}" in
    --as-user)
        AS_USER=true
        shift
        ;;
    "") ;;
    *)
        command echo "workspace-fs-health-cron: unknown argument '$1'" >&2
        exit 2
        ;;
esac

if [ "$AS_USER" != "true" ] && [ "$(id -u)" -eq 0 ]; then
    if [ ! -f "$FS_HEALTH_RESOLVE_USER_LIB" ]; then
        exit 0
    fi

    # Source the root-owned container env BEFORE resolving, so a CONTAINER_UID
    # exported there reaches the ladder's first arm. Sourcing it only after the
    # re-exec (as the second pass does, for HOME/PATH) would leave that arm
    # permanently dead under cron and silently demote every run to the shape
    # match.
    if [ -f "$CRON_ENV_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CRON_ENV_FILE"
    fi

    # shellcheck source=/dev/null
    source "$FS_HEALTH_RESOLVE_USER_LIB"

    _fs_health_user=""
    if declare -f resolve_container_user >/dev/null 2>&1; then
        _fs_health_user=$(resolve_container_user) || true
    fi

    # No resolvable user is the same class of situation as no snapshot: this
    # leg does not guess, it stays silent. A wrong guess would run the repair's
    # git-config and ln -sfn writes as the wrong owner inside the project.
    if [ -z "$_fs_health_user" ]; then
        exit 0
    fi

    exec "$FS_HEALTH_SU" -l "$_fs_health_user" -c "$(command printf '%q %q' "$0" --as-user)"
fi

# Container environment (PATH, HOME, ...). Sourced first so the snapshot path
# below resolves against the same HOME the boot run used.
if [ -f "$CRON_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CRON_ENV_FILE"
fi

FS_HEALTH_ENV_FILE="${FS_HEALTH_ENV_FILE:-${HOME:-/tmp}/.cache/container/fs-health.env}"

if [ ! -f "$FS_HEALTH_ENV_FILE" ]; then
    exit 0
fi

if [ ! -x "$FS_HEALTH_SCRIPT" ] && [ ! -f "$FS_HEALTH_SCRIPT" ]; then
    exit 0
fi

# Read the snapshot with a restricted parser rather than `source`ing it.
# Sourcing would execute whatever the file contains, which makes every value in
# it a code path; this only ever yields strings. Accepts exactly the two
# single-quoted KEY='value' lines the writer emits, and unescapes the '\''
# idiom it uses for embedded quotes.
snapshot_value() {
    local key="$1" line
    line=$(/usr/bin/grep -m1 -E "^${key}='.*'$" "$FS_HEALTH_ENV_FILE" 2>/dev/null) || return 0
    line="${line#"${key}='"}"
    line="${line%\'}"
    # Reverse the writer's '\'' escaping.
    command printf '%s' "${line//\'\\\'\'/\'}"
}

PROJECT_ROOT=$(snapshot_value PROJECT_ROOT)
WORKSPACE_ROOT=$(snapshot_value WORKSPACE_ROOT)
SKIP_CASE_FIX=$(snapshot_value SKIP_CASE_FIX)

# A snapshot naming NEITHER root is malformed — treat it like no snapshot rather
# than falling back to cron's $PWD (the user's home).
if [ -z "${PROJECT_ROOT:-}" ] && [ -z "${WORKSPACE_ROOT:-}" ]; then
    exit 0
fi

# Which root is exported decides the scope the repair script resolves, and the
# script keys on whether PROJECT_ROOT is SET at all — so exporting it empty
# would pin single scope on the empty path. Export exactly one (issue #828).
#
# A non-empty PROJECT_ROOT wins. That is the on-demand/single case, and it is
# also what a snapshot written by an OLDER image looks like: it has no
# WORKSPACE_ROOT line at all, so honoring PROJECT_ROOT keeps the hourly leg
# working across an upgrade until the next boot rewrites the snapshot.
#
# Otherwise the boot run was workspace-scoped, and this leg re-discovers repos
# under WORKSPACE_ROOT on every pass rather than repairing a list fixed at boot.
# That is what picks up a repo mounted into a running container.
if [ -n "${PROJECT_ROOT:-}" ]; then
    export PROJECT_ROOT
else
    export WORKSPACE_ROOT
fi

export SKIP_CASE_FIX="${SKIP_CASE_FIX:-false}"

# The snapshot is the boot run's to maintain. This leg reads it and must not
# rewrite it from cron's environment.
export FS_HEALTH_UPDATE_ENV=false

exec /bin/bash "$FS_HEALTH_SCRIPT"
