#!/usr/bin/env bash
# Regression test: every test run_test executes must end in exactly one verdict.
#
# run_test used to record a verdict only when the test function returned 0. A
# function returning non-zero WITHOUT calling an assertion — a bare `return 1`,
# or a call to an undefined helper exiting 127 — recorded nothing: TESTS_FAILED
# stayed 0, the report read "Failed: 0", and the suite exited 0. Six tests on
# main were failing that way, invisibly, in CI (#1002).
#
# Each case asserts the exact counter values, not just "non-zero exit", so a
# fix that double-counts (assertion failure + return 1 => Failed: 2) or that
# turns a skip into a failure is caught too.
#
# The framework is exercised in a CHILD shell rather than by re-running
# init_test_framework in this process, which would reset this suite's own
# pass/fail counters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

FRAMEWORK_SH="$SCRIPT_DIR/../framework.sh"

test_suite "every test records exactly one verdict"

# Run a synthetic suite in a fresh shell and echo its exit code as the last
# line. Paths travel through the environment so a repo path containing quotes
# cannot break the -c string.
run_suite_in_child() {
    local body="$1"
    /usr/bin/env -i \
        PATH="$PATH" \
        HOME="${HOME:-/tmp}" \
        TERM="dumb" \
        SKIP_DOCKER_CHECK=true \
        FRAMEWORK_SH="$FRAMEWORK_SH" \
        BODY="$body" \
        /bin/bash -c '
            source "$FRAMEWORK_SH" >/dev/null 2>&1
            init_test_framework >/dev/null 2>&1
            test_suite "child" >/dev/null 2>&1
            eval "$BODY"
            # framework.sh sets -e; capture the status so a red report still
            # prints its exit code instead of killing the child first.
            rc=0
            generate_report || rc=$?
            /usr/bin/echo "CHILD_EXIT=$rc"
        ' 2>&1
}

# The regression itself: a bare non-zero return is a failure.
test_bare_nonzero_return_counts_as_failed() {
    local out
    out=$(run_suite_in_child '
        t_bare() { return 1; }
        run_test t_bare "bare return 1"
    ')
    assert_contains "$out" "Failed:      1" \
        "a verdict-less return 1 must be counted as failed"
    assert_contains "$out" "Passed:      0" \
        "a verdict-less return 1 must not be counted as passed"
    assert_contains "$out" "without recording a verdict" \
        "the failure reason must say no verdict was recorded"
    assert_contains "$out" "CHILD_EXIT=1" \
        "a suite with a verdict-less failure must exit 1"
}

# An undefined helper (the `skip`/`fail` typos that hid failures) exits 127.
test_undefined_helper_counts_as_failed() {
    local out
    out=$(run_suite_in_child '
        t_undef() { no_such_helper_1002 "x"; }
        run_test t_undef "undefined helper"
    ')
    assert_contains "$out" "Failed:      1" \
        "a call to an undefined helper must be counted as failed"
    assert_contains "$out" "returned 127" \
        "the failure reason must carry the original exit code"
    assert_contains "$out" "CHILD_EXIT=1" \
        "a suite whose test hit an undefined helper must exit 1"
}

# A skip followed by a non-zero return keeps its skip — it is not reclassified.
test_skip_then_nonzero_stays_skipped() {
    local out
    out=$(run_suite_in_child '
        t_skip() { skip_test "not applicable"; return 1; }
        run_test t_skip "skip then return 1"
    ')
    assert_contains "$out" "Skipped:     1" \
        "a skipped test must stay skipped"
    assert_contains "$out" "Failed:      0" \
        "a skipped test must not also be counted as failed"
    assert_contains "$out" "CHILD_EXIT=0" \
        "a suite with only a skip must exit 0"
}

# An assertion failure followed by a non-zero return is ONE failure, not two.
test_assertion_failure_is_not_double_counted() {
    local out
    out=$(run_suite_in_child '
        t_bad() { assert_true false "deliberate failure"; return 1; }
        run_test t_bad "assertion failure then return 1"
    ')
    assert_contains "$out" "Total Tests: 1" \
        "one test was run"
    assert_contains "$out" "Failed:      1" \
        "an assertion failure must be counted exactly once"
    assert_not_contains "$out" "without recording a verdict" \
        "a test that recorded a verdict must not get a second one"
}

# Baseline: a passing test is unaffected.
test_passing_test_unaffected() {
    local out
    out=$(run_suite_in_child '
        t_ok() { assert_true true "ok"; }
        run_test t_ok "passing case"
    ')
    assert_contains "$out" "Passed:      1" "a passing test must be counted as passed"
    assert_contains "$out" "Failed:      0" "a passing test must not be counted as failed"
    assert_contains "$out" "CHILD_EXIT=0" "a passing suite must exit 0"
}

# Backstop: a test_case that never reaches a verdict (bypassing run_test) must
# still fail the suite, even though TESTS_FAILED is 0.
test_report_backstop_fails_unaccounted_tests() {
    local out
    out=$(run_suite_in_child '
        test_case "no verdict ever recorded" >/dev/null
    ')
    assert_contains "$out" "Failed:      0" \
        "the backstop case must reach generate_report with Failed: 0"
    assert_contains "$out" "1 test(s) recorded no verdict" \
        "the report must name the unaccounted gap"
    assert_contains "$out" "CHILD_EXIT=1" \
        "Total != Passed + Failed + Skipped must fail the suite"
}

# Backstop in a mixed suite: a pass alongside an unaccounted test_case must not
# mask the gap — the unaccounted count is computed across the whole suite.
test_report_backstop_mixed_with_pass() {
    local out
    out=$(run_suite_in_child '
        t_ok() { assert_true true "ok"; }
        run_test t_ok "passing case"
        test_case "no verdict ever recorded" >/dev/null
    ')
    assert_contains "$out" "Total Tests: 2" \
        "both the passing test and the bare test_case were run"
    assert_contains "$out" "Passed:      1" \
        "the passing test must still be counted as passed"
    assert_contains "$out" "Failed:      0" \
        "the unaccounted test must not be reclassified as failed"
    assert_contains "$out" "1 test(s) recorded no verdict" \
        "the report must name exactly the one unaccounted test"
    assert_contains "$out" "CHILD_EXIT=1" \
        "a passing test must not mask an unaccounted one"
}

# Backstop alongside a real failure: both conditions are reported and the
# suite fails, with neither counter absorbing the other.
test_report_backstop_with_failure() {
    local out
    out=$(run_suite_in_child '
        t_bad() { assert_true false "deliberate failure"; }
        run_test t_bad "failing case"
        test_case "no verdict ever recorded" >/dev/null
    ')
    assert_contains "$out" "Total Tests: 2" \
        "both the failing test and the bare test_case were run"
    assert_contains "$out" "Failed:      1" \
        "the failing test must be counted exactly once"
    assert_contains "$out" "1 test(s) recorded no verdict" \
        "the unaccounted test must still be reported next to a failure"
    assert_contains "$out" "CHILD_EXIT=1" \
        "a suite with a failure and an unaccounted test must exit 1"
}

run_test test_bare_nonzero_return_counts_as_failed "bare non-zero return counts as failed"
run_test test_undefined_helper_counts_as_failed "undefined helper (127) counts as failed"
run_test test_skip_then_nonzero_stays_skipped "skip then non-zero stays skipped"
run_test test_assertion_failure_is_not_double_counted "assertion failure is not double-counted"
run_test test_passing_test_unaffected "passing test is unaffected"
run_test test_report_backstop_fails_unaccounted_tests "report backstop fails unaccounted tests"
run_test test_report_backstop_mixed_with_pass "report backstop holds with a passing test alongside"
run_test test_report_backstop_with_failure "report backstop holds alongside a real failure"

generate_report
