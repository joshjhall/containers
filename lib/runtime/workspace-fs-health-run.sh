#!/bin/bash
# workspace-fs-health — run the workspace filesystem repair on demand
#
# The same repair the container runs at boot and hourly from cron (issue #794),
# exposed as a command for the moments where staleness actually bites: symlinks
# showing as modified in `git status` right before a commit, or a repo just
# opened on a case-insensitive mount.
#
# Inspects the current directory's project by default; pass a path to inspect a
# different one. Either way this command is SINGLE-SCOPE: it restricts the run
# to one repo, unlike the boot and cron legs, which scan every repo under the
# workspace root (issue #828).
#
# Silent when the workspace is healthy — any output means it repaired
# something. Honors SKIP_CASE_FIX=true (report only) and SKIP_CASE_CHECK=true
# (do nothing) exactly as the boot run does.

set -uo pipefail

FS_HEALTH_SCRIPT="${FS_HEALTH_SCRIPT:-/etc/container/startup/42-workspace-fs-health.sh}"

if [ ! -f "$FS_HEALTH_SCRIPT" ]; then
    echo "workspace-fs-health: repair script not found at $FS_HEALTH_SCRIPT" >&2
    exit 1
fi

case "${1:-}" in
    -h | --help)
        echo "Usage: workspace-fs-health [PROJECT_ROOT]"
        echo ""
        echo "Repair workspace filesystem damage from the host mount:"
        echo "  - align git core.ignorecase on case-insensitive mounts"
        echo "  - refresh symlinks with stale attributes (nlink=0)"
        echo ""
        echo "Inspects the current directory's project. Pass a path to inspect a"
        echo "different one; either way the run is restricted to that single repo,"
        echo "not the whole workspace. Silent when healthy."
        echo ""
        echo "Environment:"
        echo "  SKIP_CASE_FIX=true    detect and report, but never write"
        echo "  SKIP_CASE_CHECK=true  do nothing"
        exit 0
        ;;
    "")
        # Pin the current directory EXPLICITLY (issue #828). The repair script's
        # default scope is now the whole workspace, and it distinguishes the two
        # by whether PROJECT_ROOT is set — so leaving it unset here would
        # silently turn a bare `workspace-fs-health` into a workspace-wide scan
        # rather than the "current directory's project" this command documents.
        PROJECT_ROOT="$PWD"
        export PROJECT_ROOT
        ;;
    *)
        if [ ! -d "$1" ]; then
            echo "workspace-fs-health: not a directory: $1" >&2
            exit 1
        fi
        PROJECT_ROOT="$1"
        export PROJECT_ROOT
        ;;
esac

# The env snapshot describes the BOOT run's project and belongs to it. An
# ad-hoc run from an arbitrary directory must not redirect the hourly cron leg
# at whatever the user happened to `cd` into.
export FS_HEALTH_UPDATE_ENV=false

exec /bin/bash "$FS_HEALTH_SCRIPT"
