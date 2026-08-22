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
# Cron jobs inherit none of the container environment, so the two values that
# cannot be re-derived here — which project to inspect, and whether the user
# opted out of writes — are read from the snapshot the boot run recorded.
# No snapshot means "do not run": either SKIP_CASE_CHECK=true was set, no repo
# was mounted, or the boot script never ran. All three should be silent no-ops
# rather than a guess at PROJECT_ROOT (under cron, $PWD is the user's home).

set -uo pipefail

FS_HEALTH_SCRIPT="${FS_HEALTH_SCRIPT:-/etc/container/startup/42-workspace-fs-health.sh}"
CRON_ENV_FILE="${CRON_ENV_FILE:-/etc/container/cron-env}"

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

# shellcheck source=/dev/null
source "$FS_HEALTH_ENV_FILE"

# A snapshot without a project root is malformed — treat it like no snapshot
# rather than falling back to cron's $PWD.
if [ -z "${PROJECT_ROOT:-}" ]; then
    exit 0
fi

export PROJECT_ROOT
export SKIP_CASE_FIX="${SKIP_CASE_FIX:-false}"

# The snapshot is the boot run's to maintain. This leg reads it and must not
# rewrite it from cron's environment.
export FS_HEALTH_UPDATE_ENV=false

exec /bin/bash "$FS_HEALTH_SCRIPT"
