#!/usr/bin/env bash
# Unit tests: every GitHub Actions job is time-bounded (issue #987).
#
# Background: a job with no `timeout-minutes` inherits the 6-hour runner cap.
# On 2026-09-20 a wedged Docker daemon hung `docker version` inside
# setup-buildx-resilient for those full 6 hours and cancelled the auto-patch
# release; the wrapper's retry never fired because a hang is not a failure.
#
# Three layers are checked:
#   1. every job declares a bounded `timeout-minutes` (a job that calls a
#      reusable workflow via `uses:` cannot, and is exempt). Bounded means a
#      positive integer literal, or exactly `${{ <cond> && N || M }}` with N
#      and M positive integer literals and a <cond> holding no `&`, `|` or
#      parentheses (#1569). A GitHub expression of that form can only yield N
#      (cond truthy) or M (cond falsy or unset), whatever the matrix holds, so
#      it is bounded by max(N, M) without the checker seeing the matrix. A
#      bare `${{ matrix.x }}` is NOT accepted: its value comes from data the
#      checker cannot see, and an empty one falls back to the 6h default;
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

# BOUNDED_TIMEOUT_RE — the timeout-minutes values accepted as bounded (see the
# header): a positive integer literal, or `${{ <cond> && N || M }}`. <cond> is
# one run of characters with no `&`, `|`, `(`, `)`, `{` or `}`, so a chained
# `a && N || b && X || M` or a parenthesised sub-expression cannot slip in a
# third, unbounded operand. N and M reject 0 (`timeout-minutes: 0` is no bound).
BOUNDED_TIMEOUT_RE='^([1-9][0-9]*|\$\{\{ *[^&|(){}]+ *&& *[1-9][0-9]* *\|\| *[1-9][0-9]* *\}\})$'

# jobs_without_timeout FILE — prints "FILE:job" for each non-reusable job whose
# timeout-minutes is absent or not bounded (BOUNDED_TIMEOUT_RE).
jobs_without_timeout() {
    local file="$1" job value
    # Raw value per job, matched in bash: yq's regex dialect differs across
    # releases, and the exact accepted shape is what this guard asserts.
    while IFS=$'\t' read -r job value; do
        [[ "$value" =~ $BOUNDED_TIMEOUT_RE ]] || command echo "$(command basename "$file"):$job"
    done < <(yq -r '
        .jobs // {} | to_entries[]
        | select(.value.uses == null)
        | .key + "\t" + (.value["timeout-minutes"] // "" | tostring)
    ' "$file")
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

test_checker_bounds_matrix_expressions() {
    # #1569: a per-cell timeout must stay provably bounded. Only the
    # `${{ cond && N || M }}` shape is accepted; anything that can yield an
    # unseen value (or an empty one, i.e. the 6h default) is flagged.
    local dir
    dir=$(command mktemp -d)
    command cat >"$dir/fixture.yml" <<'YAML'
jobs:
  ternary:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ matrix.source_build && 120 || 30 }}
    steps: [{run: "true"}]
  ternary_tight:
    runs-on: ubuntu-latest
    timeout-minutes: ${{matrix.slow&&90||20}}
    steps: [{run: "true"}]
  bare_matrix:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ matrix.timeout_minutes }}
    steps: [{run: "true"}]
  matrix_fallback:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ matrix.slow && matrix.minutes || 30 }}
    steps: [{run: "true"}]
  zero_branch:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ matrix.slow && 0 || 30 }}
    steps: [{run: "true"}]
  chained:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ matrix.a && 120 || matrix.b && 9999 || 30 }}
    steps: [{run: "true"}]
  nested:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ (matrix.a || matrix.b) && 120 || 30 }}
    steps: [{run: "true"}]
  grouped:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ (matrix.slow) && 120 || 30 }}
    steps: [{run: "true"}]
  from_json:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ fromJSON(needs.setup.outputs.minutes) }}
    steps: [{run: "true"}]
YAML
    local got
    got=$(jobs_without_timeout "$dir/fixture.yml" | command tr '\n' ' ')
    command rm -rf "$dir"
    assert_equals "fixture.yml:bare_matrix fixture.yml:matrix_fallback fixture.yml:zero_branch fixture.yml:chained fixture.yml:nested fixture.yml:grouped fixture.yml:from_json " \
        "$got" "only a literal-branched cond && N || M is accepted as bounded"
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
    # The bound must be a positive duration: `timeout 0` disables the limit.
    local first
    first=$(yq -r '.runs.steps[0].run // ""' "$BUILDX_ACTION")
    if command grep -qE 'timeout( -k [0-9]+)? [1-9][0-9]*[smh]? docker version' <<<"$first"; then
        assert_true true "setup-buildx-resilient probes the daemon under timeout first"
    else
        assert_true false "setup-buildx-resilient's first step is not a timeout-bounded docker probe"
    fi
}

run_test test_checker_flags_missing_timeout "Checker flags jobs without a timeout"
run_test test_checker_bounds_matrix_expressions "Checker accepts only provably bounded timeout expressions"
run_test test_checker_flags_unbounded_buildx_step "Checker flags an unbounded buildx step"
run_test test_every_job_has_timeout "Every workflow job declares timeout-minutes"
run_test test_buildx_call_sites_bounded "Every setup-buildx-resilient step is bounded"
run_test test_buildx_action_probes_daemon_with_timeout "Buildx action probes the daemon under timeout"

generate_report
