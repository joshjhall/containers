#!/usr/bin/env bash
# Unit tests: every GitHub Actions job is time-bounded (issue #987).
#
# Background: a job with no `timeout-minutes` inherits the 6-hour runner cap.
# On 2026-09-20 a wedged Docker daemon hung `docker version` inside
# setup-buildx-resilient for those full 6 hours and cancelled the auto-patch
# release; the wrapper's retry never fired because a hang is not a failure.
#
# Three layers are checked:
#   1. every job declares a positive integer `timeout-minutes` (a job that
#      calls a reusable workflow via `uses:` cannot, and is exempt);
#   2. every step using setup-buildx-resilient sets its own step-level
#      `timeout-minutes` — composite-action steps cannot bound themselves;
#   3. the action's daemon probe is wrapped in `timeout`, so a hang becomes a
#      failure that the retry can see.
#
# The checker is run against committed-shape fixtures as well as the real
# workflows, so each layer is shown to FAIL on the defect it exists for.
#
# Scope: parses YAML only — offline, safe under SKIP_NETWORK_TESTS=1.
#
# Run via: ./tests/run_unit_tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Workflow timeouts"

if ! command -v yq >/dev/null 2>&1; then
    echo "SKIP: yq not available — install yq to run workflow-timeouts tests"
    exit 0
fi

WORKFLOWS_DIR="$PROJECT_ROOT/.github/workflows"
BUILDX_ACTION="$PROJECT_ROOT/.github/actions/setup-buildx-resilient/action.yml"

# jobs_without_timeout FILE — prints "FILE:job" for each non-reusable job whose
# timeout-minutes is absent or not a positive integer.
jobs_without_timeout() {
    local file="$1"
    yq -r '
        .jobs // {} | to_entries[]
        | select(.value.uses == null)
        | select((.value["timeout-minutes"] // "" | tostring | test("^[1-9][0-9]*$")) | not)
        | .key
    ' "$file" | command sed "s|^|$(command basename "$file"):|"
}

# buildx_steps_without_timeout FILE — prints "FILE:job" for each step using
# setup-buildx-resilient that has no step-level timeout-minutes.
buildx_steps_without_timeout() {
    local file="$1"
    # Project each step to {job, uses, timeout} BEFORE filtering: mikefarah yq
    # evaluates a select() after a `.key as $job` binding across every job's
    # steps, so the naive form reports the bounded job too.
    yq -r '
        [.jobs // {} | to_entries[]
            | .key as $job
            | (.value.steps // [])[]
            | {"job": $job, "uses": (.uses // ""), "timeout": .["timeout-minutes"]}]
        | .[]
        | select(.uses == "./.github/actions/setup-buildx-resilient" and .timeout == null)
        | .job
    ' "$file" | command sed "s|^|$(command basename "$file"):|"
}

# ---------------------------------------------------------------------------
# Checker self-tests on fixtures (prove each check can fail)
# ---------------------------------------------------------------------------

test_checker_flags_missing_timeout() {
    local dir
    dir=$(command mktemp -d)
    command cat >"$dir/fixture.yml" <<'EOF'
jobs:
  bounded:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps: [{run: "true"}]
  unbounded:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
  expression:
    runs-on: ubuntu-latest
    timeout-minutes: 0
    steps: [{run: "true"}]
  reusable:
    uses: ./.github/workflows/other.yml
EOF
    local got
    got=$(jobs_without_timeout "$dir/fixture.yml" | command tr '\n' ' ')
    command rm -rf "$dir"
    assert_equals "fixture.yml:unbounded fixture.yml:expression " "$got" \
        "checker flags missing and zero timeouts, exempts reusable-workflow jobs"
}

test_checker_flags_unbounded_buildx_step() {
    local dir
    dir=$(command mktemp -d)
    command cat >"$dir/fixture.yml" <<'EOF'
jobs:
  good:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: ./.github/actions/setup-buildx-resilient
        timeout-minutes: 10
  bad:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: ./.github/actions/setup-buildx-resilient
EOF
    local got
    got=$(buildx_steps_without_timeout "$dir/fixture.yml")
    command rm -rf "$dir"
    assert_equals "fixture.yml:bad" "$got" "checker flags a buildx step with no step timeout"
}

# ---------------------------------------------------------------------------
# The real tree
# ---------------------------------------------------------------------------

test_every_job_has_timeout() {
    local file missing="" count=0
    for file in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
        [ -f "$file" ] || continue
        count=$((count + 1))
        missing+=$(jobs_without_timeout "$file")
    done
    # Zero files scanned would read as "nothing missing".
    if [ "$count" -eq 0 ]; then
        assert_true false "no workflow files found under $WORKFLOWS_DIR"
    elif [ -n "$missing" ]; then
        command echo "  jobs inheriting the 6h default:"
        command echo "$missing" | command sed 's/^/    /'
        assert_true false "every workflow job declares timeout-minutes"
    else
        assert_true true "all jobs in $count workflows declare timeout-minutes"
    fi
}

test_buildx_call_sites_bounded() {
    local file missing="" sites=0
    for file in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
        [ -f "$file" ] || continue
        sites=$((sites + $(command grep -c 'uses: ./.github/actions/setup-buildx-resilient' "$file" || true)))
        missing+=$(buildx_steps_without_timeout "$file")
    done
    if [ "$sites" -eq 0 ]; then
        assert_true false "no setup-buildx-resilient call sites found — check the path"
    elif [ -n "$missing" ]; then
        command echo "  unbounded setup-buildx-resilient steps: $missing"
        assert_true false "every setup-buildx-resilient step sets timeout-minutes"
    else
        assert_true true "all $sites setup-buildx-resilient steps set timeout-minutes"
    fi
}

test_buildx_action_probes_daemon_with_timeout() {
    # The probe must be the FIRST step and time-bounded: anything that touches
    # the daemon before it can still hang unbounded.
    local first
    first=$(yq -r '.runs.steps[0].run // ""' "$BUILDX_ACTION")
    if command grep -qE 'timeout .*docker version' <<<"$first"; then
        assert_true true "setup-buildx-resilient probes the daemon under timeout first"
    else
        assert_true false "setup-buildx-resilient's first step is not a timeout-bounded docker probe"
    fi
}

run_test test_checker_flags_missing_timeout "Checker flags jobs without a timeout"
run_test test_checker_flags_unbounded_buildx_step "Checker flags an unbounded buildx step"
run_test test_every_job_has_timeout "Every workflow job declares timeout-minutes"
run_test test_buildx_call_sites_bounded "Every setup-buildx-resilient step is bounded"
run_test test_buildx_action_probes_daemon_with_timeout "Buildx action probes the daemon under timeout"

generate_report
