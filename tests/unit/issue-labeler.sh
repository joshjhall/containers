#!/usr/bin/env bash
# Unit tests for .github/workflows/issue-labeler.yml triage logic.
#
# Background (issue #881): the workflow decided triage state only from the
# `### Severity` / `### Effort` headings that GitHub's form templates render
# into the issue body. CLI-created issues (/workflow:file-issue,
# `gh issue create --label ...`) carry those values as API labels and have no
# form headings, so every one of them was flagged `needs-triage` — and the
# stale-flag removal lived inside a branch such an issue could never reach, so
# the flag never cleared. Measured at the time: 24 of 24 open `needs-triage`
# issues carried both labels, i.e. a signal-to-noise ratio of zero.
#
# The fix decides on the *effective* severity/effort — parsed from the body OR
# already present as a `severity/*` / `effort/*` label — and moves the removal
# out of that branch.
#
# Testing approach: the script is embedded in the workflow YAML, and this repo
# has no package.json, no .github/scripts/, and no JS test precedent. Rather
# than extract it to a module (which would force an actions/checkout into a
# workflow that needs no repo checkout), these tests exercise the SHIPPED
# ARTIFACT: yq pulls the script body out of the YAML — the same yq-driven
# approach tests/unit/conform-scopes.sh uses for .conform.yaml — and node runs
# it against recording stubs for the `github` / `context` / `core` globals that
# actions/github-script injects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "issue-labeler workflow triage logic"

WORKFLOW="$PROJECT_ROOT/.github/workflows/issue-labeler.yml"

# Scratch lives outside the repo (#821) — the bindfs/virtiofs stack this repo is
# commonly mounted through loses write-then-read coherency, and these tests
# write a fixture then immediately execute it.
SCRATCH="$TEST_SCRATCH_BASE/issue-labeler"

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
    yq '.jobs.label.steps[0].with.script' "$WORKFLOW" >"$SCRATCH/script.js"
    # yq prints the literal string "null" for a missing path; a silent empty
    # script would make every assertion below vacuously pass.
    if [ ! -s "$SCRATCH/script.js" ] ||
        [ "$(command head -c 4 "$SCRATCH/script.js")" = "null" ]; then
        return 1
    fi
}

# Run the extracted script against stubs and print one line per recorded API
# call, in the form "<method> <argument>":
#
#   addLabels severity/low
#   removeLabel needs-triage
#   createComment <!-- issue-labeler:needs-triage -->
#
# $1 = path to the script to run (lets the non-vacuity test run a mutated copy)
# $2 = issue body
# $3 = comma-separated existing label names ("" for none)
# $4 = "nudged" to pre-seed an existing nudge comment, else ""
#
# The script is wrapped in an async IIFE because actions/github-script does the
# same: that is what makes the script's top-level `await` and `return` legal.
run_script() {
    local script_path="$1" body="$2" labels="$3" nudged="${4:-}"
    local runner="$SCRATCH/run.mjs"

    command mkdir -p "$SCRATCH"
    command cat >"$runner" <<'RUNNER_EOF'
import { readFileSync } from 'node:fs';

const [scriptPath, body, labelCsv, nudged] = process.argv.slice(2);
const labels = labelCsv ? labelCsv.split(',') : [];
const calls = [];

// Minimal stand-ins for the globals actions/github-script injects. Each stub
// records what it was asked to do; assertions are made against `calls`.
const github = {
  rest: {
    issues: {
      addLabels: async ({ labels }) => {
        for (const l of labels) calls.push(`addLabels ${l}`);
      },
      removeLabel: async ({ name }) => {
        calls.push(`removeLabel ${name}`);
      },
      // The real getLabel throws a 404-shaped error when the label is absent;
      // here the label always exists, which is the steady state in this repo.
      getLabel: async () => ({}),
      createLabel: async ({ name }) => {
        calls.push(`createLabel ${name}`);
      },
      createComment: async ({ body }) => {
        calls.push(`createComment ${body.split('\n')[0]}`);
      },
      listComments: () => {},
    },
  },
  paginate: async () =>
    nudged === 'nudged'
      ? [{ body: '<!-- issue-labeler:needs-triage -->\nplease triage' }]
      : [],
};

const context = {
  repo: { owner: 'joshjhall', repo: 'containers' },
  payload: {
    issue: {
      number: 881,
      body,
      labels: labels.map((name) => ({ name })),
    },
  },
};

const core = { info: () => {} };

const source = readFileSync(scriptPath, 'utf8');
const run = new Function(
  'github', 'context', 'core',
  `return (async () => { ${source} })();`,
);
await run(github, context, core);
process.stdout.write(calls.join('\n'));
RUNNER_EOF

    node "$runner" "$script_path" "$body" "$labels" "$nudged"
}

# Assert a "<method> <arg>" line is / is not among the recorded calls.
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

# A form-template body, as GitHub renders the Severity/Effort dropdowns.
FORM_BODY='### Severity

low — Minor inconvenience

### Effort

small — A couple of files'

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

# AC1: an issue created via `gh issue create --label "severity/low,effort/small"`
# with no form body must NOT receive needs-triage. This is the reported bug.
test_cli_created_issue_not_flagged() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "Plain prose body, no headings." \
        "severity/low,effort/small,type/bug")
    assert_not_called "$calls" "addLabels needs-triage" \
        "CLI-created issue with both labels was flagged needs-triage (#881)"
}

# AC2: an issue already carrying needs-triage AND both labels has the flag
# removed on its next `edited` event. Before the fix this removal sat inside the
# `toAdd.length > 0` branch, which a label-only issue never enters.
test_stale_flag_cleared() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "Plain prose body, no headings." \
        "severity/low,effort/small,needs-triage")
    assert_called "$calls" "removeLabel needs-triage" \
        "stale needs-triage was not removed from a fully-labeled issue (#881)"
}

# AC3: the behaviour is not simply disabled — an issue with no form selections
# AND no labels still gets flagged, and still gets the nudge comment.
test_genuinely_untriaged_still_flagged() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "Just a sentence." "type/bug")
    assert_called "$calls" "addLabels needs-triage" \
        "genuinely untriaged issue was not flagged — the check is disabled, not fixed"
}

test_genuinely_untriaged_gets_nudge() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "Just a sentence." "type/bug")
    assert_called "$calls" "createComment <!-- issue-labeler:needs-triage -->" \
        "no nudge comment posted for an untriaged issue"
}

# Regression guard on the pre-existing, still-correct behaviour: a form-created
# issue's dropdowns are parsed into labels.
test_form_body_still_labeled() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "$FORM_BODY" "")
    assert_called "$calls" "addLabels severity/low" \
        "form-parsed severity label was not applied"
    assert_called "$calls" "addLabels effort/small" \
        "form-parsed effort label was not applied"
    assert_not_called "$calls" "addLabels needs-triage" \
        "form-labeled issue was flagged needs-triage"
}

# Parity with .gitlab/triage/triage-policies.yml, whose flag/clear rules are
# logical negations of each other over both prefixes: one namespace alone is not
# enough for /next-issue to prioritize the issue.
test_half_labeled_is_flagged() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "Plain prose body." "severity/low")
    assert_called "$calls" "addLabels needs-triage" \
        "issue with severity but no effort was not flagged"
}

# Idempotency: the nudge is guarded by a hidden marker, so a re-run on an
# already-nudged issue must not post a second comment.
test_nudge_not_reposted() {
    local calls
    calls=$(run_script "$SCRATCH/script.js" "Just a sentence." "needs-triage" nudged)
    assert_not_called "$calls" "createComment <!-- issue-labeler:needs-triage -->" \
        "nudge comment was posted a second time"
}

# AC4 — non-vacuity. Strip the `current`-label lookup out of the extracted
# script and assert the bug comes back. Without this, every assertion above
# could pass against a script that never consults the issue's real labels.
test_check_is_non_vacuous() {

    local mutant="$SCRATCH/script-mutant.js"
    # Neuter both disjuncts: effective state falls back to the parsed value
    # alone, which is exactly the pre-fix logic.
    command sed \
        -e "s|current\.some((n) => n\.startsWith('severity/'))|false|" \
        -e "s|current\.some((n) => n\.startsWith('effort/'))|false|" \
        "$SCRATCH/script.js" >"$mutant"

    if command cmp -s "$SCRATCH/script.js" "$mutant"; then
        fail_test "mutation was a no-op — the current-label lookup was not found in the extracted script, so this guard proves nothing"
        return
    fi

    local calls
    calls=$(run_script "$mutant" "Plain prose body, no headings." \
        "severity/low,effort/small")
    assert_called "$calls" "addLabels needs-triage" \
        "mutant did NOT reinstate the bug — the current-label check is not what prevents flagging, so the real tests are vacuous"
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
    fail_test "could not extract .jobs.label.steps[0].with.script from $WORKFLOW"
    generate_report
    exit 1
fi

run_test test_cli_created_issue_not_flagged \
    "CLI-created issue (labels, no form body) is not flagged"
run_test test_stale_flag_cleared \
    "stale needs-triage is cleared when both labels are present"
run_test test_genuinely_untriaged_still_flagged \
    "issue with no selections and no labels is still flagged"
run_test test_genuinely_untriaged_gets_nudge \
    "untriaged issue receives the one-time nudge comment"
run_test test_form_body_still_labeled \
    "form-body issue still gets severity/effort labels applied"
run_test test_half_labeled_is_flagged \
    "half-labeled issue (severity only) is flagged"
run_test test_nudge_not_reposted \
    "nudge comment is not re-posted when already present"
run_test test_check_is_non_vacuous \
    "removing the current-label lookup reinstates the bug"

command rm -rf "$SCRATCH"

generate_report
