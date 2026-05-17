#!/usr/bin/env bash
# Unit tests for bin/ingest-evidence.sh — the cross-repo evidence-row
# transport script that lands rows in joshjhall/containers-db's
# tested[] arrays. Sub-issue C of #473 (evidence-runs design tracker).
#
# These tests exercise the script's local-side behavior in --dry-run
# mode against a fake containers-db checkout. The push and PR-open
# paths are not exercised here — they require a real GH credential and
# a real upstream; the workflow itself smoke-tests them on dispatch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../framework.sh
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "bin/ingest-evidence.sh"

INGEST="$PROJECT_ROOT/bin/ingest-evidence.sh"
SAMPLE_ROW="$PROJECT_ROOT/tests/fixtures/evidence-row-sample.json"

# --- Helpers ---------------------------------------------------------------

# Build a fake containers-db checkout under $1 with a single tool/version
# pre-populated. The `tested[]` array starts empty so we can assert
# append/dedup behavior.
make_fake_db() {
    local dir="$1"
    local tool="${2:-rust}"
    local version="${3:-1.95.0}"
    mkdir -p "$dir/tools/$tool/versions"
    command cat >"$dir/tools/$tool/versions/$version.json" <<EOF
{
  "schemaVersion": 1,
  "tool": "$tool",
  "version": "$version",
  "tested": []
}
EOF
    git -C "$dir" init -q
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        add . >/dev/null
    git -C "$dir" -c user.email=test@example.com -c user.name=test \
        commit -q -m "seed"
    # Land an "origin/main" so checkout -b works as if cloned from upstream.
    git -C "$dir" branch -m main 2>/dev/null || true
}

# Run the ingest script against a freshly-built fake checkout. Echo
# variables RESULT_BRANCH, RESULT_DB, RESULT_FILE for the caller.
run_ingest() {
    local row="$1"
    shift
    RESULT_DB="$(command mktemp -d)"
    make_fake_db "$RESULT_DB"
    RESULT_FILE="$RESULT_DB/tools/rust/versions/1.95.0.json"
    # Capture stdout (the script echoes the branch name on success).
    RESULT_BRANCH="$(
        "$INGEST" \
            --row "$row" \
            --db-path "$RESULT_DB" \
            --tool rust \
            --version 1.95.0 \
            --dry-run \
            --no-validate \
            "$@" \
            2>/dev/null
    )"
}

cleanup_db() {
    [ -n "${RESULT_DB:-}" ] && [ -d "$RESULT_DB" ] && command rm -rf "$RESULT_DB"
    RESULT_DB=""
}

# --- Tests -----------------------------------------------------------------

test_appends_row_on_clean_file() {
    run_ingest "$SAMPLE_ROW"
    local count
    count=$(jq '.tested | length' "$RESULT_FILE")
    assert_equals "1" "$count" "tested[] should contain exactly the new row"
    local digest
    digest=$(jq -r '.tested[0].image_digest' "$RESULT_FILE")
    assert_equals \
        "sha256:0000000000000000000000000000000000000000000000000000000000000000" \
        "$digest" \
        "row image_digest preserved verbatim"
    cleanup_db
}

test_branch_name_includes_run_id_suffix() {
    GITHUB_RUN_ID="987654321" run_ingest "$SAMPLE_ROW"
    if [[ "$RESULT_BRANCH" == "evidence/rust/1.95.0/debian-12-amd64/987654321" ]]; then
        assert_true true "branch name follows convention with GITHUB_RUN_ID suffix"
    else
        assert_true false "expected evidence/rust/1.95.0/debian-12-amd64/987654321, got '$RESULT_BRANCH'"
    fi
    cleanup_db
}

test_commit_lands_on_new_branch() {
    GITHUB_RUN_ID="1" run_ingest "$SAMPLE_ROW"
    local current
    current=$(git -C "$RESULT_DB" rev-parse --abbrev-ref HEAD)
    assert_equals "$RESULT_BRANCH" "$current" "HEAD is on the new evidence branch"
    local subject
    subject=$(git -C "$RESULT_DB" log -1 --pretty=%s)
    assert_equals \
        "feat(rust): record rust@1.95.0 evidence on debian-12-amd64 (pass)" \
        "$subject" \
        "commit subject follows conventional-commits scope+verb format"
    cleanup_db
}

test_dedup_replaces_same_tuple_same_digest() {
    # Seed an existing row with the same (os, os_version, arch, digest)
    # as the fixture but a stale tested_at, then ingest. The new row
    # must replace the old one — count stays at 1, tested_at advances.
    RESULT_DB="$(command mktemp -d)"
    make_fake_db "$RESULT_DB"
    RESULT_FILE="$RESULT_DB/tools/rust/versions/1.95.0.json"
    local seed
    seed=$(jq '. + {"tested_at": "2024-01-01T00:00:00Z", "duration_seconds": 99.9}' \
        "$SAMPLE_ROW")
    local tmp
    tmp=$(command mktemp)
    jq --argjson row "$seed" '.tested = [$row]' "$RESULT_FILE" >"$tmp"
    command mv "$tmp" "$RESULT_FILE"
    git -C "$RESULT_DB" -c user.email=test@example.com -c user.name=test \
        commit -q -am "seed stale row"

    "$INGEST" \
        --row "$SAMPLE_ROW" \
        --db-path "$RESULT_DB" \
        --tool rust \
        --version 1.95.0 \
        --dry-run \
        --no-validate >/dev/null 2>&1

    local count
    count=$(jq '.tested | length' "$RESULT_FILE")
    assert_equals "1" "$count" \
        "dedup on same (os, os_version, arch, image_digest) replaces, not appends"
    local fresh_at
    fresh_at=$(jq -r '.tested[0].tested_at' "$RESULT_FILE")
    assert_not_equals "2024-01-01T00:00:00Z" "$fresh_at" \
        "stale row replaced — fresh tested_at present"
    cleanup_db
}

test_dedup_appends_different_digest() {
    # Same tuple coords but different image_digest = different evidence
    # point = both rows are kept.
    RESULT_DB="$(command mktemp -d)"
    make_fake_db "$RESULT_DB"
    RESULT_FILE="$RESULT_DB/tools/rust/versions/1.95.0.json"
    local seed
    seed=$(jq '. + {"image_digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111", "tested_at": "2024-01-01T00:00:00Z"}' \
        "$SAMPLE_ROW")
    local tmp
    tmp=$(command mktemp)
    jq --argjson row "$seed" '.tested = [$row]' "$RESULT_FILE" >"$tmp"
    command mv "$tmp" "$RESULT_FILE"
    git -C "$RESULT_DB" -c user.email=test@example.com -c user.name=test \
        commit -q -am "seed different-digest row"

    "$INGEST" \
        --row "$SAMPLE_ROW" \
        --db-path "$RESULT_DB" \
        --tool rust \
        --version 1.95.0 \
        --dry-run \
        --no-validate >/dev/null 2>&1

    local count
    count=$(jq '.tested | length' "$RESULT_FILE")
    assert_equals "2" "$count" \
        "different image_digest preserves both rows as history"
    cleanup_db
}

test_stdin_row_via_dash() {
    local db
    db=$(command mktemp -d)
    make_fake_db "$db"
    command cat "$SAMPLE_ROW" | "$INGEST" \
        --row - \
        --db-path "$db" \
        --tool rust \
        --version 1.95.0 \
        --dry-run \
        --no-validate >/dev/null 2>&1
    local count
    count=$(jq '.tested | length' "$db/tools/rust/versions/1.95.0.json")
    assert_equals "1" "$count" "row from stdin via --row - is ingested"
    command rm -rf "$db"
}

test_rejects_missing_required_flag() {
    local rc=0
    "$INGEST" --row "$SAMPLE_ROW" --tool rust --version 1.95.0 --dry-run --no-validate \
        >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "missing --db-path exits 2 (bad input)"
}

test_rejects_unknown_argument() {
    local rc=0
    "$INGEST" --bogus-flag >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "unknown flag exits 2"
}

test_rejects_invalid_row_json() {
    local db rc=0
    db=$(command mktemp -d)
    make_fake_db "$db"
    local bad
    bad=$(command mktemp)
    command echo "{not json" >"$bad"
    "$INGEST" \
        --row "$bad" \
        --db-path "$db" \
        --tool rust \
        --version 1.95.0 \
        --dry-run \
        --no-validate >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "malformed JSON exits 2"
    command rm -rf "$db" "$bad"
}

test_rejects_missing_version_file() {
    local db rc=0
    db=$(command mktemp -d)
    mkdir -p "$db/tools/rust/versions"
    # No 1.95.0.json — script must refuse rather than fabricate a file.
    git -C "$db" init -q
    "$INGEST" \
        --row "$SAMPLE_ROW" \
        --db-path "$db" \
        --tool rust \
        --version 1.95.0 \
        --dry-run \
        --no-validate >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "missing version file exits 2 — script never invents catalog entries"
    command rm -rf "$db"
}

# --- Run -------------------------------------------------------------------

run_test test_appends_row_on_clean_file "appends row to empty tested[]"
run_test test_branch_name_includes_run_id_suffix "branch name uses GITHUB_RUN_ID when present"
run_test test_commit_lands_on_new_branch "commit lands on the new branch with conventional subject"
run_test test_dedup_replaces_same_tuple_same_digest "dedup replaces same (tuple, digest) row"
run_test test_dedup_appends_different_digest "different image_digest accumulates as history"
run_test test_stdin_row_via_dash "--row - reads JSON from stdin"
run_test test_rejects_missing_required_flag "missing --db-path is exit 2"
run_test test_rejects_unknown_argument "unknown flag is exit 2"
run_test test_rejects_invalid_row_json "malformed row JSON is exit 2"
run_test test_rejects_missing_version_file "missing version file is exit 2"

generate_report
