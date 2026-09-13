#!/usr/bin/env bash
# Unit tests for .github/workflows/stale-status-labels.yml sweep logic.
#
# Background (issue #885): `status/*` labels are applied when work starts
# (`status/in-progress`), when a PR opens (`status/pr-pending`), or on the
# commit-only route (`status/commit-pending`), and the squash commit's
# `Closes #N` trailer then closes the issue with the label still attached.
# /workflow:ship-issue clears them only when ship itself performs the merge, so
# a PR merged out of band leaves the label forever. Measured when this suite was
# written: 199 stale labels across 199 closed issues, some carried since April
# 2026. Beyond triage noise, /workflow:next-issue excludes those labels from
# priority selection, so a REOPENED issue wearing one is silently skipped.
#
# Testing approach: identical to tests/unit/issue-labeler.sh (#883), which is
# this repo's precedent for testing a script embedded in workflow YAML. yq pulls
# the script body out of the YAML and node runs it against recording stubs for
# the `github` / `context` / `core` globals that actions/github-script injects.
#
# ONE FIDELITY POINT CARRIES THIS WHOLE SUITE. The sweep's safety predicate is
# the `state: 'closed'` argument to listForRepo — it lives in the API QUERY, not
# in a branch of the script. A `paginate` stub that returned its fixture
# verbatim would make every open-issue assertion vacuous: the script would
# "pass" for the sole reason that the test never handed it an open issue. So the
# stub below FILTERS the fixture by the `state` argument the script actually
# passes, exactly as the real endpoint does. That is what gives
# test_open_issue_untouched and the AC6 mutation guard their teeth.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "stale-status-labels workflow sweep logic"

WORKFLOW="$PROJECT_ROOT/.github/workflows/stale-status-labels.yml"

# Scratch lives outside the repo (#821) — the bindfs/virtiofs stack this repo is
# commonly mounted through loses write-then-read coherency, and these tests
# write a fixture then immediately execute it.
SCRATCH="$TEST_SCRATCH_BASE/stale-status-labels"

# Skip locally, FAIL in CI.
#
# A silently-skipped check renders identically to a pass in the summary, so the
# gap this suite exists to close would sit un-executed on every run (#768).
# Both yq and node ship in the dev-tools feature and are present in CI.
require_tool_in_ci() {
    local reason="$1"
    if [ "${CI:-false}" = "true" ]; then
        fail_test "$reason — required in CI, cannot silently skip"
    else
        skip_test "$reason"
    fi
}

tools_available() {
    command -v yq >/dev/null 2>&1 && command -v node >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# Extract the github-script body from the workflow into $SCRATCH/script.js.
extract_script() {
    command mkdir -p "$SCRATCH"
    yq '.jobs.sweep.steps[0].with.script' "$WORKFLOW" >"$SCRATCH/script.js"
    # yq prints the literal string "null" for a missing path; a silent empty
    # script would make every assertion below vacuously pass.
    if [ ! -s "$SCRATCH/script.js" ] ||
        [ "$(command head -c 4 "$SCRATCH/script.js")" = "null" ]; then
        return 1
    fi
}

# Run the extracted script against stubs and print one line per recorded API
# call, in the form "removeLabel <issue>/<label>":
#
#   removeLabel 100/status/pr-pending
#   removeLabel 101/status/in-progress
#
# $1 = path to the script to run (lets the non-vacuity test run a mutated copy)
# $2 = JSON array of issue fixtures, each { number, state, labels, pull_request? }
#
# The script is wrapped in an async IIFE because actions/github-script does the
# same: that is what makes the script's top-level `await` legal.
run_script() {
    local script_path="$1" fixture="$2"
    local runner="$SCRATCH/run.mjs"

    command mkdir -p "$SCRATCH"
    command cat >"$runner" <<'RUNNER_EOF'
import { readFileSync } from 'node:fs';

const [scriptPath, fixtureJson] = process.argv.slice(2);
const fixture = JSON.parse(fixtureJson);
const calls = [];

// Minimal stand-ins for the globals actions/github-script injects.
const github = {
  rest: {
    issues: {
      // Referenced by the script as a function VALUE handed to paginate, never
      // invoked directly — paginate below is what actually resolves it.
      listForRepo: () => {},
      removeLabel: async ({ issue_number, name }) => {
        const issue = fixture.find((i) => i.number === issue_number);
        const labels = issue ? issue.labels.map((l) => l.name) : [];
        // The real endpoint 404s when the label is not on the issue. Modeling
        // that is what makes the idempotency test meaningful: a second sweep
        // over an already-swept issue must absorb the 404, not blow up.
        if (!labels.includes(name)) {
          const err = new Error(`Label does not exist: ${name}`);
          err.status = 404;
          throw err;
        }
        calls.push(`removeLabel ${issue_number}/${name}`);
      },
    },
  },
  // Honour the `state` filter the script passes, exactly as the real endpoint
  // does. Returning the fixture verbatim here would make every open-issue
  // assertion in this suite vacuous — see the header note.
  paginate: async (_endpoint, params) => {
    const state = params.state || 'open';
    if (state === 'all') return fixture;
    return fixture.filter((i) => i.state === state);
  },
};

const context = { repo: { owner: 'joshjhall', repo: 'containers' } };
const core = { info: () => {} };

const source = readFileSync(scriptPath, 'utf8');
const run = new Function(
  'github', 'context', 'core',
  `return (async () => { ${source} })();`,
);
await run(github, context, core);
process.stdout.write(calls.join('\n'));
RUNNER_EOF

    node "$runner" "$script_path" "$fixture"
}

# Assert a "removeLabel <issue>/<label>" line is / is not among the recorded
# calls.
assert_called() {
    local calls="$1" needle="$2" message="$3"
    if ! command printf '%s\n' "$calls" | command grep -qxF "$needle"; then
        fail_test "$message (recorded calls: ${calls//$'\n'/ | })"
    fi
}

assert_not_called() {
    local calls="$1" needle="$2" message="$3"
    if command printf '%s\n' "$calls" | command grep -qxF "$needle"; then
        fail_test "$message (recorded calls: ${calls//$'\n'/ | })"
    fi
}

# A closed issue carrying every sweepable label, plus a terminal marker and an
# ordinary taxonomy label that must both survive.
CLOSED_ISSUES='[
  {"number":100,"state":"closed","labels":[{"name":"status/pr-pending"},{"name":"type/bug"}]},
  {"number":101,"state":"closed","labels":[{"name":"status/in-progress"}]},
  {"number":102,"state":"closed","labels":[{"name":"status/commit-pending"}]},
  {"number":103,"state":"closed","labels":[{"name":"status/on-hold"},{"name":"status/blocked"}]},
  {"number":104,"state":"closed","labels":[{"name":"status/complete"},{"name":"severity/low"}]}
]'

# Open issues carrying labels that are LEGITIMATE while the issue is open. 54
# real open issues were in this state when the sweep was written.
OPEN_ISSUES='[
  {"number":200,"state":"open","labels":[{"name":"status/in-progress"}]},
  {"number":201,"state":"open","labels":[{"name":"status/pr-pending"}]},
  {"number":202,"state":"open","labels":[{"name":"status/on-hold"}]}
]'

# Mixed, as the repo actually looks.
MIXED_ISSUES='[
  {"number":100,"state":"closed","labels":[{"name":"status/pr-pending"}]},
  {"number":200,"state":"open","labels":[{"name":"status/in-progress"}]},
  {"number":300,"state":"closed","labels":[{"name":"status/commit-pending"}],"pull_request":{"url":"https://api.github.com/pr/300"}}
]'

# Already swept — nothing left to remove.
SWEPT_ISSUES='[
  {"number":100,"state":"closed","labels":[{"name":"type/bug"}]},
  {"number":104,"state":"closed","labels":[{"name":"status/complete"}]}
]'

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# AC1: a closed issue carrying status/pr-pending has it removed.
test_closed_pr_pending_removed() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES")
    assert_called "$calls" "removeLabel 100/status/pr-pending" \
        "closed issue kept its stale status/pr-pending label (#885 AC1)"
}

# AC2: a closed issue carrying status/in-progress has it removed.
test_closed_in_progress_removed() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES")
    assert_called "$calls" "removeLabel 101/status/in-progress" \
        "closed issue kept its stale status/in-progress label (#885 AC2)"
}

# The largest group (98 issues) and the one the issue body never measured.
# Same root cause: applied by ship's commit-only path, cleared on no path a
# merged-out-of-band issue reaches.
test_closed_commit_pending_removed() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES")
    assert_called "$calls" "removeLabel 102/status/commit-pending" \
        "closed issue kept its stale status/commit-pending label"
}

# Both remaining sweepable labels come off, and both come off the SAME issue —
# guards against a `break`-after-first-match regression.
test_closed_on_hold_and_blocked_removed() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES")
    assert_called "$calls" "removeLabel 103/status/on-hold" \
        "closed issue kept its stale status/on-hold label"
    assert_called "$calls" "removeLabel 103/status/blocked" \
        "second stale label on the same issue was not removed"
}

# AC3: the live-work guard. An OPEN issue carrying any sweepable label must be
# left alone — #948 and the 54 open on-hold/blocked issues are live examples.
# This is only meaningful because the paginate stub honours `state` (header).
test_open_issue_untouched() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$OPEN_ISSUES")
    if [ -n "$calls" ]; then
        fail_test "sweep removed a label from an OPEN issue — this clears live work (#885 AC3): ${calls//$'\n'/ | }"
    fi
}

# The same guard in the realistic mixed case: the closed issue is swept while
# the open one beside it is not.
test_mixed_sweeps_only_closed() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$MIXED_ISSUES")
    assert_called "$calls" "removeLabel 100/status/pr-pending" \
        "closed issue was not swept in a mixed batch"
    assert_not_called "$calls" "removeLabel 200/status/in-progress" \
        "open issue was swept in a mixed batch (#885 AC3)"
}

# listForRepo returns pull requests as issues. PRs carry their own label
# lifecycle and are out of scope for this sweep.
test_pull_requests_skipped() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$MIXED_ISSUES")
    assert_not_called "$calls" "removeLabel 300/status/commit-pending" \
        "sweep touched a pull request — listForRepo returns PRs as issues"
}

# Scope decision: status/complete is the one status label that stays TRUE once
# an issue closes, so it must survive.
test_status_complete_kept() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES")
    assert_not_called "$calls" "removeLabel 104/status/complete" \
        "sweep stripped status/complete, which is correct on a closed issue"
}

# The sweep must not over-reach into other label namespaces.
test_non_status_labels_kept() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES")
    assert_not_called "$calls" "removeLabel 100/type/bug" \
        "sweep removed a type/* label"
    assert_not_called "$calls" "removeLabel 104/severity/low" \
        "sweep removed a severity/* label"
}

# AC4: idempotency. A second run over an already-swept set is a clean no-op —
# it must neither record removals nor throw on the 404 the real endpoint
# returns for an absent label.
test_second_run_is_noop() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$SWEPT_ISSUES" 2>&1); then
        fail_test "second run over an already-swept set threw: $calls"
        return
    fi
    if [ -n "$calls" ]; then
        fail_test "second run over an already-swept set was not a no-op: ${calls//$'\n'/ | }"
    fi
}

# AC6 — non-vacuity. Neuter the closed-state predicate in the extracted script
# and assert the bug appears: the sweep must then strip labels from OPEN issues.
# Without this guard, every assertion above could pass against a script that
# never constrains the query by state at all.
test_check_is_non_vacuous() {
    local mutant="$SCRATCH/script-mutant.js"
    # `state: 'all'` is what the predicate is protecting against — the query
    # that returns open issues alongside closed ones.
    command sed -e "s|state: 'closed'|state: 'all'|" \
        "$SCRATCH/script.js" >"$mutant"

    if command cmp -s "$SCRATCH/script.js" "$mutant"; then
        fail_test "mutation was a no-op — the closed-state predicate was not found in the extracted script, so this guard proves nothing"
        return
    fi

    local calls
    calls=$(run_script "$mutant" "$OPEN_ISSUES")
    assert_called "$calls" "removeLabel 200/status/in-progress" \
        "mutant did NOT reinstate the bug — the closed-state predicate is not what protects open issues, so the real tests are vacuous"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# These two preflight checks are driven manually rather than through run_test
# because a failure must abort the suite outright — there is nothing to test
# without the workflow file and its extracted script. run_test resets
# TEST_STATUS per case; doing it by hand here keeps both from collapsing into
# one counted result.
# shellcheck disable=SC2034  # Read by the framework's pass_test/fail_test
TEST_STATUS=""
test_case "workflow file exists"
if [ -f "$WORKFLOW" ]; then
    pass_test
else
    fail_test "$WORKFLOW not found"
    generate_report
    exit 1
fi

# shellcheck disable=SC2034  # Read by the framework's pass_test/fail_test
TEST_STATUS=""
if ! tools_available; then
    test_case "extract embedded github-script"
    require_tool_in_ci "yq and node are required to test the embedded script"
    generate_report
    exit 0
fi

test_case "extract embedded github-script"
if extract_script; then
    pass_test
else
    fail_test "could not extract .jobs.sweep.steps[0].with.script from $WORKFLOW"
    generate_report
    exit 1
fi

run_test test_closed_pr_pending_removed \
    "closed issue has status/pr-pending removed"
run_test test_closed_in_progress_removed \
    "closed issue has status/in-progress removed"
run_test test_closed_commit_pending_removed \
    "closed issue has status/commit-pending removed"
run_test test_closed_on_hold_and_blocked_removed \
    "closed issue has both on-hold and blocked removed"
run_test test_open_issue_untouched \
    "open issue carrying a status label is left untouched"
run_test test_mixed_sweeps_only_closed \
    "mixed batch sweeps the closed issue and spares the open one"
run_test test_pull_requests_skipped \
    "pull requests returned by listForRepo are skipped"
run_test test_status_complete_kept \
    "status/complete survives on a closed issue"
run_test test_non_status_labels_kept \
    "type/* and severity/* labels are not touched"
run_test test_second_run_is_noop \
    "second run over an already-swept set is a clean no-op"
run_test test_check_is_non_vacuous \
    "removing the closed-state predicate reinstates the bug"

command rm -rf "$SCRATCH"

generate_report
