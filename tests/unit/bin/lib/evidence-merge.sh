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

# Pinned well after every fixture stamp, so none reads as future-skewed.
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
    f=$(command mktemp)
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
    before=$(command mktemp)
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
    before=$(command mktemp)
    command cp "$f" "$before"
    merge_evidence_row "$f" "$(_stamp "$PASS_ROW" 2026-10-15T00:00:00Z)"
    if command cmp -s "$before" "$f"; then
        pass_test
    else
        fail_test "a newer repeated pass changed the file to $(command jq -c . "$f")"
    fi
    command rm -f "$f" "$before"
}

run_test test_older_repeat_is_noop "an older repeated failure is a byte-identical no-op"
run_test test_equal_epoch_repeat_is_noop "an equal-epoch repeated failure is a no-op (the <= boundary)"
run_test test_newer_repeat_refreshes_in_place "a newer repeated failure refreshes its row in place"
run_test test_newer_pass_repeat_is_noop "a newer repeated pass is a no-op"

generate_report
