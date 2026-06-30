#!/usr/bin/env bash
# Unit tests for read_evidence_verdict() in bin/lib/evidence-issue.sh — the
# evidence fail-row verdict read+sanitize logic extracted from
# .github/workflows/evidence-run.yml's "Read evidence verdict" step (#653,
# logic from #652).
#
# read_evidence_verdict reads `result`/`error_class` from a container-produced
# evidence row, strips CR/LF (the GITHUB_OUTPUT key=value injection vector the
# workflow redirects into $GITHUB_OUTPUT), validates result against the
# pass|fail|skip enum, and normalizes a non-[a-z_] error_class to "unknown".
# These guards have no other coverage, so a regression in the tr-strip or the
# enum case would silently weaken the injection defense.
#
# Offline: no gh/network. We write a row JSON to $TEST_TEMP_DIR and call the
# helper, capturing stdout in a subshell with `|| rc=$?` so a `return 1` under
# the helper's `set -e` doesn't abort the suite. Real jq is used.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../framework.sh
source "$SCRIPT_DIR/../framework.sh"

SKIP_DOCKER_CHECK=true init_test_framework

test_suite "bin/lib/evidence-issue.sh read_evidence_verdict"

# shellcheck source=../../bin/lib/evidence-issue.sh
source "$PROJECT_ROOT/bin/lib/evidence-issue.sh"

# Write a row JSON ($1) to a temp file and echo its path. Uses printf so the
# caller can embed literal \r / \n escape sequences in the value.
write_row() {
    local json="$1"
    local f="$TEST_TEMP_DIR/row.json"
    command printf '%s' "$json" >"$f"
    echo "$f"
}

# --- Tests -----------------------------------------------------------------

test_pass_row() {
    local row out rc=0
    row="$(write_row '{"result":"pass"}')"
    out="$(read_evidence_verdict "$row")" || rc=$?
    assert_equals "0" "$rc" "valid pass row returns 0"
    assert_contains "$out" "result=pass" "pass row emits result=pass"
    # A pass row has no error_class field → defaulted to unknown.
    assert_contains "$out" "error_class=unknown" "pass row defaults error_class to unknown"
}

test_fail_row_with_error_class() {
    local row out rc=0
    row="$(write_row '{"result":"fail","error_class":"verify"}')"
    out="$(read_evidence_verdict "$row")" || rc=$?
    assert_equals "0" "$rc" "valid fail row returns 0"
    assert_contains "$out" "result=fail" "fail row emits result=fail"
    assert_contains "$out" "error_class=verify" "a bare [a-z_] error_class is preserved"
}

test_skip_row() {
    local row out rc=0
    row="$(write_row '{"result":"skip"}')"
    out="$(read_evidence_verdict "$row")" || rc=$?
    assert_equals "0" "$rc" "valid skip row returns 0"
    assert_contains "$out" "result=skip" "skip row emits result=skip"
}

test_unexpected_result_exits_1() {
    local row out rc=0
    row="$(write_row '{"result":"bogus"}')"
    out="$(read_evidence_verdict "$row" 2>"$TEST_TEMP_DIR/err")" || rc=$?
    assert_equals "1" "$rc" "an unexpected result returns 1"
    assert_not_contains "$out" "result=" "no result= is emitted on an unexpected verdict"
    local err
    err="$(command cat "$TEST_TEMP_DIR/err")"
    assert_contains "$err" "Unexpected result" "stderr explains the unexpected result"
}

test_crlf_stripped_from_result() {
    # A result value carrying embedded CR/LF: the strip must collapse it to the
    # bare enum token so it can't inject a second key=value line into
    # $GITHUB_OUTPUT. jq -r renders \r\n as real CR/LF, then tr -d removes them.
    local row out rc=0
    row="$(write_row '{"result":"fail\r\n"}')"
    out="$(read_evidence_verdict "$row")" || rc=$?
    assert_equals "0" "$rc" "fail\\r\\n still validates as fail after strip"
    # The result line must be exactly "result=fail" — no trailing CR, no
    # injected second line. Grep for an exact-line match.
    if command printf '%s\n' "$out" | command grep -qxF "result=fail"; then
        assert_true true "result line is exactly 'result=fail' (CR/LF stripped)"
    else
        assert_true false "expected an exact 'result=fail' line, got: $(command printf '%q' "$out")"
    fi
    assert_not_contains "$out" $'\r' "no carriage return survives in the output"
}

test_crlf_and_case_normalize_error_class() {
    # error_class carrying CR/LF or uppercase/punct is not a bare [a-z_] slug,
    # so it normalizes to "unknown" (informational, never a gate). Covers both
    # the CR/LF strip and the case "$ERROR_CLASS" in *[!a-z_]*) guard.
    local row out rc=0
    row="$(write_row '{"result":"fail","error_class":"Verify-2\r\n"}')"
    out="$(read_evidence_verdict "$row")" || rc=$?
    assert_equals "0" "$rc" "row still validates"
    assert_contains "$out" "error_class=unknown" \
        "an uppercase/punct/CRLF error_class normalizes to unknown"
    if command printf '%s\n' "$out" | command grep -qxF "error_class=unknown"; then
        assert_true true "error_class line is exactly 'error_class=unknown'"
    else
        assert_true false "expected exact 'error_class=unknown' line, got: $(command printf '%q' "$out")"
    fi
}

# --- Run -------------------------------------------------------------------

run_test test_pass_row "valid pass row → result=pass, error_class=unknown"
run_test test_fail_row_with_error_class "fail row preserves a bare error_class"
run_test test_skip_row "valid skip row → result=skip"
run_test test_unexpected_result_exits_1 "unexpected result → rc 1, no result= emitted"
run_test test_crlf_stripped_from_result "CR/LF stripped from result, no injected line"
run_test test_crlf_and_case_normalize_error_class "CRLF/uppercase error_class → unknown"

generate_report
