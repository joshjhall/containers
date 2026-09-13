#!/usr/bin/env bash
# Unit tests for .github/workflows/stale-triage-nudges.yml sweep logic.
#
# Background (issue #887): the issue labeler's flag-for-triage path applies a
# `needs-triage` label AND posts a one-time nudge comment. #881 made every
# CLI-created issue reach that path, so the nudge was posted on issues that
# already carried both labels. #883 fixed the decision logic and the label
# backlog was swept by hand — but a comment has no retraction path, so 86
# issues still carry a nudge telling a human to add labels that are visibly
# already present.
#
# Testing approach: identical to tests/unit/issue-labeler.sh (#883) and
# tests/unit/stale-status-labels.sh (#885) — yq pulls the script body out of the
# workflow YAML and node runs it against recording stubs for the `github` /
# `context` / `core` globals that actions/github-script injects. The tests
# therefore exercise the SHIPPED ARTIFACT, not a copy.
#
# THREE FIDELITY POINTS CARRY THIS SUITE.
#
# 1. The safety predicate lives in the SCRIPT (both `severity/*` and `effort/*`
#    present), not in an API query — the opposite of #885, whose predicate was
#    the `state: 'closed'` argument. So the fixtures, not the stub, are what
#    give the keep-assertions teeth: every keep case hands the script an issue
#    that DOES carry a marked comment and differs only in its labels. A fixture
#    whose kept issues had no nudge comment would pass for the wrong reason.
#
# 2. The dry-run assertions are about an ABSENCE of mutation, which is the
#    easiest thing in testing to prove vacuously. The stub therefore records an
#    `attempt` line before any fault check, so "no deleteComment call" is
#    distinguishable from "the loop was never entered" — the dry-run test
#    asserts the candidates WERE found (`would delete` lines) as well as that
#    nothing was deleted.
#
# 3. The deleteComment error paths are UNREACHABLE from the fixture alone. The
#    script only ever deletes a comment it just read off the same issue in the
#    same run, so a stub deriving its 404 from that shared fixture could never
#    fire — a test claiming to cover 404 absorption would pass by never entering
#    the branch. The 404 fires in production only when a concurrent run or a
#    human deletes the comment between the list and the delete. So faults are
#    INJECTED independently of the fixture (the `$4` argument).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "stale-triage-nudges workflow sweep logic"

WORKFLOW="$PROJECT_ROOT/.github/workflows/stale-triage-nudges.yml"

# Scratch lives outside the repo (#821) — the bindfs/virtiofs stack this repo is
# commonly mounted through loses write-then-read coherency, and these tests
# write a fixture then immediately execute it.
SCRATCH="$TEST_SCRATCH_BASE/stale-triage-nudges"

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
# call:
#
#   attempt 100/5001          <- deleteComment was reached for this comment
#   deleteComment 100/5001    <- ...and it succeeded
#   would delete 100/5001     <- dry-run candidate (no mutation)
#   sleep 1000                <- inter-mutation pacing
#
# $1 = path to the script to run (lets the non-vacuity test run a mutated copy)
# $2 = JSON array of issue fixtures:
#        { number, labels: [{name}], comments: [{id, body}], pull_request? }
# $3 = DRY_RUN value passed through the environment, exactly as the workflow's
#      `env:` block delivers it ("true" / "false" / anything else)
# $4 = optional deleteComment fault injection, as JSON:
#        { "vanished": ["<issue>/<id>", ...], "throttle": {"<issue>/<id>": N},
#          "fail": {"<issue>/<id>": <status>} }
#      `vanished` makes the stub 404 for a comment the LIST still reported —
#      modeling the out-of-band race that is the only way the script's 404
#      branch can fire in production.
#
# The script is wrapped in an async IIFE because actions/github-script does the
# same: that is what makes the script's top-level `await` legal.
run_script() {
    # `${3-false}`, NOT `${3:-false}`: the colon form substitutes on an EMPTY
    # argument as well as an unset one, which would silently rewrite the empty
    # string this suite deliberately passes to test the fail-safe default into
    # "false" — the exact value that arms deletion. The test would then report a
    # script bug that does not exist.
    local script_path="$1" fixture="$2" dry_run="${3-false}" faults="${4:-{\}}"
    local runner="$SCRATCH/run.mjs"

    command mkdir -p "$SCRATCH"
    command cat >"$runner" <<'RUNNER_EOF'
import { readFileSync } from 'node:fs';

const [scriptPath, fixtureJson, faultsJson] = process.argv.slice(2);
const fixture = JSON.parse(fixtureJson);
const faults = JSON.parse(faultsJson || '{}');
const vanished = new Set(faults.vanished || []);
const throttle = { ...(faults.throttle || {}) };
const fail = faults.fail || {};
const calls = [];

// Map comment id -> issue number, so a recorded line names both. The script
// only passes comment_id to deleteComment (that is the real API shape), so the
// issue number has to be recovered here rather than read off the call.
const issueOfComment = new Map();
for (const issue of fixture) {
  for (const c of issue.comments || []) issueOfComment.set(c.id, issue.number);
}

// Minimal stand-ins for the globals actions/github-script injects.
const github = {
  rest: {
    issues: {
      // Referenced by the script as function VALUES handed to paginate, never
      // invoked directly — paginate below is what actually resolves them.
      listForRepo: () => {},
      listComments: () => {},
      deleteComment: async ({ comment_id }) => {
        const num = issueOfComment.get(comment_id);
        const key = `${num}/${comment_id}`;
        // Recorded BEFORE any fault check so "reached but failed" is
        // distinguishable from "never reached" — see fidelity note 2.
        calls.push(`attempt ${key}`);

        // An arbitrary non-404 status the script must propagate rather than
        // swallow (permissions, 5xx).
        if (fail[key] !== undefined) {
          const err = new Error(`injected failure ${fail[key]}`);
          err.status = fail[key];
          throw err;
        }

        // Secondary rate limit on the first N attempts. Shaped like the real
        // rejection: 403 whose message names the limiter.
        if (throttle[key] > 0) {
          throttle[key]--;
          const err = new Error(
            'You have exceeded a secondary rate limit. Please wait a few minutes.',
          );
          err.status = 403;
          err.response = { headers: { 'retry-after': '0' } };
          throw err;
        }

        // The comment was reported by the list but is gone by the time we try
        // to delete it — a concurrent run, or a human, got there first. This is
        // the ONLY way the script's 404 branch fires in production, which is
        // why it is injected here rather than derived from the fixture.
        if (vanished.has(key)) {
          const err = new Error('Not Found');
          err.status = 404;
          throw err;
        }

        calls.push(`deleteComment ${key}`);
      },
    },
  },
  // Dispatch on which endpoint the script handed us. Identity is compared by
  // reference against the stubs above, mirroring how the real paginate resolves
  // the endpoint it is given.
  paginate: async (endpoint, params) => {
    if (endpoint === github.rest.issues.listComments) {
      const issue = fixture.find((i) => i.number === params.issue_number);
      return (issue && issue.comments) || [];
    }
    return fixture;
  },
};

const context = { repo: { owner: 'joshjhall', repo: 'containers' } };

// The dry-run path reports through core.info rather than mutating, so the
// report IS the observable behaviour and has to be recorded, not discarded.
const core = {
  info: (msg) => {
    const m = /^#(\d+): would delete comment (\d+)$/.exec(msg);
    if (m) calls.push(`would delete ${m[1]}/${m[2]}`);
  },
};

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
await run(github, context, core, setTimeout);
process.stdout.write(calls.join('\n'));
RUNNER_EOF

    DRY_RUN="$dry_run" node "$runner" "$script_path" "$fixture" "$faults"
}

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

MARKER='<!-- issue-labeler:needs-triage -->'
# The real nudge puts the marker on its own line, so the fixture does too — as
# the two-character JSON escape `\` `n`, never a raw newline. A raw newline is a
# control character inside a JSON string literal and makes the whole fixture
# unparsable; the runner then throws inside JSON.parse BEFORE the script under
# test runs, and every assert_not_called in this suite passes vacuously.
# %s (not %b) is what keeps the backslash literal — %b would expand it back into
# the raw newline this comment exists to prevent. test_fixtures_are_well_formed
# is the standing guard.
NUDGE="$MARKER"'\n'"This issue is missing \`severity/*\` and/or \`effort/*\` labels."

# The realistic population, mirroring the live 82-delete / 4-keep split.
#
# EVERY issue here carries a marked nudge comment. The cases differ only in
# their LABELS, which is what makes the keep-assertions meaningful — a fixture
# whose kept issues simply had no comment would pass for the wrong reason.
#
#   100 — both namespaces          -> delete (the 82 case)
#   101 — missing effort/*         -> KEEP (one of the 4)
#   102 — missing severity/*       -> KEEP
#   103 — no labels at all         -> KEEP
#   104 — both, plus an ordinary human comment that must survive
#   300 — a PR, which listForRepo returns as an issue
ISSUES="$(command printf '[
  {"number":100,"labels":[{"name":"severity/low"},{"name":"effort/small"}],
   "comments":[{"id":5001,"body":"%s"}]},
  {"number":101,"labels":[{"name":"severity/high"},{"name":"type/bug"}],
   "comments":[{"id":5002,"body":"%s"}]},
  {"number":102,"labels":[{"name":"effort/large"}],
   "comments":[{"id":5003,"body":"%s"}]},
  {"number":103,"labels":[],
   "comments":[{"id":5004,"body":"%s"}]},
  {"number":104,"labels":[{"name":"severity/medium"},{"name":"effort/trivial"}],
   "comments":[{"id":5005,"body":"%s"},{"id":5006,"body":"A real human reply."}]},
  {"number":300,"labels":[{"name":"severity/low"},{"name":"effort/small"}],
   "comments":[{"id":5007,"body":"%s"}],
   "pull_request":{"url":"https://api.github.com/pr/300"}}
]' "$NUDGE" "$NUDGE" "$NUDGE" "$NUDGE" "$NUDGE" "$NUDGE")"

# Already swept — the triaged issues retain only ordinary comments.
SWEPT="$(command printf '[
  {"number":100,"labels":[{"name":"severity/low"},{"name":"effort/small"}],
   "comments":[]},
  {"number":101,"labels":[{"name":"severity/high"}],
   "comments":[{"id":5002,"body":"%s"}]}
]' "$NUDGE")"

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# AC1: a nudge on an issue carrying BOTH namespaces is deleted.
test_triaged_nudge_deleted() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false)
    assert_called "$calls" "deleteComment 100/5001" \
        "a bogus nudge on a fully-labeled issue was not deleted (#887 AC1)"
}

# AC2: a nudge on an issue genuinely missing effort/* is KEPT. This is one of
# the live 4 (#731, #769, #794, #897) — its nudge is correct and actionable.
test_missing_effort_kept() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false)
    assert_not_called "$calls" "deleteComment 101/5002" \
        "deleted a CORRECT nudge from an issue missing effort/* (#887 AC2)"
    # Stronger than the line above: the script must not even reach the call.
    assert_not_called "$calls" "attempt 101/5002" \
        "the sweep attempted to delete a correct nudge — the label predicate did not gate it"
}

# AC2, other half of the conjunction. A predicate written as `severity || effort`
# would pass the test above and fail this one.
test_missing_severity_kept() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false)
    assert_not_called "$calls" "attempt 102/5003" \
        "deleted a CORRECT nudge from an issue missing severity/* (#887 AC2)"
}

# The wholly-untriaged case: no labels at all, which is the population the nudge
# was designed for.
test_unlabeled_kept() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false)
    assert_not_called "$calls" "attempt 103/5004" \
        "deleted the nudge from a completely unlabeled issue — exactly the issue the nudge is FOR"
}

# The MARKER selects the comment, not the issue. An ordinary human comment on a
# qualifying issue must survive.
test_ordinary_comment_survives() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false)
    assert_called "$calls" "deleteComment 104/5005" \
        "the marked nudge on a fully-labeled issue was not deleted"
    assert_not_called "$calls" "attempt 104/5006" \
        "the sweep deleted an ordinary human comment — it is selecting by ISSUE, not by marker"
}

# listForRepo returns pull requests as issues. A PR never received a nudge.
test_pull_requests_skipped() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false)
    assert_not_called "$calls" "attempt 300/5007" \
        "sweep touched a pull request — listForRepo returns PRs as issues"
}

# AC4: dry run reports candidates and mutates NOTHING.
#
# Both halves are asserted. "No deleteComment call" alone would pass against a
# script that found no candidates at all, which is the failure mode this AC
# exists to prevent.
test_dry_run_reports_without_deleting() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" true)
    assert_called "$calls" "would delete 100/5001" \
        "dry run did not report the candidate it would delete (#887 AC4)"
    assert_not_called "$calls" "attempt 100/5001" \
        "DRY RUN DELETED A COMMENT — deletion is irreversible (#887 AC4)"
}

# The dry-run report must respect the label predicate too, or the operator
# reviewing it before arming the sweep is reviewing the wrong list.
test_dry_run_respects_predicate() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" true)
    assert_not_called "$calls" "would delete 101/5002" \
        "dry run listed a CORRECT nudge as a deletion candidate"
}

# The input defaults to true, and the script must fail SAFE on anything it does
# not recognise: only the exact string 'false' arms deletion. A malformed or
# absent input silently deleting 82 comments is the worst outcome available.
test_unrecognised_dry_run_value_is_safe() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" "")
    assert_not_called "$calls" "attempt 100/5001" \
        "an EMPTY dry_run value armed deletion — the default must fail safe"

    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" "no")
    assert_not_called "$calls" "attempt 100/5001" \
        "an unrecognised dry_run value ('no') armed deletion — only 'false' may"
}

# AC3: idempotency, part 1. A second run over an already-swept set is a clean
# no-op. Note what this does NOT prove: it passes by never entering the delete
# loop, so the 404 branch is covered separately below.
test_second_run_is_noop() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$SWEPT" false 2>&1); then
        fail_test "second run over an already-swept set threw: $calls"
        return
    fi
    if [ -n "$calls" ]; then
        fail_test "second run over an already-swept set was not a no-op: ${calls//$'\n'/ | }"
    fi
}

# AC3: idempotency, part 2 — the real 404 branch. The comment is present in the
# LIST but gone by the time deleteComment runs, which is the only way the branch
# fires in production. The sweep must absorb it and keep going.
test_vanished_comment_absorbed() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false \
        '{"vanished":["100/5001"]}' 2>&1); then
        fail_test "a comment that vanished between list and delete aborted the sweep: $calls"
        return
    fi
    assert_not_called "$calls" "deleteComment 100/5001" \
        "a vanished comment was counted as deleted"
    # The sweep must continue past it, not stop at the first 404.
    assert_called "$calls" "deleteComment 104/5005" \
        "sweep stopped after absorbing a 404 instead of continuing"
}

# A non-404 failure is genuine — permissions, a 5xx — and must propagate. The
# converse of the test above: absorbing everything would turn a broken token
# into a silent no-op sweep that reports success.
test_non_404_error_propagates() {
    if run_script "$SCRATCH/script.js" "$ISSUES" false \
        '{"fail":{"100/5001":500}}' >/dev/null 2>&1; then
        fail_test "a 500 from deleteComment was swallowed — a broken sweep would report success"
    fi
}

# Secondary rate limiting. The backfill fires ~82 sequential deletes, which is
# what GitHub's abuse-detection limiter targets. A 403 from it must be retried.
test_rate_limit_is_retried() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false \
        '{"throttle":{"100/5001":2}}' 2>&1); then
        fail_test "a secondary-rate-limit 403 aborted the sweep instead of retrying: $calls"
        return
    fi
    assert_called "$calls" "deleteComment 100/5001" \
        "sweep gave up on a throttled comment instead of retrying to success"
}

# Retries are bounded — a permanently-throttled comment must eventually surface
# rather than spin forever.
test_rate_limit_retries_are_bounded() {
    if run_script "$SCRATCH/script.js" "$ISSUES" false \
        '{"throttle":{"100/5001":99}}' >/dev/null 2>&1; then
        fail_test "an endlessly-throttled comment did not surface — the retry loop is unbounded"
    fi
}

# Mutating calls are paced to stay under the secondary rate limiter.
test_mutations_are_paced() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false)
    if ! command printf '%s\n' "$calls" | command grep -qE '^sleep [1-9][0-9]*$'; then
        fail_test "no delay between mutating calls — an 82-comment backfill will trip GitHub's secondary rate limiter (recorded: ${calls//$'\n'/ | })"
    fi
}

# AC5 — non-vacuity. Neuter the label predicate in the extracted script and
# assert the bug appears: the sweep must then delete the CORRECT nudges it is
# supposed to keep.
#
# Without this guard every keep-assertion above could pass against a script that
# deletes nothing at all, or that never reaches those issues for an unrelated
# reason. Dropping the `effort/` conjunct is the precise mutation: #101 carries
# severity/* only, so it survives the real predicate and falls to the mutant.
test_check_is_non_vacuous() {
    local mutant="$SCRATCH/script-mutant.js"
    command sed -e "s|names.some((n) => n.startsWith('effort/'))|true|" \
        "$SCRATCH/script.js" >"$mutant"

    if command cmp -s "$SCRATCH/script.js" "$mutant"; then
        fail_test "mutation was a no-op — the effort/* conjunct was not found in the extracted script, so this guard proves nothing"
        return
    fi

    local calls
    calls=$(run_script "$mutant" "$ISSUES" false)
    assert_called "$calls" "deleteComment 101/5002" \
        "mutant did NOT reinstate the bug — the effort/* conjunct is not what protects untriaged issues, so the keep tests are vacuous"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

# These two preflight checks are driven manually rather than through run_test
# because a failure must abort the suite outright — there is nothing to test
# without the workflow file and its extracted script.
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

# Preflight the fixtures before any assertion depends on them.
#
# Learned the hard way while writing this suite: a malformed fixture makes the
# runner throw inside JSON.parse, BEFORE the script under test ever executes.
# The positive assertions then fail loudly — but every assert_not_called passes,
# because nothing was called for the simple reason that nothing ran. Half this
# suite is absence-assertions, so an unguarded fixture error reads as a
# half-green suite that is actually proving nothing at all.
test_fixtures_are_well_formed() {
    local calls
    if ! calls=$(run_script "$SCRATCH/script.js" "$ISSUES" false 2>&1); then
        fail_test "the ISSUES fixture did not survive a baseline run — every absence-assertion in this suite would pass vacuously: $calls"
        return
    fi
    if [ -z "$calls" ]; then
        fail_test "baseline run over the ISSUES fixture recorded NO calls — the fixture reaches nothing, so the keep-assertions prove nothing"
        return
    fi
    if ! run_script "$SCRATCH/script.js" "$SWEPT" false >/dev/null 2>&1; then
        fail_test "the SWEPT fixture did not survive a baseline run"
    fi
}

run_test test_fixtures_are_well_formed \
    "fixtures parse and reach the script under test"

run_test test_triaged_nudge_deleted \
    "nudge on a fully-labeled issue is deleted"
run_test test_missing_effort_kept \
    "nudge on an issue missing effort/* is kept"
run_test test_missing_severity_kept \
    "nudge on an issue missing severity/* is kept"
run_test test_unlabeled_kept \
    "nudge on a completely unlabeled issue is kept"
run_test test_ordinary_comment_survives \
    "an ordinary comment on a swept issue survives"
run_test test_pull_requests_skipped \
    "pull requests returned by listForRepo are skipped"
run_test test_dry_run_reports_without_deleting \
    "dry run reports candidates and deletes nothing"
run_test test_dry_run_respects_predicate \
    "dry run applies the same label predicate"
run_test test_unrecognised_dry_run_value_is_safe \
    "an unrecognised dry_run value fails safe"
run_test test_second_run_is_noop \
    "second run over an already-swept set is a clean no-op"
run_test test_vanished_comment_absorbed \
    "a comment that vanished between list and delete is absorbed"
run_test test_non_404_error_propagates \
    "a non-404 failure from deleteComment propagates"
run_test test_rate_limit_is_retried \
    "a secondary-rate-limit 403 is retried to success"
run_test test_rate_limit_retries_are_bounded \
    "rate-limit retries are bounded, not infinite"
run_test test_mutations_are_paced \
    "mutating calls are paced to stay under the rate limiter"
run_test test_check_is_non_vacuous \
    "removing the effort/* conjunct reinstates the bug"

command rm -rf "$SCRATCH"

generate_report
