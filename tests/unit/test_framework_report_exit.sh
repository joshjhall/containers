#!/usr/bin/env bash
# Regression test: a suite's exit status must reflect its TEST RESULTS, never
# the I/O of writing its report.
#
# generate_report is the last command of every suite, and suites run under
# `set -e`, so whatever status it returns becomes the suite's status. It used to
# end with a bare `... | command tee "$report_file"` writing into
# $RESULTS_DIR — which lives in the repo, commonly a virtiofs + bindfs FUSE
# mount whose writes are not reliably visible to the next read (#821). When that
# write hiccuped, a fully passing suite exited non-zero and the harness recorded
# it as ERROR, while the suite's own report read "0 failed". Green on re-run,
# so it looked like an unexplained flake rather than an infrastructure fault.
#
# Measured on the dev container with a write-then-read loop, 8 procs x 400:
# 1 lost / 3200 under tests/results, 0 / 3200 under /tmp.
#
# The properties asserted here are STRUCTURAL and hold on every platform, so
# they still catch a regression on a CI runner where the repo sits on ordinary
# storage and the race never fires.
#
# The framework is exercised in a CHILD shell rather than by re-running
# init_test_framework in this process, which would reset this suite's own
# pass/fail counters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"
init_test_framework

FRAMEWORK_SH="$SCRIPT_DIR/../framework.sh"

test_suite "suite exit status reflects results, not report I/O"

# Run a synthetic suite in a fresh shell and echo its exit code as the last
# line. $body sets up the tests; RESULTS_DIR may be overridden by the caller to
# simulate a broken artifact location. Paths travel through the environment so
# a repo path containing quotes cannot break the -c string.
run_suite_in_child() {
    local body="$1"
    local results_override="${2:-}"
    /usr/bin/env -i \
        PATH="$PATH" \
        HOME="${HOME:-/tmp}" \
        TERM="dumb" \
        SKIP_DOCKER_CHECK=true \
        FRAMEWORK_SH="$FRAMEWORK_SH" \
        RESULTS_OVERRIDE="$results_override" \
        BODY="$body" \
        /bin/bash -c '
            source "$FRAMEWORK_SH" >/dev/null 2>&1
            init_test_framework >/dev/null 2>&1
            [ -n "$RESULTS_OVERRIDE" ] && RESULTS_DIR="$RESULTS_OVERRIDE"
            test_suite "child" >/dev/null 2>&1
            eval "$BODY"
            generate_report
            /usr/bin/echo "CHILD_EXIT=$?"
        ' 2>&1
}

# A passing suite exits 0 — the baseline the other cases are measured against.
test_passing_suite_exits_zero() {
    local out
    out=$(run_suite_in_child '
        t_ok() { assert_true true "ok"; }
        run_test t_ok "passing case" >/dev/null 2>&1
    ')
    assert_contains "$out" "CHILD_EXIT=0" \
        "a suite with no failures must exit 0"
}

# A failing suite still exits non-zero. Without this, a fix that made
# generate_report unconditionally return success would pass every other
# assertion here while disabling the entire test gate.
test_failing_suite_exits_nonzero() {
    local out
    out=$(run_suite_in_child '
        t_bad() { assert_true false "deliberate failure"; }
        run_test t_bad "failing case" >/dev/null 2>&1
    ')
    assert_not_contains "$out" "CHILD_EXIT=0" \
        "a suite with a failed test must NOT exit 0"
}

# The regression itself: a passing suite whose report cannot be written must
# still exit 0. An unwritable RESULTS_DIR stands in for the FUSE write that
# intermittently fails on the real mount.
test_report_io_failure_does_not_fail_a_green_suite() {
    local out
    out=$(run_suite_in_child '
        t_ok() { assert_true true "ok"; }
        run_test t_ok "passing case" >/dev/null 2>&1
    ' "/nonexistent-dir-for-report-io-test")

    assert_contains "$out" "CHILD_EXIT=0" \
        "report write failure must not change a green suite's exit status"
    # The failure must be visible rather than swallowed silently.
    assert_contains "$out" "WARNING" \
        "an unwritable report location should warn"
    # And the results must still reach stdout, which is what the harness parses.
    assert_contains "$out" "Failed:      0" \
        "report body must still be emitted when the file cannot be written"
}

# A failing suite whose report also cannot be written must still exit non-zero:
# the I/O degradation must not become a way to launder real failures.
test_report_io_failure_does_not_mask_a_red_suite() {
    local out
    out=$(run_suite_in_child '
        t_bad() { assert_true false "deliberate failure"; }
        run_test t_bad "failing case" >/dev/null 2>&1
    ' "/nonexistent-dir-for-report-io-test")
    assert_not_contains "$out" "CHILD_EXIT=0" \
        "a failing suite must stay failing even when its report cannot be written"
}

# Staging must resolve somewhere writable, so the report survives a bad
# $RESULTS_DIR instead of being lost with it.
test_staging_dir_is_writable_when_results_dir_is_not() {
    local out
    out=$(run_suite_in_child '
        RESULTS_DIR="/nonexistent-dir-for-report-io-test"
        /usr/bin/echo "staged=$(tf_report_staging_dir)"
        t_ok() { assert_true true "ok"; }
        run_test t_ok "passing case" >/dev/null 2>&1
    ' "/nonexistent-dir-for-report-io-test")

    local staged
    staged=$(/usr/bin/grep '^staged=' <<<"$out" | /usr/bin/cut -d= -f2- | /usr/bin/head -1)
    assert_not_empty "$staged" "tf_report_staging_dir must return a path"
    assert_not_equals "/nonexistent-dir-for-report-io-test" "$staged" \
        "staging must not hand back an unwritable results dir"
    assert_true "[ -w '$staged' ]" "staging dir '$staged' must be writable"
}

run_test test_passing_suite_exits_zero "passing suite exits 0"
run_test test_failing_suite_exits_nonzero "failing suite exits non-zero"
run_test test_report_io_failure_does_not_fail_a_green_suite \
    "report I/O failure does not redden a green suite"
run_test test_report_io_failure_does_not_mask_a_red_suite \
    "report I/O failure does not mask a red suite"
run_test test_staging_dir_is_writable_when_results_dir_is_not \
    "staging dir is writable when results dir is not"

generate_report
