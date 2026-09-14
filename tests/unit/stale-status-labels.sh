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
# TWO FIDELITY POINTS CARRY THIS WHOLE SUITE.
#
# 1. The sweep's safety predicate is the `state: 'closed'` argument to
#    listForRepo — it lives in the API QUERY, not in a branch of the script. A
#    `paginate` stub that returned its fixture verbatim would make every
#    open-issue assertion vacuous: the script would "pass" for the sole reason
#    that the test never handed it an open issue. So the stub below FILTERS the
#    fixture by the `state` argument the script actually passes, exactly as the
#    real endpoint does. That is what gives test_open_issue_untouched and the
#    AC6 mutation guard their teeth.
#
# 2. The removeLabel error paths are UNREACHABLE from the fixture alone. The
#    script only ever removes a label it just read off the same issue in the
#    same run, so a stub deriving its 404 from that shared fixture could never
#    fire — a test claiming to cover 404 absorption would pass by never entering
#    the branch. The 404 fires in production only when a concurrent run or a
#    human removes the label between the list and the remove. So faults are
#    INJECTED independently of the fixture (the `$3` argument), which is what
#    makes the 404, rate-limit-retry, and rethrow tests real.

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
# $3 = optional removeLabel fault injection, as JSON:
#        { "vanished": ["<issue>/<label>", ...], "throttle": {"<issue>/<label>": N},
#          "fail": {"<issue>/<label>": <status>} }
#      `vanished` makes the stub 404 for a label the LIST still reported —
#      modeling the out-of-band race (a concurrent run, or a human) that is the
#      only way the script's 404 branch can fire in production. `throttle` 403s
#      the first N attempts with a secondary-rate-limit message before
#      succeeding; `fail` raises an arbitrary status that must propagate.
#
#      Both fault kinds accept a widened object form alongside the bare one:
#        throttle: 2  ==  {"count": 2, "retryAfter": 0}
#        fail: 500    ==  {"status": 500}
#      `retryAfter` sets the `retry-after` response header, which is what
#      selects between the script's two backoff paths — the bare form's 0 takes
#      the exponential fallback, a positive value takes the honour-the-header
#      branch. `message` on `fail` matters because the script CLASSIFIES 403s by
#      message (`/secondary rate limit|abuse/i`): the default
#      "injected failure 403" happens not to match, so a permissions-403 test
#      written against it would pass for an accidental reason rather than
#      because the classification is right.
#
# $4 = which recorded stream to print, `calls` (default) or `info`.
#      `core.info` output is recorded SEPARATELY from the API calls rather than
#      merged into one stream: the sweep emits its summary line unconditionally,
#      so merging would put a line into `calls` on every run and break
#      test_open_issue_untouched and test_second_run_is_noop, both of which
#      assert `calls` is empty.
#
# Fault state is deliberately SEPARATE from the paginate fixture. The script
# only ever removes a label it just read off that same fixture, so a stub
# sharing one source could never reach its own error paths — every such test
# would pass by never entering the branch it claims to cover.
#
# The script is wrapped in an async IIFE because actions/github-script does the
# same: that is what makes the script's top-level `await` legal.
run_script() {
    local script_path="$1" fixture="$2" faults="${3:-{\}}" mode="${4:-calls}"
    local runner="$SCRATCH/run.mjs"

    command mkdir -p "$SCRATCH"
    command cat >"$runner" <<'RUNNER_EOF'
import { readFileSync } from 'node:fs';

const [scriptPath, fixtureJson, faultsJson, mode] = process.argv.slice(2);
const fixture = JSON.parse(fixtureJson);
const faults = JSON.parse(faultsJson || '{}');
const vanished = new Set(faults.vanished || []);

// Normalize both fault kinds to their object form so the stub has one shape to
// read. The bare forms (`throttle: 2`, `fail: 500`) predate the widened ones
// and stay valid — every existing caller uses them.
const throttle = Object.fromEntries(
  Object.entries(faults.throttle || {}).map(([key, spec]) => [
    key,
    typeof spec === 'number'
      ? { count: spec, retryAfter: 0 }
      : { count: spec.count, retryAfter: spec.retryAfter ?? 0 },
  ]),
);
const fail = Object.fromEntries(
  Object.entries(faults.fail || {}).map(([key, spec]) => [
    key,
    typeof spec === 'number' ? { status: spec } : spec,
  ]),
);

const calls = [];
const infos = [];

// Minimal stand-ins for the globals actions/github-script injects.
const github = {
  rest: {
    issues: {
      // Referenced by the script as a function VALUE handed to paginate, never
      // invoked directly — paginate below is what actually resolves it.
      listForRepo: () => {},
      removeLabel: async ({ issue_number, name }) => {
        const key = `${issue_number}/${name}`;
        calls.push(`attempt ${key}`);

        // An arbitrary non-404 status the script must propagate rather than
        // swallow (permissions, 5xx). `message` is overridable because the
        // script classifies 403s BY message — see the run_script header.
        if (fail[key] !== undefined) {
          const { status, message } = fail[key];
          const err = new Error(message ?? `injected failure ${status}`);
          err.status = status;
          throw err;
        }

        // Secondary rate limit on the first N attempts. Shaped like the real
        // rejection: 403 whose message names the limiter.
        if (throttle[key] && throttle[key].count > 0) {
          throttle[key].count--;
          const err = new Error(
            'You have exceeded a secondary rate limit. Please wait a few minutes.',
          );
          err.status = 403;
          err.response = {
            headers: { 'retry-after': String(throttle[key].retryAfter) },
          };
          throw err;
        }

        // The label was reported by the list but is gone by the time we try to
        // remove it — a concurrent run, or a human, got there first. This is
        // the ONLY way the script's 404 branch fires in production, which is
        // why it is injected here rather than derived from the fixture.
        if (vanished.has(key)) {
          const err = new Error(`Label does not exist: ${name}`);
          err.status = 404;
          throw err;
        }

        const issue = fixture.find((i) => i.number === issue_number);
        const labels = issue ? issue.labels.map((l) => l.name) : [];
        if (!labels.includes(name)) {
          const err = new Error(`Label does not exist: ${name}`);
          err.status = 404;
          throw err;
        }
        calls.push(`removeLabel ${key}`);
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
// Recorded, not discarded: the sweep's summary line is the ONLY signal an
// operator has for how much a scheduled run actually did, so it has to be
// assertable. Kept in its own array — see the run_script header for why
// merging it into `calls` would break the empty-stream assertions.
const core = { info: (message) => infos.push(message) };

// Fake clock. The sweep deliberately paces its mutating calls ~1s apart to stay
// under GitHub's secondary rate limiter, which would make this suite sleep for
// minutes. Record each requested delay as `sleep <ms>` and resolve immediately:
// the pacing stays ASSERTABLE without being waited out.
const setTimeout = (fn, ms) => {
  calls.push(`sleep ${ms}`);
  return Promise.resolve().then(fn);
};

const source = readFileSync(scriptPath, 'utf8');
const run = new Function(
  'github', 'context', 'core', 'setTimeout',
  `return (async () => { ${source} })();`,
);
// Print the recorded streams even when the script throws. A test asserting how
// many attempts a FAILING call made needs the record, and the run that produces
// it is by definition the one that ends in a throw. The non-zero exit is
// preserved, so the tests that check only the exit code are unaffected.
//
// The error goes to STDERR, never stdout: the tests assert on stdout, so
// writing there would corrupt the recorded stream. Discarding it entirely
// would be worse than the uncaught rejection this replaced — an UNEXPECTED
// throw (a real workflow-script bug, or harness miswiring) would still fail
// the exit-code tests, but with nothing in the output saying why.
try {
  await run(github, context, core, setTimeout);
} catch (err) {
  process.exitCode = 1;
  process.stderr.write(`script threw: ${err && err.stack ? err.stack : err}\n`);
}
process.stdout.write((mode === 'info' ? infos : calls).join('\n'));
RUNNER_EOF

    node "$runner" "$script_path" "$fixture" "$faults" "$mode"
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

# AC4: idempotency, part 1. A second run over an already-swept set is a clean
# no-op — no issue carries a sweepable label, so removeLabel is never reached.
# Note what this does NOT prove: it passes by never entering the loop, so the
# 404 branch is covered separately below.
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

# AC4: idempotency, part 2 — the real 404 branch. The label is present in the
# LIST but gone by the time removeLabel runs, which is the only way the branch
# fires in production (a concurrent run, or a human, got there first). The sweep
# must absorb it and keep going rather than aborting the batch.
test_vanished_label_absorbed() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"vanished":["100/status/pr-pending"]}' 2>&1); then
        fail_test "a label that vanished between list and remove aborted the sweep: $calls"
        return
    fi
    assert_not_called "$calls" "removeLabel 100/status/pr-pending" \
        "a vanished label was counted as removed"
    # The sweep must continue past it, not stop at the first 404.
    assert_called "$calls" "removeLabel 101/status/in-progress" \
        "sweep stopped after absorbing a 404 instead of continuing"
}

# A non-404 failure is genuine — permissions, a 5xx — and must propagate rather
# than be silently swallowed. The converse of the test above: absorbing
# everything would turn a broken token into a silent no-op sweep.
test_non_404_error_propagates() {
    if run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"fail":{"100/status/pr-pending":500}}' >/dev/null 2>&1; then
        fail_test "a 500 from removeLabel was swallowed — a broken sweep would report success"
    fi
}

# Secondary rate limiting. The first backfill run fires ~200 sequential delete
# requests, which is exactly what GitHub's abuse-detection limiter targets. A
# 403 from it must be retried, not treated as fatal.
test_rate_limit_is_retried() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"throttle":{"100/status/pr-pending":2}}' 2>&1); then
        fail_test "a secondary-rate-limit 403 aborted the sweep instead of retrying: $calls"
        return
    fi
    assert_called "$calls" "removeLabel 100/status/pr-pending" \
        "sweep gave up on a throttled label instead of retrying to success"
}

# Retries are bounded — a permanently-throttled label must eventually surface
# rather than spin forever.
test_rate_limit_retries_are_bounded() {
    if run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"throttle":{"100/status/pr-pending":99}}' >/dev/null 2>&1; then
        fail_test "an endlessly-throttled label did not surface — the retry loop is unbounded"
    fi
}

# The RETRY_MAX boundary, from the passing side (#956). The two tests above
# throttle 2 times and 99 times — neither lands on RETRY_MAX (3) itself, so the
# budget's exact edge is unpinned: refactoring the guard from
# `attempt <= RETRY_MAX` to `attempt < RETRY_MAX` silently cuts it to 2 and both
# of them still pass. Exactly RETRY_MAX throttles must still succeed.
test_rate_limit_retry_max_boundary() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"throttle":{"100/status/pr-pending":3}}' 2>&1); then
        fail_test "throttling exactly RETRY_MAX times aborted the sweep — the retry budget is off by one: $calls"
        return
    fi
    assert_called "$calls" "removeLabel 100/status/pr-pending" \
        "sweep gave up at exactly RETRY_MAX throttles — the budget is one short of its documented value"
}

# The `retry-after` branch (#956). Every other throttle test sends
# `retry-after: 0`, and `0 > 0` is false, so they all take the EXPONENTIAL
# fallback — the honour-the-header path has never executed. Code that ignored
# the header, read the wrong key, or dropped the seconds-to-ms conversion would
# pass the whole suite.
test_retry_after_header_is_honoured() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"throttle":{"100/status/pr-pending":{"count":1,"retryAfter":5}}}' 2>&1); then
        fail_test "a throttle carrying retry-after aborted the sweep: $calls"
        return
    fi
    # 5 seconds -> 5000ms. Distinct from every other delay the sweep can emit.
    assert_called "$calls" "sleep 5000" \
        "retry-after: 5 did not produce a 5000ms wait — the header is ignored, or the seconds-to-ms conversion was dropped"
    # MUTATION_DELAY_MS * 2 ** 1 — what the fallback would have chosen. Its
    # presence means the header branch was skipped in favour of the backoff.
    assert_not_called "$calls" "sleep 2000" \
        "sweep took the exponential fallback despite a usable retry-after header"
}

# 403 CLASSIFICATION (#956). Throttle detection is a 403 whose message names the
# limiter; a permissions 403 ("Resource not accessible by integration") is
# terminal and must surface at once. The only other rethrow test injects a 500,
# so widening the check to a bare `err.status === 403` would go unnoticed —
# turning a broken token into three pointless retries and a delayed failure.
test_non_throttle_403_propagates() {
    local calls attempts
    if calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"fail":{"100/status/pr-pending":{"status":403,"message":"Resource not accessible by integration"}}}' 2>&1); then
        fail_test "a permissions 403 was swallowed — a sweep with a broken token would report success"
        return
    fi
    # Retried rather than rethrown is the failure this guards: the message does
    # not name the limiter, so exactly one attempt may be made.
    attempts=$(command printf '%s\n' "$calls" |
        command grep -cxF "attempt 100/status/pr-pending" || true)
    if [ "$attempts" != "1" ]; then
        fail_test "permissions 403 was retried ${attempts}x — throttle detection is matching on status alone, ignoring the message"
    fi
    assert_not_called "$calls" "sleep 2000" \
        "sweep backed off before rethrowing a non-throttle 403"
}

# The summary counters (#956). `touched` is the only signal an operator has for
# how much a scheduled run actually did, and nothing verified it was honest.
# PR #955 changed it to count issues actually MODIFIED — it previously
# incremented on `stale.length > 0`, overstating the sweep whenever every label
# on an issue turned out to be already gone.
#
# The fixture is the discriminator. Issue 101's only stale label is `vanished`,
# so it is listed-but-not-modified: 100 and 102 remove one label each and 103
# removes two (removed = 4), while 101 removes nothing (touched = 3). The
# reverted form would count 101 as well and report 4.
test_touched_counts_only_modified_issues() {
    local infos
    if ! infos=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES" \
        '{"vanished":["101/status/in-progress"]}' info 2>&1); then
        fail_test "sweep threw while counting: $infos"
        return
    fi
    if ! command printf '%s\n' "$infos" |
        command grep -qxF "Swept 4 stale label(s) from 3 closed issue(s)."; then
        fail_test "summary miscounted — an issue whose only stale label had already vanished was counted as touched, overstating the sweep (reported: ${infos//$'\n'/ | })"
    fi
}

# The sweep paces its mutating calls to stay under the secondary rate limiter.
# Without this the ~200-call backfill is squarely in what that limiter catches.
test_mutations_are_paced() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$CLOSED_ISSUES")
    if ! command printf '%s\n' "$calls" | command grep -qE '^sleep [1-9][0-9]*$'; then
        fail_test "no delay between mutating calls — a 200-issue backfill will trip GitHub's secondary rate limiter (recorded: ${calls//$'\n'/ | })"
    fi
}

# AC5 (the one-off backfill of the existing ~199) has no case here BY DESIGN: it
# is a `gh workflow run stale-status-labels.yml` dispatch of this very workflow,
# not separate code. Reusing the shipped path is the point — a parallel backfill
# script could drift from the thing it is meant to mirror — so the coverage for
# AC5 is every case in this file plus the live dispatch itself.
#
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
run_test test_vanished_label_absorbed \
    "a label that vanished between list and remove is absorbed"
run_test test_non_404_error_propagates \
    "a non-404 failure from removeLabel propagates"
run_test test_rate_limit_is_retried \
    "a secondary-rate-limit 403 is retried to success"
run_test test_rate_limit_retries_are_bounded \
    "rate-limit retries are bounded, not infinite"
run_test test_rate_limit_retry_max_boundary \
    "exactly RETRY_MAX throttles still succeeds"
run_test test_retry_after_header_is_honoured \
    "a positive retry-after header is honoured over the backoff"
run_test test_non_throttle_403_propagates \
    "a non-throttle 403 propagates on the first attempt"
run_test test_touched_counts_only_modified_issues \
    "the summary counts only issues actually modified"
run_test test_mutations_are_paced \
    "mutating calls are paced to stay under the rate limiter"
run_test test_check_is_non_vacuous \
    "removing the closed-state predicate reinstates the bug"

command rm -rf "$SCRATCH"

generate_report
