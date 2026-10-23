#!/usr/bin/env bash
# Unit tests for bin/lib/evidence-epoch.sh — the one tested_at → epoch parse
# shared by the evidence matrix's fail cooldown and ingest's repeated-failure
# ordering (#1355). Expected epochs were computed independently with GNU
# `date -u -d`, not by the def under test.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

init_test_framework

test_suite "Bin Lib Evidence Epoch Tests"

# shellcheck source=bin/lib/evidence-epoch.sh
source "$PROJECT_ROOT/bin/lib/evidence-epoch.sh"

# _epoch <tested_at-json> — evidence_epoch of a row whose tested_at is the
# given JSON value (`null` drops the field).
_epoch() {
    command jq -n --argjson t "$1" \
        "$_EVIDENCE_EPOCH_JQ"'(if $t == null then {} else {tested_at: $t} end) | evidence_epoch'
}

test_accepted_forms() {
    assert_equals "1790812800" "$(_epoch '"2026-10-01T00:00:00Z"')" "Z"
    assert_equals "1790812800" "$(_epoch '"2026-10-01T00:00:00.123456789Z"')" \
        "fractional seconds are dropped"
    assert_equals "1790809200" "$(_epoch '"2026-10-01T01:00:00+02:00"')" \
        "a + offset is subtracted"
    assert_equals "1790818200" "$(_epoch '"2026-10-01T00:30:00.5-01:00"')" \
        "a - offset with a fraction is added"
    assert_equals "1790812800" "$(_epoch '"2026-10-01T14:00:00+14:00"')" "+14:00 is the upper bound"
    assert_equals "1790812800" "$(_epoch '"2026-09-30T12:00:00-12:00"')" "-12:00 is the lower bound"
    assert_equals "1709164800" "$(_epoch '"2024-02-29T00:00:00Z"')" "a real leap day"
}

test_rejected_forms_read_as_zero() {
    local t
    for t in '"2026-10-01T14:00:00+14:01"' '"2026-10-01T00:00:00-12:01"' \
        '"2026-10-01T00:00:00+02:60"' '"2026-10-01T00:00:00+0200"' \
        '"2026-10-01T00:00:00z"' '"2026-10-01 00:00:00Z"' '"2026-02-30T00:00:00Z"' \
        '"2025-02-29T00:00:00Z"' '"yesterday"' '""' 'null' '1790812800'; do
        assert_equals "0" "$(_epoch "$t")" "tested_at $t reads as epoch 0"
    done
}

test_callers_have_no_copy_of_their_own() {
    # The drift #1355 closes: a second def that only its own caller exercises.
    # Any bin script defining its own *epoch jq def, or carrying the parse's
    # offset capture, fails here. (Plain fromdateiso8601 is not the signature:
    # evidence_open_prs uses it on GitHub's always-Z createdAt.)
    local lib copies=""
    for lib in "$PROJECT_ROOT"/bin/*.sh "$PROJECT_ROOT"/bin/lib/*.sh; do
        [ "$lib" = "$PROJECT_ROOT/bin/lib/evidence-epoch.sh" ] && continue
        if command grep -Eq 'def [A-Za-z_]*epoch[A-Za-z_]*:|\(\?<z>Z\|' "$lib"; then
            copies="$copies ${lib#"$PROJECT_ROOT"/}"
        fi
    done
    assert_equals "" "$copies" "no bin script carries its own tested_at epoch parse"
}

test_both_callers_use_the_shared_def() {
    # Sourced in a subshell each, the way the workflow and ingest scripts do.
    local matrix merge
    matrix=$(
        unset _EVIDENCE_EPOCH_JQ
        # shellcheck source=bin/lib/evidence-matrix.sh
        source "$PROJECT_ROOT/bin/lib/evidence-matrix.sh"
        command jq -cn "$_EM_EVIDENCE_JQ"'[
            {os: "debian", os_version: "13", arch: "amd64", result: "fail", tested_at: "2026-10-01T01:00:00+02:00"},
            {os: "debian", os_version: "13", arch: "arm64", result: "fail", tested_at: "2026-02-30T00:00:00Z"}
        ] | em_evidence | .fail'
    )
    assert_equals '{"debian-13-amd64":1790809200,"debian-13-arm64":0}' "$matrix" \
        "the matrix fail map uses evidence_epoch"

    # merge: a stored fail at 2026-09-30T23:30:00Z, then a repeat whose
    # wall clock is earlier but whose instant (00:30-01:00 = 01:30Z) is later.
    local f row stored newer
    f=$(command mktemp)
    row='{"os":"debian","os_version":"13","arch":"amd64","image_digest":"sha256:aa","result":"fail","error_class":"verify"}'
    stored=$(command jq -c '. + {tested_at: "2026-10-01T01:30:00+02:00"}' <<<"$row")
    newer=$(command jq -c '. + {tested_at: "2026-10-01T00:30:00-01:00"}' <<<"$row")
    command jq -n --argjson a "$stored" '{tested: [$a]}' >"$f"
    merge=$(
        unset _EVIDENCE_EPOCH_JQ
        # shellcheck source=bin/lib/evidence-merge.sh
        source "$PROJECT_ROOT/bin/lib/evidence-merge.sh"
        merge_evidence_row "$f" "$newer" && command jq -r '.tested[0].tested_at' "$f"
    )
    command rm -f "$f"
    assert_equals "2026-10-01T00:30:00-01:00" "$merge" \
        "ingest orders repeated failures by evidence_epoch"
}

test_setup_sparse_checkout_carries_matrix_deps() {
    # The evidence-run setup job sources evidence-matrix.sh from a sparse
    # checkout, so every sibling it sources must be listed there too, or the
    # matrix step dies on a missing file that the unit tests (full checkout)
    # never notice. Siblings are read from the lib's own source lines, so a
    # future dependency is covered without editing this test.
    local wf="$PROJECT_ROOT/.github/workflows/evidence-run.yml" listed deps dep missing=""
    listed=$(command awk '
        /sparse-checkout: \|/ { if (!seen) { inlist = 1; seen = 1 }; next }
        inlist && /^ *[A-Za-z0-9_.\/-]+ *$/ { gsub(/ /, ""); print; next }
        inlist { inlist = 0 }
    ' "$wf")
    deps=$(command sed -n 's|^source "$(dirname "${BASH_SOURCE\[0\]}")/\([^"]*\)"$|bin/lib/\1|p' \
        "$PROJECT_ROOT/bin/lib/evidence-matrix.sh")
    assert_equals "bin/lib/evidence-epoch.sh" "$deps" \
        "evidence-matrix.sh sources exactly the shared epoch lib"
    for dep in bin/lib/evidence-matrix.sh $deps; do
        command grep -qxF "$dep" <<<"$listed" || missing="$missing $dep"
    done
    assert_equals "" "$missing" "the setup job's sparse checkout lists the matrix lib and its deps"
}

run_test test_accepted_forms "accepted tested_at forms parse to the UTC instant"
run_test test_rejected_forms_read_as_zero "near-miss and non-string tested_at read as epoch 0"
run_test test_callers_have_no_copy_of_their_own "no other bin script defines its own epoch parse"
run_test test_both_callers_use_the_shared_def "matrix and ingest both source the shared def"
run_test test_setup_sparse_checkout_carries_matrix_deps "setup sparse checkout carries the matrix lib's sourced deps"

generate_report
