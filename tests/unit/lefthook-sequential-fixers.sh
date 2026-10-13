#!/usr/bin/env bash
# Unit tests for sequential stage_fixed hooks in lefthook.yml (issue #1114).
#
# Background: pre-commit ran every hook with `parallel: true`, and eight of
# them were `stage_fixed: true`. Each one re-stages its output with
# `git add`, which takes .git/index.lock — so two fixers touching files at
# once collided with each other or with the commit, failing with "Unable to
# create .git/index.lock: File exists" and leaving a stale lock behind.
#
# The fix groups the fixers into a `parallel: false` job group that runs
# before the (still parallel) read-only checks. These assertions pin that
# shape: no stage_fixed hook may be reachable from anything that runs
# concurrently. Structural by necessity — reproducing the race needs every
# fixer binary installed and real scheduler contention.

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "lefthook sequential fixers (#1114)"

LEFTHOOK="${LEFTHOOK_FILE:-$PROJECT_ROOT/lefthook.yml}"

# Mirrors tests/unit/lefthook-optional-tools.sh.
if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not available — install yq to run lefthook-sequential-fixers tests"
    generate_report
    exit 0
fi

# Names of stage_fixed hooks that can run concurrently with something else:
#   - any stage_fixed hook under a stage whose top level is `parallel: true`
#     (that runs every job/command, groups included, side by side), and
#   - any stage_fixed job directly inside a `parallel: true` group.
concurrent_fixers() {
    yq -r '
        [ (.[] | select(tag == "!!map" and .parallel == true)
               | .. | select(tag == "!!map" and .stage_fixed == true)
               | (.name // "<command>")),
          (.. | select(tag == "!!map" and has("group")) | .group
              | select(.parallel == true) | .jobs[]
              | select(.stage_fixed == true) | .name)
        ] | unique | .[]' "$LEFTHOOK"
}

test_no_fixer_runs_concurrently() {
    local found
    found=$(concurrent_fixers | /usr/bin/tr '\n' ' ')
    assert_equals "" "$found" \
        "stage_fixed hooks must not run in parallel — they race on .git/index.lock (#1114)"
}

# Guards against the check above passing vacuously (e.g. the fixers renamed
# away or stage_fixed dropped): pre-commit must still have its fixers.
test_pre_commit_still_has_fixers() {
    local n
    n=$(yq -r '[."pre-commit" | .. | select(tag == "!!map" and .stage_fixed == true)] | length' "$LEFTHOOK")
    assert_equals "8" "$n" "pre-commit must keep its 8 stage_fixed fixers"
}

run_test test_no_fixer_runs_concurrently "no stage_fixed hook runs concurrently"
run_test test_pre_commit_still_has_fixers "pre-commit keeps its stage_fixed fixers"

generate_report
