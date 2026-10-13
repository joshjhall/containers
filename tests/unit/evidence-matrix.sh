#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-matrix.sh builds the push-triggered evidence
# matrix from the catalog (#1111) — newest patch per minor from the floor up,
# claimed ∩ base-image tuples, pending cells only, capped under GitHub's 256.
#
# Hermetic: a synthetic catalog + base-images tree per test, with exact
# expected cells (not substring checks), so a wrong-but-plausible matrix fails.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "Evidence matrix (catalog-derived)"

# shellcheck source=bin/lib/evidence-matrix.sh
source "$PROJECT_ROOT/bin/lib/evidence-matrix.sh"

# _version <dir> <version> <tuples-csv> [passing-tuple]
# One version file claiming each `os-osv-arch` in tuples-csv supported, with an
# optional passing evidence row for passing-tuple.
_version() {
    local dir="$1" v="$2" tuples="$3" pass="${4:-}"
    command jq -n --arg v "$v" --arg t "$tuples" --arg p "$pass" '
        def cell: split("-") as $x | {os: $x[0], os_version: $x[1], arch: $x[2]};
        {schemaVersion: 1, tool: "rust", version: $v,
         support_matrix: [ $t | split(",")[] | cell + {status: "supported"} ],
         tested: (if $p == "" then [] else [ ($p | cell) + {tested_at: "2026-10-01T00:00:00Z", result: "pass"} ] end)}
    ' >"$dir/tools/rust/versions/$v.json"
}

# _fixture <floor> — fresh catalog + base-images root; echoes its path.
_fixture() {
    local root
    root="$(command mktemp -d "$TEST_TEMP_DIR/em.XXXXXX")"
    command mkdir -p "$root/catalog/tools/rust/versions"
    command printf '{"id":"rust","minimum_recommended":"%s"}\n' "$1" >"$root/catalog/tools/rust/index.json"
    local t
    for t in debian/13/amd64 debian/13/arm64 alpine/3.24/amd64; do
        command mkdir -p "$root/base-images/$t"
        command touch "$root/base-images/$t/Dockerfile"
    done
    command echo "$root"
}

# _cells <matrix-json> — "version tuple" per cell, sorted.
_cells() {
    command jq -r '.include[] | "\(.version) \(.tuple)"' <<<"$1" | command sort
}

test_newest_patch_per_minor_from_floor() {
    local r out
    r="$(_fixture 1.85.0)"
    _version "$r/catalog" 1.84.1 debian-13-amd64  # below floor
    _version "$r/catalog" 1.85.0 debian-13-amd64  # superseded patch
    _version "$r/catalog" 1.85.2 debian-13-amd64  # newest 1.85
    _version "$r/catalog" 1.85.10 debian-13-amd64 # numerically newer than .2
    _version "$r/catalog" 1.86.0 debian-13-amd64
    out="$(evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.85.10 debian-13-amd64\n1.86.0 debian-13-amd64' "$(_cells "$out")" \
        "newest patch of each minor at/above the floor, compared numerically"
}

test_claims_intersect_base_images() {
    local r out
    r="$(_fixture 1.0.0)"
    # rhel-10-amd64 is claimed but has no base image; alpine-3.24-arm64 likewise.
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64,rhel-10-amd64,alpine-3.24-arm64
    out="$(evidence_matrix "$r/catalog" rust "$r")"
    assert_equals $'1.90.0 debian-13-amd64\n1.90.0 debian-13-arm64' "$(_cells "$out")" \
        "only claimed tuples that have a base image"
}

test_covered_cells_are_not_pending() {
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64,debian-13-arm64 debian-13-amd64
    out="$(evidence_matrix "$r/catalog" rust "$r")"
    assert_equals "1.90.0 debian-13-arm64" "$(_cells "$out")" \
        "a cell with a passing row is not re-run"
}

test_nothing_pending_exits_3_with_no_output() {
    local r out rc=0
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-amd64 debian-13-amd64
    out="$(evidence_matrix "$r/catalog" rust "$r" 2>/dev/null)" || rc=$?
    assert_equals "3" "$rc" "nothing pending is exit 3, so the workflow can skip the job"
    assert_equals "" "$out" "and prints no (empty) matrix"
}

test_cap_takes_oldest_first() {
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.80.0 debian-13-amd64,debian-13-arm64
    _version "$r/catalog" 1.81.0 debian-13-amd64,debian-13-arm64
    out="$(evidence_matrix "$r/catalog" rust "$r" latest 3 2>/dev/null)"
    assert_equals $'1.80.0 debian-13-amd64\n1.80.0 debian-13-arm64\n1.81.0 debian-13-amd64' "$(_cells "$out")" \
        "max_cells keeps the oldest pending cells"
}

test_cells_carry_arch_plumbing() {
    local r out
    r="$(_fixture 1.0.0)"
    _version "$r/catalog" 1.90.0 debian-13-arm64
    out="$(evidence_matrix "$r/catalog" rust "$r" v9)"
    assert_equals \
        '{"tool":"rust","version":"1.90.0","tuple":"debian-13-arm64","image_tag":"v9","arch":"arm64","runner":"ubuntu-24.04-arm","runtime":"native","rust_target":"aarch64-unknown-linux-musl"}' \
        "$(command jq -c '.include[0]' <<<"$out")" \
        "each cell carries the same fields the dispatch path builds"
}

test_missing_index_is_an_error() {
    local rc=0
    evidence_matrix "$TEST_TEMP_DIR/nope" rust "$TEST_TEMP_DIR" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a missing index is exit 1, not an empty matrix"
}

test_real_catalog_respects_github_cap() {
    # The shipped catalog against the real base-images tree: whatever is
    # pending, one run never exceeds GitHub's 256-job matrix limit.
    local out rc=0 n=0
    out="$(evidence_matrix "$PROJECT_ROOT/crates/luggage/testdata/catalog" rust "$PROJECT_ROOT" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 3 ]; then
        assert_true true "nothing pending in the shipped catalog"
        return
    fi
    assert_equals "0" "$rc" "the shipped catalog yields a matrix"
    n="$(command jq '.include | length' <<<"$out")"
    if [ "$n" -gt 0 ] && [ "$n" -le 256 ]; then
        assert_true true "$n cells, within GitHub's 256 cap"
    else
        assert_true false "matrix has $n cells; must be 1..256"
    fi
}

run_test test_newest_patch_per_minor_from_floor "newest patch per minor from the floor (numeric)"
run_test test_claims_intersect_base_images "claims intersect available base images"
run_test test_covered_cells_are_not_pending "covered cells are not re-run"
run_test test_nothing_pending_exits_3_with_no_output "nothing pending exits 3 with no output"
run_test test_cap_takes_oldest_first "cap keeps the oldest pending cells"
run_test test_cells_carry_arch_plumbing "cells carry arch plumbing"
run_test test_missing_index_is_an_error "missing index is an error"
run_test test_real_catalog_respects_github_cap "shipped catalog stays within GitHub's 256 cap"

generate_report
