#!/usr/bin/env bash
# Unit tests: evidence_matrix_all in bin/lib/evidence-matrix.sh merges every
# versioned tool's pending cells into one matrix (#1341) — round-robin under the
# cap, untested cells before failure retries, one PR dry-run leg per tool — and
# keeps the shipped catalog within GitHub's 256-job limit.
#
# Split from evidence-matrix.sh (#1381); fixtures are shared via
# tests/lib/evidence-matrix-fixtures.sh. Hermetic, with exact expected cells.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

init_test_framework

test_suite "Evidence matrix (every tool)"

# shellcheck source=bin/lib/evidence-matrix.sh
source "$PROJECT_ROOT/bin/lib/evidence-matrix.sh"
# Tests that rely on the vendored tested[] path must not inherit a source.
unset EVIDENCE_TESTED_SOURCE EVIDENCE_PUBLISHED_CHECK
# shellcheck source=tests/lib/evidence-matrix-fixtures.sh
source "$PROJECT_ROOT/tests/lib/evidence-matrix-fixtures.sh"

test_all_tools_covers_every_versioned_tool() {
    # #1341: go legs alongside rust legs; a system_package entry (index, no
    # versions/) is not a luggage tool and contributes nothing.
    local r out
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    command mkdir -p "$r/catalog/tools/gcc"
    command echo '{"id":"gcc"}' >"$r/catalog/tools/gcc/index.json"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    _version "$r/catalog" 1.23.4 debian-13-arm64 "" go
    out="$(evidence_matrix_all "$r/catalog" "$r" v9)"
    assert_equals $'go 1.23.4 debian-13-arm64\nrust 1.90.0 debian-13-amd64' "$(_tool_cells "$out")" \
        "one leg per pending cell of each tool with a versions/ dir"
    assert_equals \
        '{"tool":"go","version":"1.23.4","tuple":"debian-13-arm64","image_tag":"v9","arch":"arm64","runner":"ubuntu-24.04-arm","runtime":"native","rust_target":"aarch64-unknown-linux-musl"}' \
        "$(command jq -c '.include[0]' <<<"$out")" \
        "a go leg carries the same arch plumbing (rust_target builds luggage itself)"
}

test_all_tools_cap_interleaves_tools() {
    # The cap covers the merged set, and no tool's backlog takes all of it:
    # grouping by tool would give go both of its cells before any rust, and
    # grouping by version would put every go cell (1.x < 1.80) first too.
    local r out err
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.80.0 debian-13-amd64,debian-13-arm64
    _version "$r/catalog" 1.81.0 debian-13-amd64,debian-13-arm64
    _version "$r/catalog" 1.23.4 debian-13-amd64,debian-13-arm64 "" go
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(evidence_matrix_all "$r/catalog" "$r" latest 3 2>"$err")"
    assert_equals $'go 1.23.4 debian-13-amd64\nrust 1.80.0 debian-13-amd64\ngo 1.23.4 debian-13-arm64' \
        "$(_tool_cells "$out")" \
        "round-robin across tools, each tool oldest first, capped at max_cells"
    assert_equals "evidence_matrix: 6 pending cells for go rust; running the first 3 this time (untested before failure retries, oldest first)" \
        "$(command cat "$err")" "the cap line counts the merged set and names every tool"
}

test_all_tools_retries_after_every_untested() {
    # A stale failure in one tool still waits behind never-tested cells of
    # every tool, however deep the other tool's untested queue.
    local r db out
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.80.0 debian-13-amd64
    _version "$r/catalog" 1.81.0 debian-13-amd64
    _version "$r/catalog" 1.23.4 debian-13-amd64,debian-13-arm64 "" go
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.80.0 "" debian-13-amd64 2026-09-01T00:00:00Z
    _db_version "$db" 1.81.0 ""
    _db_version "$db" 1.23.4 "" "" "" go
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix_all "$r/catalog" "$r")"
    assert_equals $'go 1.23.4 debian-13-amd64\nrust 1.81.0 debian-13-amd64\ngo 1.23.4 debian-13-arm64\nrust 1.80.0 debian-13-amd64' \
        "$(_tool_cells "$out")" \
        "untested cells of all tools first, the retry last"
    assert_equals "0" "$(command jq '[.include[] | select(has("retry") or has("rank"))] | length' <<<"$out")" \
        "sort keys are not emitted into the matrix"
}

test_all_tools_retries_interleave_too() {
    # Ranks restart inside the retry group, so retries round-robin across tools
    # like untested cells do. Ranked over each tool's whole list instead, go's
    # retry would sit at rank 2 behind its own untested cells, and rust's
    # retry (rank 0) would jump ahead of it.
    local r db out
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.80.0 debian-13-amd64
    _version "$r/catalog" 1.22.9 debian-13-amd64 "" go
    _version "$r/catalog" 1.23.4 debian-13-amd64,debian-13-arm64 "" go
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.80.0 "" debian-13-amd64 2026-09-01T00:00:00Z
    _db_version "$db" 1.22.9 "" debian-13-amd64 2026-09-01T00:00:00Z go
    _db_version "$db" 1.23.4 "" "" "" go
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix_all "$r/catalog" "$r")"
    assert_equals $'go 1.23.4 debian-13-amd64\ngo 1.23.4 debian-13-arm64\ngo 1.22.9 debian-13-amd64\nrust 1.80.0 debian-13-amd64' \
        "$(_tool_cells "$out")" \
        "each tool's first retry ranks 0 within the retry group"
}

test_all_tools_probe_publication_once() {
    # The publish check runs once per tuple for the whole run, not once per
    # tool: every tool must judge a tuple against the same answer.
    local r out calls
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.90.0 debian-13-amd64
    _version "$r/catalog" 1.23.4 debian-13-amd64 "" go
    calls="$(command mktemp "$TEST_TEMP_DIR/calls.XXXXXX")"
    _count_published() { command echo "$1" >>"$calls"; }
    out="$(EVIDENCE_PUBLISHED_CHECK=_count_published evidence_matrix_all "$r/catalog" "$r")"
    assert_equals $'go 1.23.4 debian-13-amd64\nrust 1.90.0 debian-13-amd64' "$(_tool_cells "$out")" \
        "both tools' legs are produced"
    assert_equals $'alpine-3.24-amd64\ndebian-13-amd64\ndebian-13-arm64' "$(command sort "$calls")" \
        "each of the fixture's three tuples is probed exactly once"
}

test_pr_legs_one_per_tool() {
    # The PR dry-run keeps each tool's first cell. The real merged order puts
    # go first on a rank tie, so the first-cell-overall shape would be go only.
    local r out
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.80.0 debian-13-amd64,debian-13-arm64
    _version "$r/catalog" 1.23.4 debian-13-amd64,debian-13-arm64 "" go
    out="$(evidence_matrix_all "$r/catalog" "$r" | evidence_pr_legs)"
    assert_equals $'go 1.23.4 debian-13-amd64\nrust 1.80.0 debian-13-amd64' "$(_tool_cells "$out")" \
        "exactly one leg per tool, each that tool's first pending cell"
    assert_equals '{"include":[]}' "$(evidence_pr_legs <<<'{"include":[]}')" \
        "an empty matrix stays empty"
}

test_pr_legs_take_first_cell_not_min() {
    # The first pending cell is not always the lexical minimum: a stale-failure
    # retry of an older version sorts after a never-tested newer one. A leg
    # picked by min_by would be go 1.22.9; the first cell is go 1.23.4.
    local r db out
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.80.0 debian-13-amd64
    _version "$r/catalog" 1.22.9 debian-13-amd64 "" go
    _version "$r/catalog" 1.23.4 debian-13-arm64 "" go
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.80.0 ""
    _db_version "$db" 1.22.9 "" debian-13-amd64 2026-09-01T00:00:00Z go
    _db_version "$db" 1.23.4 "" "" "" go
    out="$(EVIDENCE_NOW="$_NOW" EVIDENCE_TESTED_SOURCE="$db" evidence_matrix_all "$r/catalog" "$r")"
    assert_equals $'go 1.23.4 debian-13-arm64\nrust 1.80.0 debian-13-amd64\ngo 1.22.9 debian-13-amd64' \
        "$(_tool_cells "$out")" "precondition: go's retry sorts after its untested cell"
    assert_equals $'go 1.23.4 debian-13-arm64\nrust 1.80.0 debian-13-amd64' \
        "$(_tool_cells "$(evidence_pr_legs <<<"$out")")" \
        "the go PR leg is go's first pending cell, not its lexical minimum"
}

test_available_tuples_json_propagates_failure() {
    # A first-stage failure must not read as "no tuples available". Defensive:
    # today's _em_available_tuples cannot exit non-zero (an unpublished tuple
    # is skipped, not failed), so the stub pins the contract for a future one.
    local r rc=0 out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64
    out="$(
        _em_available_tuples() { return 1; }
        _em_available_tuples_json "$r"
    )" || rc=$?
    assert_equals "1" "$rc" "a failing tuple scan fails the JSON wrapper"
    assert_equals "" "$out" "and prints no array"

    # Both callers stop on it, rather than leaning on jq rejecting an empty
    # --argjson further down (that path would print jq's own error here).
    rc=0
    out="$(
        _em_available_tuples() { return 1; }
        evidence_matrix "$r/catalog" rust "$r" 2>&1
    )" || rc=$?
    assert_equals "1" "$rc" "evidence_matrix fails on a failing tuple scan"
    assert_equals "" "$out" "before reaching the matrix jq, and prints nothing"
    rc=0
    out="$(
        _em_available_tuples() { return 1; }
        evidence_matrix_all "$r/catalog" "$r" 2>&1
    )" || rc=$?
    assert_equals "1" "$rc" "evidence_matrix_all fails on a failing tuple scan"
    assert_equals "" "$out" "and prints nothing"

    assert_equals '["alpine-3.24-amd64","debian-13-amd64","debian-13-arm64"]' \
        "$(_em_available_tuples_json "$r")" "the fixture's tuples, as before"
    local empty
    empty="$(command mktemp -d "$TEST_TEMP_DIR/empty.XXXXXX")"
    assert_equals "[]" "$(_em_available_tuples_json "$empty")" "no base images is an empty array"
}

test_all_tools_exit_3_only_when_all_covered() {
    local r out err rc=0
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.90.0 debian-13-amd64 debian-13-amd64
    _version "$r/catalog" 1.23.4 debian-13-amd64 "" go
    out="$(evidence_matrix_all "$r/catalog" "$r")"
    assert_equals "go 1.23.4 debian-13-amd64" "$(_tool_cells "$out")" \
        "a fully covered tool does not stop another tool's legs"

    _version "$r/catalog" 1.23.4 debian-13-amd64 debian-13-amd64 go
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(evidence_matrix_all "$r/catalog" "$r" 2>"$err")" || rc=$?
    assert_equals "3" "$rc" "every tool covered is exit 3"
    assert_equals "" "$out" "and prints no matrix"
    assert_equals "evidence_matrix: go rust has no pending evidence cells" \
        "$(command cat "$err")" "and says so for the merged set of tools"
}

test_all_tools_one_failing_tool_is_an_error() {
    # A published source with no go evidence must fail the run, not quietly
    # drop go and ship a rust-only matrix.
    local r db out err rc=0
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.90.0 debian-13-amd64
    _version "$r/catalog" 1.23.4 debian-13-amd64 "" go
    db="$(command mktemp -d "$TEST_TEMP_DIR/db.XXXXXX")"
    _db_version "$db" 1.90.0 ""
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(EVIDENCE_TESTED_SOURCE="$db" evidence_matrix_all "$r/catalog" "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "one tool's unreadable evidence is exit 1"
    assert_equals "" "$out" "and prints no partial matrix"
    assert_equals "evidence_matrix: $db has no tools/go; go was vendored before containers-db main has it — merge its containers-db PR first" \
        "$(command cat "$err")" "and the failure names go and the fix, not some other exit 1"

    # Tools exist, but only system_package-style ones (index.json, no
    # versions/): nothing to evidence is an error, not "nothing pending".
    local only
    only="$(command mktemp -d "$TEST_TEMP_DIR/only.XXXXXX")"
    command mkdir -p "$only/tools/gcc"
    command echo '{"id":"gcc"}' >"$only/tools/gcc/index.json"
    rc=0
    out="$(evidence_matrix_all "$only" "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "a catalog with no versioned tools is exit 1, not exit 3"
    assert_equals "evidence_matrix: no tools with a versions/ directory in $only" \
        "$(command cat "$err")" "with a message saying no tool is versioned"
}

test_pr_source_predating_a_tool_adds_nothing() {
    # An ingest PR branched before go reached containers-db has a tools/ tree
    # with rust but no go. It must not fail the run; its rust rows still count.
    local r main pr out err rc=0
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64
    _version "$r/catalog" 1.23.4 debian-13-amd64 "" go
    main="$(command mktemp -d "$TEST_TEMP_DIR/main.XXXXXX")"
    pr="$(command mktemp -d "$TEST_TEMP_DIR/pr.XXXXXX")"
    _db_version "$main" 1.90.0 ""
    _db_version "$main" 1.23.4 "" "" "" go
    _db_version "$pr" 1.90.0 debian-13-amd64
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(EVIDENCE_TESTED_SOURCE="$main:$pr" evidence_matrix_all "$r/catalog" "$r" 2>"$err")" || rc=$?
    assert_equals "0" "$rc" "a PR source without the tool is not an error"
    assert_equals $'go 1.23.4 debian-13-amd64\nrust 1.90.0 debian-13-arm64' "$(_tool_cells "$out")" \
        "go comes from main; the PR's rust pass still covers its cell"
    assert_equals "evidence_matrix: $pr predates go (no tools/go); it adds no go evidence" \
        "$(command cat "$err")" "and the skip is said, not silent"
}

test_missing_tool_stays_strict_where_it_must() {
    # The leniency is only for a later source with a readable tools/ tree and
    # no trace of the tool. Main, a tree with no tools/, or a tool dir with no
    # version files are still errors (#1319).
    local r main pr err rc
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.90.0 debian-13-amd64
    _version "$r/catalog" 1.23.4 debian-13-amd64 "" go
    main="$(command mktemp -d "$TEST_TEMP_DIR/main.XXXXXX")"
    pr="$(command mktemp -d "$TEST_TEMP_DIR/pr.XXXXXX")"
    _db_version "$main" 1.90.0 ""
    _db_version "$pr" 1.90.0 ""
    _db_version "$pr" 1.23.4 "" "" "" go
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"

    rc=0
    EVIDENCE_TESTED_SOURCE="$main:$pr" evidence_matrix_all "$r/catalog" "$r" >/dev/null 2>"$err" || rc=$?
    assert_equals "1" "$rc" "main (the first source) missing a tool is still exit 1"
    assert_equals "evidence_matrix: $main has no tools/go; go was vendored before containers-db main has it — merge its containers-db PR first" \
        "$(command cat "$err")" "main's guard fired, naming the tool and the fix"

    _db_version "$main" 1.23.4 "" "" "" go
    rc=0
    EVIDENCE_TESTED_SOURCE="$main:$TEST_TEMP_DIR/no-such-pr" evidence_matrix_all "$r/catalog" "$r" >/dev/null 2>"$err" || rc=$?
    assert_equals "1" "$rc" "a later source with no tools/ tree at all is still exit 1"
    assert_equals "evidence_matrix: no published evidence for go at $TEST_TEMP_DIR/no-such-pr/tools/go/versions (EVIDENCE_TESTED_SOURCE)" \
        "$(command cat "$err")" "the tree-less later source's guard fired, not main's"

    command rm -f "$pr"/tools/go/versions/*.json
    rc=0
    EVIDENCE_TESTED_SOURCE="$main:$pr" evidence_matrix_all "$r/catalog" "$r" >/dev/null 2>"$err" || rc=$?
    assert_equals "1" "$rc" "a later source with tools/go but no version files is still exit 1"
    assert_equals "evidence_matrix: no published evidence for go at $pr/tools/go/versions (EVIDENCE_TESTED_SOURCE)" \
        "$(command cat "$err")" "the file-less later source's guard fired, not main's"
}

test_all_tools_empty_versions_dir_is_an_error() {
    # A tool with a versions/ dir but no version files is half-vendored: fail
    # loudly and say why, rather than drop the tool or crash inside jq.
    local r out err rc=0
    r="$(_fixture 1.0.0)"
    _tool "$r/catalog" go 1.22.0
    _version "$r/catalog" 1.90.0 debian-13-amd64
    err="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    out="$(evidence_matrix_all "$r/catalog" "$r" 2>"$err")" || rc=$?
    assert_equals "1" "$rc" "an empty versions/ dir is exit 1"
    assert_equals "" "$out" "and prints no partial matrix"
    assert_equals "evidence_matrix: no version files for go in $r/catalog/tools/go/versions" \
        "$(command cat "$err")" "with a message naming the tool, not a jq glob error"
}

test_real_catalog_respects_github_cap() {
    # The shipped catalog against the real base-images tree: whatever is
    # pending, one run never exceeds GitHub's 256-job matrix limit — per tool
    # and for the merged every-tool matrix the workflow actually runs.
    local out rc n label
    for label in rust all; do
        rc=0
        if [ "$label" = all ]; then
            out="$(evidence_matrix_all "$PROJECT_ROOT/crates/luggage/testdata/catalog" "$PROJECT_ROOT" 2>/dev/null)" || rc=$?
        else
            out="$(evidence_matrix "$PROJECT_ROOT/crates/luggage/testdata/catalog" rust "$PROJECT_ROOT" 2>/dev/null)" || rc=$?
        fi
        if [ "$rc" -eq 3 ]; then
            assert_true true "$label: nothing pending in the shipped catalog"
            continue
        fi
        assert_equals "0" "$rc" "$label: the shipped catalog yields a matrix"
        n="$(command jq '.include | length' <<<"$out")"
        if [ "$n" -gt 0 ] && [ "$n" -le 256 ]; then
            assert_true true "$label: $n cells, within GitHub's 256 cap"
        else
            assert_true false "$label: matrix has $n cells; must be 1..256"
        fi
    done
}

run_test test_all_tools_covers_every_versioned_tool "every tool with versions/ gets legs; system_package does not"
run_test test_all_tools_cap_interleaves_tools "the merged cap interleaves tools round-robin"
run_test test_all_tools_retries_after_every_untested "failure retries wait behind every tool's untested cells"
run_test test_all_tools_retries_interleave_too "failure retries also interleave across tools"
run_test test_all_tools_probe_publication_once "base-image publication is probed once per run"
run_test test_pr_legs_one_per_tool "PR dry-run keeps one leg per tool"
run_test test_pr_legs_take_first_cell_not_min "PR dry-run keeps each tool's first cell, not its minimum"
run_test test_available_tuples_json_propagates_failure "a failing tuple scan is not an empty tuple list"
run_test test_all_tools_exit_3_only_when_all_covered "exit 3 only when every tool is covered"
run_test test_all_tools_one_failing_tool_is_an_error "one tool's error fails the merged matrix"
run_test test_pr_source_predating_a_tool_adds_nothing "an ingest PR that predates a tool adds no rows for it, not an error"
run_test test_missing_tool_stays_strict_where_it_must "main, tree-less, or file-less sources still fail"
run_test test_all_tools_empty_versions_dir_is_an_error "an empty versions/ dir fails with a named error"
run_test test_real_catalog_respects_github_cap "shipped catalog stays within GitHub's 256 cap"

generate_report
