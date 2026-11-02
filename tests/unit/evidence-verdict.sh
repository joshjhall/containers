#!/usr/bin/env bash
# Unit tests for read_evidence_verdict() and annotate_fail_verdict() in bin/lib/evidence-issue.sh — the
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
    if command grep -qxF "result=fail" <<<"$out"; then
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
    if command grep -qxF "error_class=unknown" <<<"$out"; then
        assert_true true "error_class line is exactly 'error_class=unknown'"
    else
        assert_true false "expected exact 'error_class=unknown' line, got: $(command printf '%q' "$out")"
    fi
}

# --- annotate_fail_verdict (#1549) ----------------------------------------
# A fail cell's job concludes `success` by design; annotate_fail_verdict is
# what makes it visible in the Actions UI. Its stdout is parsed by the runner
# as workflow commands, so the injection guard is part of the contract.

test_annotate_fail_emits_error_and_summary() {
    local out rc=0 summary="$TEST_TEMP_DIR/summary.md"
    out="$(GITHUB_STEP_SUMMARY="$summary" \
        annotate_fail_verdict fail unknown node 20.13.1 alpine-3.22-amd64)" || rc=$?
    assert_equals "0" "$rc" "fail verdict returns 0"
    assert_equals \
        "::error title=Evidence fail: node@20.13.1 on alpine-3.22-amd64::install failed (error_class=unknown); a fail row was recorded and the job stays green by design" \
        "$out" "exactly one ::error annotation naming the cell and class"
    assert_file_exists "$summary" "summary file written"
    assert_equals \
        '- :x: `node@20.13.1` on `alpine-3.22-amd64` recorded **fail** (`error_class: unknown`)' \
        "$(command cat "$summary")" "summary line names the cell and class"
}

test_annotate_non_fail_is_silent() {
    local verdict out rc summary="$TEST_TEMP_DIR/summary.md"
    for verdict in pass skip; do
        rc=0
        out="$(GITHUB_STEP_SUMMARY="$summary" \
            annotate_fail_verdict "$verdict" unknown node 20.13.1 alpine-3.22-amd64)" || rc=$?
        assert_equals "0" "$rc" "$verdict verdict returns 0"
        assert_empty "$out" "$verdict verdict emits no annotation"
    done
    assert_file_not_exists "$summary" "no summary line for pass/skip"
}

test_annotate_rejects_injected_coordinates() {
    local out rc summary="$TEST_TEMP_DIR/summary.md" bad
    local -a args
    local pos
    # Each coordinate position (tool=3, version=4, tuple=5) is a free-text
    # dispatch input, so inject into each in turn.
    for pos in 3 4 5; do
        for bad in 'x::add-mask::x' $'x\n::stop-commands::t'; do
            args=(fail unknown node 20.13.1 alpine-3.22-amd64)
            args[pos - 1]="$bad"
            rc=0
            out="$(GITHUB_STEP_SUMMARY="$summary" \
                annotate_fail_verdict "${args[@]}" 2>/dev/null)" || rc=$?
            assert_equals "1" "$rc" "injected arg \$$pos $(command printf '%q' "$bad") → rc 1"
            assert_not_contains "$out" "::" "no workflow command emitted for injected arg \$$pos"
        done
    done
    rc=0
    out="$(GITHUB_STEP_SUMMARY="$summary" \
        annotate_fail_verdict fail 'infra::x' node 20.13.1 alpine-3.22-amd64 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "non-slug error_class → rc 1"
    assert_empty "$out" "no annotation for a non-slug error_class"
    assert_file_not_exists "$summary" "no summary line on a rejected input"
}

test_annotate_without_step_summary() {
    local out rc=0
    out="$(env -u GITHUB_STEP_SUMMARY bash -c \
        'source "$1"; annotate_fail_verdict fail infra node 20.13.1 alpine-3.22-amd64' \
        _ "$PROJECT_ROOT/bin/lib/evidence-issue.sh")" || rc=$?
    assert_equals "0" "$rc" "unset GITHUB_STEP_SUMMARY is not an error"
    assert_equals \
        "::error title=Evidence fail: node@20.13.1 on alpine-3.22-amd64::install failed (error_class=infra); a fail row was recorded and the job stays green by design" \
        "$out" "exact annotation still printed without a step summary"
}

test_empty_error_class_reaches_annotation() {
    # Cross-helper contract: a fail row with an empty error_class must still
    # produce an annotation. `// "unknown"` does not replace "", so
    # read_evidence_verdict has to normalize it, or annotate_fail_verdict's
    # slug check rejects it and the fail cell stays invisible.
    local row out rc=0 ec annotation summary="$TEST_TEMP_DIR/summary.md"
    row="$(write_row '{"result":"fail","error_class":""}')"
    out="$(read_evidence_verdict "$row")" || rc=$?
    assert_equals "0" "$rc" "empty error_class row still validates"
    if command grep -qxF "error_class=unknown" <<<"$out"; then
        assert_true true "empty error_class normalizes to exactly 'error_class=unknown'"
    else
        assert_true false "expected 'error_class=unknown', got: $(command printf '%q' "$out")"
    fi
    ec="$(command sed -n 's/^error_class=//p' <<<"$out")"
    rc=0
    # Pin the summary to scratch: CI's inherited GITHUB_STEP_SUMMARY would
    # otherwise get a fake fail line in the unit-test job's summary.
    annotation="$(GITHUB_STEP_SUMMARY="$summary" \
        annotate_fail_verdict fail "$ec" node 20.13.1 alpine-3.22-amd64)" || rc=$?
    assert_equals "0" "$rc" "normalized class is accepted by annotate_fail_verdict"
    assert_contains "$annotation" "(error_class=unknown)" "annotation carries the normalized class"
    assert_equals \
        '- :x: `node@20.13.1` on `alpine-3.22-amd64` recorded **fail** (`error_class: unknown`)' \
        "$(command cat "$summary")" "summary line carries the normalized class"
}

test_annotate_underscore_error_classes() {
    # luggage's ErrorClass has underscore variants (install_method,
    # post_install). The annotate guard must accept them: a tightening to
    # ^[a-z]+$ would silently drop their annotations, and the workflow step is
    # continue-on-error, so only this test would notice (#1568). Each class is
    # fed through a real row → read_evidence_verdict → annotate_fail_verdict.
    local ec row out rc annotation summary="$TEST_TEMP_DIR/summary.md"
    for ec in install_method post_install; do
        command rm -f "$summary"
        row="$(write_row "{\"result\":\"fail\",\"error_class\":\"$ec\"}")"
        rc=0
        out="$(read_evidence_verdict "$row")" || rc=$?
        assert_equals "0" "$rc" "$ec row validates"
        if command grep -qxF "error_class=$ec" <<<"$out"; then
            assert_true true "$ec is preserved as exactly 'error_class=$ec'"
        else
            assert_true false "expected 'error_class=$ec', got: $(command printf '%q' "$out")"
        fi
        rc=0
        annotation="$(GITHUB_STEP_SUMMARY="$summary" annotate_fail_verdict fail \
            "$(command sed -n 's/^error_class=//p' <<<"$out")" \
            node 20.13.1 alpine-3.22-amd64)" || rc=$?
        assert_equals "0" "$rc" "annotate_fail_verdict accepts $ec"
        assert_equals \
            "::error title=Evidence fail: node@20.13.1 on alpine-3.22-amd64::install failed (error_class=$ec); a fail row was recorded and the job stays green by design" \
            "$annotation" "exact annotation for $ec"
        assert_equals \
            "- :x: \`node@20.13.1\` on \`alpine-3.22-amd64\` recorded **fail** (\`error_class: $ec\`)" \
            "$(command cat "$summary" 2>/dev/null)" "exact summary line for $ec"
    done
}

test_annotate_reject_message_names_annotation() {
    # A rejected annotation must say so: the shared validator used to log
    # "Refusing to file issue", pointing the annotate step's log at the wrong
    # operation (#1568).
    local out rc=0 err
    out="$(annotate_fail_verdict fail unknown 'Bad Tool' 20.13.1 alpine-3.22-amd64 \
        2>"$TEST_TEMP_DIR/err")" || rc=$?
    assert_equals "1" "$rc" "bad tool slug → rc 1"
    assert_empty "$out" "no annotation for a bad tool slug"
    err="$(command cat "$TEST_TEMP_DIR/err")"
    assert_contains "$err" "Refusing to annotate: unexpected tool slug 'Bad Tool'" \
        "reject message names annotation"
    assert_not_contains "$err" "file issue" "reject message does not mention issue filing"
}

test_validate_default_action_is_file_issue() {
    # The issue-filing callers pass no action; their message is unchanged.
    local rc=0 err
    validate_issue_inputs node 20.13.1 'not a tuple' 2>"$TEST_TEMP_DIR/err" || rc=$?
    assert_equals "1" "$rc" "bad tuple → rc 1"
    err="$(command cat "$TEST_TEMP_DIR/err")"
    assert_equals "Refusing to file issue: unexpected tuple 'not a tuple'" "$err" \
        "default action keeps the issue-filing message"
}

# --- Run -------------------------------------------------------------------

run_test test_pass_row "valid pass row → result=pass, error_class=unknown"
run_test test_fail_row_with_error_class "fail row preserves a bare error_class"
run_test test_skip_row "valid skip row → result=skip"
run_test test_unexpected_result_exits_1 "unexpected result → rc 1, no result= emitted"
run_test test_crlf_stripped_from_result "CR/LF stripped from result, no injected line"
run_test test_crlf_and_case_normalize_error_class "CRLF/uppercase error_class → unknown"
run_test test_annotate_fail_emits_error_and_summary "fail verdict → ::error annotation + summary line"
run_test test_annotate_non_fail_is_silent "pass/skip verdict → no annotation, no summary"
run_test test_annotate_rejects_injected_coordinates "injected coordinate/class → rc 1, nothing emitted"
run_test test_annotate_without_step_summary "unset GITHUB_STEP_SUMMARY → annotation only"
run_test test_empty_error_class_reaches_annotation "empty error_class → unknown, still annotated"
run_test test_annotate_underscore_error_classes "install_method/post_install → exact annotation"
run_test test_annotate_reject_message_names_annotation "rejected annotation → 'Refusing to annotate'"
run_test test_validate_default_action_is_file_issue "validator default message still names issue filing"

generate_report
