#!/usr/bin/env bash
# Unit tests for bin/check-pr-checks.sh — the zero-check merge guard (#854).
#
# The behavior under test is a negative: a PR showing NO checks must not be
# treated as a PR showing no failures. That distinction is invisible in the
# happy path, so these tests are built around counter-tests — for each rule,
# a case that passes today and would flip if the rule were deleted.
#
# Three properties are easy to get wrong and are therefore pinned explicitly:
#
#   1. effective_checks = total - skipping. The healthy steady state on this
#      repo is majority-skipping (PR #896: 13 of 23), so a naive "count > 0"
#      guard would green-light a PR on which nothing ran. Tests 6 and 7 are a
#      matched pair: 6 fails if the subtraction is dropped, 7 fails if the
#      subtraction is over-applied into "skipping-heavy means absent".
#
#   2. The grace boundary is strict (age > grace). Tests 4 and 5 sit one
#      second apart on either side; neither alone constrains the comparator,
#      together they admit exactly `-gt`.
#
#   3. statusCheckRollup carries NO `bucket` field and spells outcomes in
#      UPPERCASE via .status/.conclusion (CheckRun) or .state (StatusContext).
#      An adapter that matches lowercase counts zero everywhere, which renders
#      as a clean pass — the exact silent failure this script exists to stop.
#      Verified against live PRs #896 and #848 during implementation.
#
# Per .claude/memory/skips-render-as-passes.md, the count-driven tests (the AC3
# core) use no external tools and can never silently skip. Only the JSON-adapter
# tests need jq, and they FAIL in CI rather than skipping when it is absent.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

SKIP_DOCKER_CHECK=true init_test_framework

test_suite "Bin Check PR Checks Tests"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT_REAL="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$PROJECT_ROOT_REAL/bin/check-pr-checks.sh"

# Run the script and capture stdout; the caller inspects $? separately. The
# environment is cleared of PR_CHECKS_GRACE_SEC so a value leaking in from the
# surrounding shell cannot quietly change a verdict.
run_verdict() {
    env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict "$@" 2>&1
}

# Extract one key=value field from the emitted report.
field() {
    command printf '%s\n' "$1" | command grep "^$2=" | command cut -d= -f2-
}

test_script_exists_and_executable() {
    assert_file_exists "$SCRIPT" "check-pr-checks.sh exists"
    assert_executable "$SCRIPT" "check-pr-checks.sh is executable"
}

test_valid_bash_syntax() {
    bash -n "$SCRIPT" 2>/dev/null
    assert_true $? "check-pr-checks.sh parses as valid bash"
}

# --- Core AC3 split -------------------------------------------------------
# The issue in one test: zero checks, past grace, must not read as passing.

test_zero_checks_past_grace_is_absent() {
    local out rc
    out="$(run_verdict --age-sec 900 --total 0 --failing 0 --pending 0 --skipping 0)"
    rc=$?
    assert_equals "absent" "$(field "$out" verdict)" \
        "Zero checks past grace is absent"
    assert_equals "zero_checks_past_grace" "$(field "$out" reason)" \
        "Reason names the grace expiry"
    assert_equals "3" "$rc" "absent exits 3"
}

test_absent_is_never_exit_zero() {
    local rc
    run_verdict --age-sec 900 --total 0 --failing 0 --pending 0 --skipping 0 >/dev/null
    rc=$?
    assert_not_equals "0" "$rc" \
        "absent must not exit 0 — zero checks is NOT PASSING (#854 AC3)"
}

test_absent_is_not_mergeable() {
    local out
    out="$(run_verdict --age-sec 900 --total 0 --failing 0 --pending 0 --skipping 0 || true)"
    assert_equals "false" "$(field "$out" mergeable)" "absent reports mergeable=false"
}

test_zero_checks_within_grace_is_pending() {
    local out rc
    out="$(run_verdict --age-sec 4 --total 0 --failing 0 --pending 0 --skipping 0)"
    rc=$?
    assert_equals "pending" "$(field "$out" verdict)" \
        "Zero checks inside grace is pending, not absent (3-4s is the normal baseline)"
    assert_equals "4" "$rc" "pending exits 4"
}

# --- Grace boundary: this pair admits exactly `age > grace` ----------------

test_age_exactly_at_grace_is_pending() {
    local out
    out="$(run_verdict --age-sec 300 --total 0 --failing 0 --pending 0 --skipping 0 || true)"
    assert_equals "pending" "$(field "$out" verdict)" \
        "age == grace is still pending (boundary is strict)"
}

test_age_one_second_past_grace_is_absent() {
    local out
    out="$(run_verdict --age-sec 301 --total 0 --failing 0 --pending 0 --skipping 0 || true)"
    assert_equals "absent" "$(field "$out" verdict)" \
        "age == grace+1 is absent"
}

# --- Effective-count split (the PR #896 majority-skipping shape) -----------

test_all_skipping_is_zero_effective() {
    local out
    out="$(run_verdict --age-sec 900 --total 23 --failing 0 --pending 0 --skipping 23 || true)"
    assert_equals "0" "$(field "$out" effective_checks)" \
        "23 total / 23 skipping is zero effective checks"
    assert_equals "absent" "$(field "$out" verdict)" \
        "An all-skipping rollup past grace is absent, not pass"
}

test_one_real_check_among_skipping_is_pass() {
    local out rc
    out="$(run_verdict --age-sec 900 --total 23 --failing 0 --pending 0 --skipping 22)"
    rc=$?
    assert_equals "1" "$(field "$out" effective_checks)" "One non-skipping check counts"
    assert_equals "pass" "$(field "$out" verdict)" \
        "A single real check is enough — counter-test against over-applying the subtraction"
    assert_equals "0" "$rc" "pass exits 0"
}

test_healthy_repo_shape_is_pass() {
    local out
    out="$(run_verdict --age-sec 900 --total 23 --failing 0 --pending 0 --skipping 13)"
    assert_equals "10" "$(field "$out" effective_checks)" \
        "PR #896's real shape yields 10 effective checks"
    assert_equals "pass" "$(field "$out" verdict)" "The healthy steady state passes"
}

test_cancelled_check_is_not_a_pass() {
    local out
    out="$(run_verdict --age-sec 10 --total 1 --failing 0 --pending 0 --skipping 0 --cancelled 1 || true)"
    assert_equals "fail" "$(field "$out" verdict)" \
        "A cancelled check did not report success"
    assert_equals "1" "$(field "$out" failing)" "Cancelled folds into the failing count"
}

# --- Verdict precedence ---------------------------------------------------

test_pending_check_past_grace_is_pending_not_absent() {
    local out
    out="$(run_verdict --age-sec 1800 --total 4 --failing 0 --pending 1 --skipping 0 || true)"
    assert_equals "pending" "$(field "$out" verdict)" \
        "Real checks still running past grace are pending, not absent"
    assert_equals "checks_still_running" "$(field "$out" reason)" \
        "Reason distinguishes running checks from an empty rollup"
}

test_failing_check_within_grace_is_fail() {
    local out rc
    out="$(run_verdict --age-sec 5 --total 3 --failing 1 --pending 0 --skipping 0)"
    rc=$?
    assert_equals "fail" "$(field "$out" verdict)" \
        "A real failure is not masked by the grace window"
    assert_equals "1" "$rc" "fail exits 1"
}

test_exit_codes_match_every_verdict() {
    # Sweep all four verdicts rather than trusting one — per
    # .claude/memory/fixture-state-hides-vectors.md, an exhaustive claim needs
    # every state exercised.
    local rc

    run_verdict --age-sec 10 --total 2 --failing 0 --pending 0 --skipping 0 >/dev/null
    rc=$?
    assert_equals "0" "$rc" "pass -> 0"

    run_verdict --age-sec 10 --total 2 --failing 1 --pending 0 --skipping 0 >/dev/null
    rc=$?
    assert_equals "1" "$rc" "fail -> 1"

    run_verdict --age-sec 900 --total 0 --failing 0 --pending 0 --skipping 0 >/dev/null
    rc=$?
    assert_equals "3" "$rc" "absent -> 3"

    run_verdict --age-sec 10 --total 0 --failing 0 --pending 0 --skipping 0 >/dev/null
    rc=$?
    assert_equals "4" "$rc" "pending -> 4"
}

# --- Grace configuration --------------------------------------------------

test_default_grace_is_300() {
    local out
    out="$(run_verdict --age-sec 10 --total 1 --failing 0 --pending 0 --skipping 0)"
    assert_equals "300" "$(field "$out" grace_sec)" \
        "Default grace is 300s (~75x the measured 3-4s baseline)"
}

test_grace_env_override_is_honored() {
    local out
    # 800s is past the 300s default but inside a 1200s window: the verdict flips
    # only if the env var is actually read.
    out="$(PR_CHECKS_GRACE_SEC=1200 "$SCRIPT" verdict \
        --age-sec 800 --total 0 --failing 0 --pending 0 --skipping 0 2>&1 || true)"
    assert_equals "pending" "$(field "$out" verdict)" \
        "A widened grace keeps an 800s-old empty rollup pending"
    assert_equals "1200" "$(field "$out" grace_sec)" \
        "The emitted grace_sec reflects the override, not the default"
}

test_grace_override_narrower_than_default() {
    local out
    out="$(PR_CHECKS_GRACE_SEC=1 "$SCRIPT" verdict \
        --age-sec 4 --total 0 --failing 0 --pending 0 --skipping 0 2>&1 || true)"
    assert_equals "absent" "$(field "$out" verdict)" \
        "A narrowed grace turns the 4s baseline case absent"
}

test_non_numeric_grace_exits_2() {
    local out rc
    out="$(PR_CHECKS_GRACE_SEC=abc "$SCRIPT" verdict \
        --age-sec 10 --total 1 --failing 0 --pending 0 --skipping 0 2>&1)" || rc=$?
    assert_equals "2" "${rc:-0}" "Non-numeric grace exits 2"
    # Assert the diagnostic, not just the code: bad arithmetic would also exit
    # non-zero, so an exit-code-only check could pass for the wrong reason.
    assert_contains "$out" "PR_CHECKS_GRACE_SEC" \
        "The error names the offending variable"
}

# --- Usage / input validation ---------------------------------------------

test_missing_age_exits_2() {
    local rc=0
    run_verdict --total 1 --failing 0 --pending 0 --skipping 0 >/dev/null || rc=$?
    assert_equals "2" "$rc" "Missing --age-sec exits 2"
}

test_unknown_flag_exits_2() {
    local rc=0
    run_verdict --age-sec 10 --bogus 1 >/dev/null || rc=$?
    assert_equals "2" "$rc" "Unknown flag exits 2"
}

test_negative_age_exits_2() {
    local rc=0
    run_verdict --age-sec -5 --total 1 --failing 0 --pending 0 --skipping 0 >/dev/null || rc=$?
    assert_equals "2" "$rc" "Negative age exits 2 rather than emitting a verdict"
}

test_skipping_exceeding_total_exits_2() {
    local rc=0
    run_verdict --age-sec 10 --total 2 --failing 0 --pending 0 --skipping 5 >/dev/null || rc=$?
    assert_equals "2" "$rc" "Incoherent counts exit 2 rather than yielding negative effective checks"
}

test_trailing_flag_without_value_exits_2() {
    # A flag as the LAST token, with no value after it, used to HANG: `shift 2`
    # with one positional left fails, and without `set -e` that failure leaves
    # the positionals untouched, so the loop re-entered the same arm forever.
    # `timeout` is what makes this a real regression test — without it a
    # reintroduced hang would stall the suite rather than fail it. Every
    # value-taking flag is swept, since the parser groups them in one arm and a
    # future flag added outside that arm would reintroduce the bug.
    local flag rc
    for flag in --age-sec --rollup-json --total --failing --pending --skipping --cancelled --now; do
        rc=0
        timeout -s KILL 10 "$SCRIPT" verdict "$flag" >/dev/null 2>&1 || rc=$?
        assert_equals "2" "$rc" "$flag with no value exits 2 (137 would mean it hung)"
    done
}

test_trailing_flag_error_names_the_flag() {
    local out
    out="$(timeout -s KILL 10 "$SCRIPT" verdict --age-sec 2>&1 || true)"
    # Assert the diagnostic, not just the code: a hang killed by timeout also
    # yields non-zero, so an exit-code-only check could pass for the wrong reason.
    assert_contains "$out" "requires a value" \
        "The error explains the missing value rather than dying silently"
}

test_unknown_subcommand_exits_2() {
    local rc=0
    env -u PR_CHECKS_GRACE_SEC "$SCRIPT" bogus >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "Unknown subcommand exits 2"
}

test_help_flag() {
    local out
    out="$("$SCRIPT" --help)"
    assert_contains "$out" "Usage:" "Help text present"
    assert_contains "$out" "PR_CHECKS_GRACE_SEC" "Help documents the grace override"
    assert_contains "$out" "Exit:" "Help documents exit codes"
}

# --- JSON adapter ---------------------------------------------------------
# statusCheckRollup is the GraphQL shape: no `bucket`, UPPERCASE outcomes.

require_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    # Fail in CI, skip locally: a silent skip renders identically to a pass
    # (.claude/memory/skips-render-as-passes.md).
    if [ "${CI:-false}" = "true" ]; then
        assert_equals "present" "absent" "jq is required in CI for the rollup-JSON tests"
    else
        skip_test "jq not installed"
    fi
    return 1
}

test_rollup_json_classifies_checkrun_conclusions() {
    require_jq || return 0
    local payload out
    payload='{"createdAt":"2026-08-26T16:45:44Z","statusCheckRollup":[
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "3" "$(field "$out" total_checks)" "Counts every rollup node"
    assert_equals "2" "$(field "$out" skipping)" "SKIPPED conclusions are skipping"
    assert_equals "1" "$(field "$out" effective_checks)" "Effective count subtracts skipping"
    assert_equals "pass" "$(field "$out" verdict)" "One SUCCESS among skips passes"
}

test_rollup_json_reads_uppercase_not_bucket() {
    require_jq || return 0
    local payload out
    # An in-progress CheckRun. There is no `bucket` field to read, and the
    # values are UPPERCASE: a lowercase or bucket-based filter counts zero
    # pending, turning a running PR into a pass.
    payload='{"createdAt":"2026-08-26T16:45:44Z","statusCheckRollup":[
      {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null},
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "1" "$(field "$out" pending)" \
        "IN_PROGRESS is pending — read from .status, UPPERCASE, not .bucket"
    assert_equals "pending" "$(field "$out" verdict)" \
        "A running check must not render as a pass"
}

test_rollup_json_handles_status_context() {
    require_jq || return 0
    local payload out
    payload='{"createdAt":"2026-08-26T16:45:44Z","statusCheckRollup":[
      {"__typename":"StatusContext","state":"FAILURE"}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "fail" "$(field "$out" verdict)" \
        "StatusContext nodes report via .state, not .conclusion"
}

test_rollup_json_empty_array_past_grace_is_absent() {
    require_jq || return 0
    local payload out
    # The literal PR #848 shape during the incident window.
    payload='{"createdAt":"2026-08-26T16:45:44Z","statusCheckRollup":[]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 826 2>&1 || true)"
    assert_equals "absent" "$(field "$out" verdict)" \
        "An empty rollup at the 13m46s #848 delay is absent"
}

test_rollup_json_derives_age_from_created_at() {
    require_jq || return 0
    local payload out
    # createdAt is the real PR #848 timestamp (epoch 1787762744); --now is set
    # 826s later, the measured 13m46s delay.
    payload='{"createdAt":"2026-08-26T16:45:44Z","statusCheckRollup":[]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --now 1787763570 2>&1 || true)"
    assert_equals "826" "$(field "$out" age_sec)" \
        "Age is derived from createdAt when --age-sec is omitted"
    assert_equals "absent" "$(field "$out" verdict)" "The derived age drives the verdict"
}

test_rollup_json_baseline_delay_is_pending() {
    require_jq || return 0
    local payload out
    # 4s after creation — the measured normal arrival on this repo.
    payload='{"createdAt":"2026-08-26T16:45:44Z","statusCheckRollup":[]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --now 1787762748 2>&1 || true)"
    assert_equals "pending" "$(field "$out" verdict)" \
        "The 3-4s baseline must not be flagged absent — counter-test against a too-narrow grace"
}

test_rollup_json_null_conclusion_fails_closed() {
    require_jq || return 0
    local payload out
    # A COMPLETED CheckRun whose conclusion is null classifies as nothing. If
    # failing were an allowlist of failure names it would match none of them,
    # still count toward effective_checks, and emerge as `pass` — fail-open, the
    # exact shape this script exists to prevent.
    payload='{"statusCheckRollup":[
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":null}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "fail" "$(field "$out" verdict)" \
        "An unclassifiable outcome must not read as a pass"
    assert_equals "1" "$(field "$out" failing)" "It counts as failing, not as a silent success"
}

test_rollup_json_unknown_typename_fails_closed() {
    require_jq || return 0
    local payload out
    # Guards against a future GitHub node type or status value: anything this
    # script does not explicitly recognize as SUCCESS/skip/pending/cancel is
    # treated as a failure rather than waved through.
    payload='{"statusCheckRollup":[
      {"__typename":"FutureNodeType","status":"COMPLETED","conclusion":"BRAND_NEW_STATE"}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "fail" "$(field "$out" verdict)" \
        "An unrecognized conclusion fails closed"
}

test_rollup_json_queued_is_pending() {
    require_jq || return 0
    local payload out
    # QUEUED is a non-COMPLETED status, so it must read as pending rather than
    # falling into the unknown-fails-closed path — a queued check has not failed.
    payload='{"statusCheckRollup":[
      {"__typename":"CheckRun","status":"QUEUED","conclusion":null}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "pending" "$(field "$out" verdict)" \
        "QUEUED is pending — counter-test so fail-closed does not swallow queued checks"
}

test_rollup_json_missing_rollup_key_is_absent() {
    require_jq || return 0
    local payload out
    # A payload with no statusCheckRollup key at all must not crash or pass.
    payload='{"createdAt":"2026-08-26T16:45:44Z"}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "absent" "$(field "$out" verdict)" \
        "A missing statusCheckRollup key is absent, not pass"
}

test_rollup_json_neutral_expected_cancelled() {
    require_jq || return 0
    local payload out
    # NEUTRAL, EXPECTED and CANCELLED each have their own arm in the classifier
    # but were reachable only through the explicit-count path. Sweeping them
    # through the JSON adapter too, per fixture-state-hides-vectors: an
    # exhaustive claim needs every member exercised in the state that matters.
    payload='{"statusCheckRollup":[
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"NEUTRAL"},
      {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "1" "$(field "$out" skipping)" "NEUTRAL classifies as skipping"
    assert_equals "pass" "$(field "$out" verdict)" "NEUTRAL alongside a SUCCESS passes"

    payload='{"statusCheckRollup":[{"__typename":"StatusContext","state":"EXPECTED"}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "pending" "$(field "$out" verdict)" "EXPECTED classifies as pending"

    payload='{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]}'
    out="$(command printf '%s' "$payload" |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 900 2>&1 || true)"
    assert_equals "fail" "$(field "$out" verdict)" "CANCELLED folds into failing via the JSON path too"
}

test_rollup_json_invalid_input_exits_2() {
    require_jq || return 0
    local rc=0
    command printf 'not json' |
        env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict --rollup-json - --age-sec 10 >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "Malformed JSON exits 2 rather than yielding a verdict"
}

test_rollup_json_missing_file_exits_2() {
    local rc=0
    env -u PR_CHECKS_GRACE_SEC "$SCRIPT" verdict \
        --rollup-json /nonexistent/rollup.json --age-sec 10 >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "A missing rollup file exits 2"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_valid_bash_syntax "Script is valid bash"
run_test test_zero_checks_past_grace_is_absent "Zero checks past grace is absent"
run_test test_absent_is_never_exit_zero "absent never exits 0"
run_test test_absent_is_not_mergeable "absent reports mergeable=false"
run_test test_zero_checks_within_grace_is_pending "Zero checks within grace is pending"
run_test test_age_exactly_at_grace_is_pending "Boundary: age == grace is pending"
run_test test_age_one_second_past_grace_is_absent "Boundary: age == grace+1 is absent"
run_test test_all_skipping_is_zero_effective "All-skipping rollup is zero effective"
run_test test_one_real_check_among_skipping_is_pass "One real check among skips passes"
run_test test_healthy_repo_shape_is_pass "Healthy repo shape (10/23) passes"
run_test test_cancelled_check_is_not_a_pass "Cancelled check counts as failing"
run_test test_pending_check_past_grace_is_pending_not_absent "Running checks past grace stay pending"
run_test test_failing_check_within_grace_is_fail "Failure within grace still fails"
run_test test_exit_codes_match_every_verdict "Exit codes match all four verdicts"
run_test test_default_grace_is_300 "Default grace is 300s"
run_test test_grace_env_override_is_honored "Grace env override is honored"
run_test test_grace_override_narrower_than_default "Narrowed grace flips the baseline case"
run_test test_non_numeric_grace_exits_2 "Non-numeric grace exits 2"
run_test test_missing_age_exits_2 "Missing --age-sec exits 2"
run_test test_unknown_flag_exits_2 "Unknown flag exits 2"
run_test test_negative_age_exits_2 "Negative age exits 2"
run_test test_skipping_exceeding_total_exits_2 "Skipping > total exits 2"
run_test test_trailing_flag_without_value_exits_2 "Trailing flag with no value exits 2 (no hang)"
run_test test_trailing_flag_error_names_the_flag "Trailing-flag error names the cause"
run_test test_unknown_subcommand_exits_2 "Unknown subcommand exits 2"
run_test test_help_flag "Help flag works"
run_test test_rollup_json_classifies_checkrun_conclusions "Rollup JSON classifies CheckRun conclusions"
run_test test_rollup_json_reads_uppercase_not_bucket "Rollup JSON reads UPPERCASE status, not bucket"
run_test test_rollup_json_handles_status_context "Rollup JSON handles StatusContext nodes"
run_test test_rollup_json_empty_array_past_grace_is_absent "Empty rollup past grace is absent"
run_test test_rollup_json_derives_age_from_created_at "Age derived from createdAt"
run_test test_rollup_json_baseline_delay_is_pending "4s baseline delay stays pending"
run_test test_rollup_json_null_conclusion_fails_closed "Null conclusion fails closed"
run_test test_rollup_json_unknown_typename_fails_closed "Unknown conclusion fails closed"
run_test test_rollup_json_queued_is_pending "QUEUED status is pending"
run_test test_rollup_json_missing_rollup_key_is_absent "Missing rollup key is absent"
run_test test_rollup_json_neutral_expected_cancelled "NEUTRAL/EXPECTED/CANCELLED classify correctly"
run_test test_rollup_json_invalid_input_exits_2 "Malformed rollup JSON exits 2"
run_test test_rollup_json_missing_file_exits_2 "Missing rollup file exits 2"

generate_report
