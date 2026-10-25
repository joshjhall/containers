#!/usr/bin/env bash
# Unit tests for bin/lib/evidence-merge.sh — merge_evidence_row's repeated-
# failure ordering (#1326, #1355). A repeat of a stored fail row refreshes it
# only when its tested_at instant is strictly newer; an older or equal one is a
# byte-identical no-op. tests/unit/ingest-evidence.sh drives the same function
# through the ingest scripts; this suite is the one the push-time changed-test
# run selects for an edit to the lib (#1386).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

init_test_framework

test_suite "Bin Lib Evidence Merge Tests"

# shellcheck source=bin/lib/evidence-merge.sh
source "$PROJECT_ROOT/bin/lib/evidence-merge.sh"

# Pinned after every fixture stamp except the deliberate 2030 future ones.
export EVIDENCE_NOW=1793491200 # 2026-11-01T00:00:00Z

FAIL_ROW='{"os":"debian","os_version":"13","arch":"amd64","image_digest":"sha256:aa","result":"fail","error_class":"verify"}'
PASS_ROW='{"os":"debian","os_version":"13","arch":"arm64","image_digest":"sha256:bb","result":"pass"}'

# _stamp <row-json> <tested_at> — the row with that tested_at.
_stamp() {
    command jq -c --arg t "$2" '. + {tested_at: $t}' <<<"$1"
}

# _version_file <row-json>... — a scratch version file holding those rows, in
# order. Seeded through merge_evidence_row itself (the rows have distinct dedup
# keys, so each appends) so the file is already in the lib's byte format and a
# later no-op merge compares equal under cmp.
_version_file() {
    local f row
    f=$(command mktemp "$TEST_SCRATCH_BASE/evidence-merge.XXXXXX")
    command echo '{"tested": []}' >"$f"
    for row in "$@"; do
        merge_evidence_row "$f" "$row"
    done
    command echo "$f"
}

# The stored failure: 2026-10-01T01:00:00+02:00 is the instant 2026-09-30T23:00:00Z.
STORED_AT="2026-10-01T01:00:00+02:00"

# _assert_noop <incoming-tested_at> <message> — merging a repeat of the stored
# failure stamped so leaves the file byte-identical.
_assert_noop() {
    local f before
    f=$(_version_file "$(_stamp "$PASS_ROW" 2026-09-29T00:00:00Z)" "$(_stamp "$FAIL_ROW" "$STORED_AT")")
    before=$(command mktemp "$TEST_SCRATCH_BASE/evidence-merge.XXXXXX")
    command cp "$f" "$before"
    merge_evidence_row "$f" "$(_stamp "$FAIL_ROW" "$1")"
    if command cmp -s "$before" "$f"; then
        pass_test
    else
        fail_test "$2: file changed to $(command jq -c . "$f")"
    fi
    command rm -f "$f" "$before"
}

test_older_repeat_is_noop() {
    _assert_noop "2026-09-30T22:00:00Z" "an older repeated failure must not move tested_at backwards"
}

test_equal_epoch_repeat_is_noop() {
    # Same instant, different spelling: a `<` in place of `<=` would rewrite
    # tested_at to this string, so the byte compare discriminates the boundary.
    _assert_noop "2026-09-30T23:00:00Z" "an equal-epoch repeated failure is a no-op"
}

test_newer_repeat_refreshes_in_place() {
    local f out
    f=$(_version_file "$(_stamp "$PASS_ROW" 2026-09-29T00:00:00Z)" "$(_stamp "$FAIL_ROW" "$STORED_AT")")
    merge_evidence_row "$f" "$(_stamp "$FAIL_ROW" 2026-09-30T23:00:01Z)"
    out=$(command jq -c '[.tested[] | [.arch, .result, .tested_at]]' "$f")
    command rm -f "$f"
    assert_equals '[["arm64","pass","2026-09-29T00:00:00Z"],["amd64","fail","2026-09-30T23:00:01Z"]]' "$out" \
        "a newer repeated failure refreshes its row in place, order kept"
}

test_newer_pass_repeat_is_noop() {
    # The refresh is fail-only: a pass repeat carries no cooldown timestamp.
    local f before
    f=$(_version_file "$(_stamp "$PASS_ROW" 2026-09-29T00:00:00Z)")
    before=$(command mktemp "$TEST_SCRATCH_BASE/evidence-merge.XXXXXX")
    command cp "$f" "$before"
    merge_evidence_row "$f" "$(_stamp "$PASS_ROW" 2026-10-15T00:00:00Z)"
    if command cmp -s "$before" "$f"; then
        pass_test
    else
        fail_test "a newer repeated pass changed the file to $(command jq -c . "$f")"
    fi
    command rm -f "$f" "$before"
}

test_changed_core_replaces_even_when_older() {
    # A different non-volatile field is fresh signal: the row is replaced
    # whatever its tested_at, which the ordering branch would have no-op'd.
    local f out
    f=$(_version_file "$(_stamp "$FAIL_ROW" "$STORED_AT")")
    merge_evidence_row "$f" "$(command jq -c '. + {error_class: "build", tested_at: "2026-09-01T00:00:00Z"}' <<<"$FAIL_ROW")"
    out=$(command jq -c '[.tested[] | [.error_class, .tested_at]]' "$f")
    command rm -f "$f"
    assert_equals '[["build","2026-09-01T00:00:00Z"]]' "$out" \
        "a repeat with a changed error_class replaces the row"
}

test_future_stamp_reads_as_stale() {
    # #1356: a stored stamp past EVIDENCE_NOW + skew reads as 0, so a genuine
    # repeat refreshes it; an incoming future stamp reads as 0 and is a no-op.
    local f out
    f=$(_version_file "$(_stamp "$FAIL_ROW" 2030-01-01T00:00:00Z)")
    merge_evidence_row "$f" "$(_stamp "$FAIL_ROW" 2026-10-20T00:00:00Z)"
    out=$(command jq -c '[.tested[].tested_at]' "$f")
    command rm -f "$f"
    assert_equals '["2026-10-20T00:00:00Z"]' "$out" "a stored future stamp is refreshed by a real repeat"

    _assert_noop "2030-01-01T00:00:00Z" "an incoming future stamp must not pin the row"
}

# _assert_rejected <row-json> <evidence-now> <stderr-fragment> <message> — the
# merge returns 2, names the problem on stderr, and leaves the file untouched.
_assert_rejected() {
    local f before err rc=0
    f=$(_version_file "$(_stamp "$FAIL_ROW" "$STORED_AT")")
    before=$(command mktemp "$TEST_SCRATCH_BASE/evidence-merge.XXXXXX")
    err=$(command mktemp "$TEST_SCRATCH_BASE/evidence-merge.XXXXXX")
    command cp "$f" "$before"
    EVIDENCE_NOW="$2" merge_evidence_row "$f" "$1" 2>"$err" || rc=$?
    assert_equals "2" "$rc" "$4: return code"
    assert_contains "$(command cat "$err")" "$3" "$4: stderr names the problem"
    if command cmp -s "$before" "$f"; then
        pass_test
    else
        fail_test "$4: file changed to $(command jq -c . "$f")"
    fi
    command rm -f "$f" "$before" "$err"
}

test_invalid_input_is_rejected() {
    _assert_rejected 'not json' "$EVIDENCE_NOW" "row is not valid JSON" "a non-JSON row"
    local field
    for field in os arch result; do
        _assert_rejected "$(command jq -c --arg k "$field" 'del(.[$k])' <<<"$FAIL_ROW")" "$EVIDENCE_NOW" \
            "missing required" "a row without .$field"
    done
    _assert_rejected "$(_stamp "$FAIL_ROW" 2026-10-20T00:00:00Z)" "abc" \
        "EVIDENCE_NOW must be 1-12 digits" "a non-numeric EVIDENCE_NOW"
    _assert_rejected "$(_stamp "$FAIL_ROW" 2026-10-20T00:00:00Z)" "1234567890123" \
        "EVIDENCE_NOW must be 1-12 digits" "a 13-digit EVIDENCE_NOW"
}

test_tuple_slug() {
    assert_equals "debian-13-amd64" "$(evidence_tuple_slug "$FAIL_ROW")" "with os_version"
    assert_equals "debian-amd64" "$(evidence_tuple_slug "$(command jq -c 'del(.os_version)' <<<"$FAIL_ROW")")" \
        "without os_version"
}

run_test test_older_repeat_is_noop "an older repeated failure is a byte-identical no-op"
run_test test_equal_epoch_repeat_is_noop "an equal-epoch repeated failure is a no-op (the <= boundary)"
run_test test_newer_repeat_refreshes_in_place "a newer repeated failure refreshes its row in place"
run_test test_newer_pass_repeat_is_noop "a newer repeated pass is a no-op"
run_test test_changed_core_replaces_even_when_older "a changed non-volatile field replaces the row"
run_test test_future_stamp_reads_as_stale "a future tested_at on either side reads as stale"
run_test test_invalid_input_is_rejected "invalid rows and EVIDENCE_NOW return 2 and leave the file untouched"
run_test test_tuple_slug "evidence_tuple_slug drops an absent os_version"

generate_report
