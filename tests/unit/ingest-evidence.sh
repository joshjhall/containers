#!/usr/bin/env bash
# Unit tests for bin/ingest-evidence.sh — the cross-repo evidence-row
# transport script that lands rows in joshjhall/containers-db's
# tested[] arrays. Sub-issue C of #473 (evidence-runs design tracker).
#
# Most tests exercise the script's local-side behavior in --dry-run mode
# against a fake containers-db checkout. The push + PR-open path runs
# against a local bare repo standing in for origin, with `gh` stubbed on
# PATH (see run_real_ingest).

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

test_branch_name_is_stable_per_tuple() {
    # GITHUB_RUN_ID is set the way CI sets it: it must NOT reach the branch
    # name, or every run opens its own PR (45 duplicates of rust@1.95.0).
    GITHUB_RUN_ID="987654321" run_ingest "$SAMPLE_ROW"
    assert_equals "evidence/rust/1.95.0/debian-12-amd64" "$RESULT_BRANCH" \
        "branch is evidence/<tool>/<version>/<tuple>, with no per-run suffix"
    cleanup_db
}

test_explicit_branch_suffix_is_honored() {
    run_ingest "$SAMPLE_ROW" --branch-suffix manual-1
    assert_equals "evidence/rust/1.95.0/debian-12-amd64/manual-1" "$RESULT_BRANCH" \
        "--branch-suffix still opts into a separate branch"
    cleanup_db
}

# Non-dry-run ingest against a bare repo standing in for containers-db
# origin. `gh` is a stub that logs its argv to $GH_LOG and answers
# `pr list` with $GH_OPEN_PR (empty = no open PR for the head).
run_real_ingest() {
    local db="$1" row="$2" out rc=0
    out=$(PATH="$STUB_DIR:$PATH" GH_TOKEN=dummy BASH_ENV='' \
        "$INGEST" --row "$row" --db-path "$db" \
        --tool rust --version 1.95.0 --no-validate 2>/dev/null) || rc=$?
    REAL_OUT="$out"
    REAL_RC="$rc"
}

make_gh_stub() {
    STUB_DIR="$(command mktemp -d)"
    GH_LOG="$STUB_DIR/gh.log"
    export GH_LOG
    command cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
if [ "$1 $2" = "pr list" ]; then
    printf '%s' "${GH_OPEN_PR:-}"
elif [ "$1 $2" = "pr create" ]; then
    printf 'https://github.com/joshjhall/containers-db/pull/1\n'
fi
STUB
    command chmod +x "$STUB_DIR/gh"
}

test_reingest_updates_open_pr_instead_of_duplicating() {
    local origin db row2
    origin="$(command mktemp -d)"
    db="$(command mktemp -d)"
    make_fake_db "$db"
    git -C "$origin" init -q --bare
    git -C "$db" remote add origin "$origin"
    git -C "$db" push -q origin main 2>/dev/null
    make_gh_stub

    # First run: no PR yet, so one is created.
    GH_OPEN_PR="" run_real_ingest "$db" "$SAMPLE_ROW"
    assert_equals "0" "$REAL_RC" "first real ingest exits 0"
    assert_equals "1" "$(command grep -c '^pr create' "$GH_LOG")" \
        "first ingest opens exactly one PR"
    local tip1
    tip1=$(git -C "$origin" rev-parse refs/heads/evidence/rust/1.95.0/debian-12-amd64)

    # Second run, new digest (a rebuilt base image), PR #42 already open.
    # The worktree is back on main, as a fresh CI checkout would be.
    git -C "$db" checkout -q main
    row2="$(command mktemp)"
    jq '.image_digest = "sha256:1111111111111111111111111111111111111111111111111111111111111111"' \
        "$SAMPLE_ROW" >"$row2"
    GH_OPEN_PR="42" run_real_ingest "$db" "$row2"
    assert_equals "0" "$REAL_RC" "re-ingest with an open PR exits 0"
    assert_equals "evidence/rust/1.95.0/debian-12-amd64" "$REAL_OUT" \
        "re-ingest reports the shared branch on stdout"
    assert_equals "1" "$(command grep -c '^pr create' "$GH_LOG")" \
        "re-ingest opens no second PR"
    local tip2
    tip2=$(git -C "$origin" rev-parse refs/heads/evidence/rust/1.95.0/debian-12-amd64)
    assert_not_equals "$tip1" "$tip2" "re-ingest force-updates the shared branch"
    assert_equals "sha256:1111111111111111111111111111111111111111111111111111111111111111" \
        "$(git -C "$origin" show "$tip2:tools/rust/versions/1.95.0.json" | jq -r '.tested[-1].image_digest')" \
        "the open PR's branch now carries the new row"
    assert_equals "1" "$(git -C "$origin" for-each-ref refs/heads/evidence/ | command wc -l | command tr -d ' ')" \
        "only one evidence branch exists on origin"

    command rm -rf "$origin" "$db" "$STUB_DIR" "$row2"
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
    # Seed an existing row with the same (os, os_version, arch, digest) as
    # the fixture but a *meaningful* difference (a failing result), then
    # ingest the passing fixture row. Because a non-volatile field differs,
    # the new row must replace the old one — count stays at 1 and the result
    # flips to pass. (A difference in volatile fields alone is a no-op; that
    # path is covered by test_noop_on_volatile_only_reingest.)
    RESULT_DB="$(command mktemp -d)"
    make_fake_db "$RESULT_DB"
    RESULT_FILE="$RESULT_DB/tools/rust/versions/1.95.0.json"
    local seed
    seed=$(jq '. + {"result": "fail", "error_class": "verify", "tested_at": "2024-01-01T00:00:00Z"}' \
        "$SAMPLE_ROW")
    local tmp
    tmp=$(command mktemp)
    jq --argjson row "$seed" '.tested = [$row]' "$RESULT_FILE" >"$tmp"
    command mv "$tmp" "$RESULT_FILE"
    git -C "$RESULT_DB" -c user.email=test@example.com -c user.name=test \
        commit -q -am "seed failing row"

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
    local result
    result=$(jq -r '.tested[0].result' "$RESULT_FILE")
    assert_equals "pass" "$result" \
        "meaningful change (result fail->pass) replaces the stale row"
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

test_noop_on_identical_reingest() {
    # Re-ingesting a byte-identical row is a clean no-op: the script exits 0,
    # creates no new commit, and prints no branch name on stdout. This is the
    # literal "nothing to commit" regression from #494.
    RESULT_DB="$(command mktemp -d)"
    make_fake_db "$RESULT_DB"
    RESULT_FILE="$RESULT_DB/tools/rust/versions/1.95.0.json"

    # First ingest records the row and commits it in the script's own format.
    GITHUB_RUN_ID=1 "$INGEST" \
        --row "$SAMPLE_ROW" --db-path "$RESULT_DB" \
        --tool rust --version 1.95.0 --dry-run --no-validate >/dev/null 2>&1
    local head1
    head1=$(git -C "$RESULT_DB" rev-parse HEAD)

    # Second ingest of the identical row must change nothing.
    local out rc=0
    out=$(GITHUB_RUN_ID=2 "$INGEST" \
        --row "$SAMPLE_ROW" --db-path "$RESULT_DB" \
        --tool rust --version 1.95.0 --dry-run --no-validate 2>/dev/null) || rc=$?
    assert_equals "0" "$rc" "identical re-ingest exits 0"
    assert_equals "" "$out" "identical re-ingest prints no branch name on stdout"
    local head2
    head2=$(git -C "$RESULT_DB" rev-parse HEAD)
    assert_equals "$head1" "$head2" "identical re-ingest creates no new commit"
    cleanup_db
}

test_noop_on_volatile_only_reingest() {
    # A row that matches the dedup key and differs only in volatile fields
    # (tested_at, ci_run, duration_seconds) carries no fresh signal, so the
    # re-ingest is a no-op and the recorded tested_at is left untouched.
    RESULT_DB="$(command mktemp -d)"
    make_fake_db "$RESULT_DB"
    RESULT_FILE="$RESULT_DB/tools/rust/versions/1.95.0.json"

    # First ingest records the fixture row.
    GITHUB_RUN_ID=1 "$INGEST" \
        --row "$SAMPLE_ROW" --db-path "$RESULT_DB" \
        --tool rust --version 1.95.0 --dry-run --no-validate >/dev/null 2>&1
    local head1 original_at
    head1=$(git -C "$RESULT_DB" rev-parse HEAD)
    original_at=$(jq -r '.tested[0].tested_at' "$RESULT_FILE")

    # Second ingest: same tuple+digest+result, only volatile fields differ.
    local volatile_row
    volatile_row=$(command mktemp)
    jq '. + {"tested_at": "2030-12-31T23:59:59Z", "duration_seconds": 0.1, "ci_run": "https://example.com/runs/99"}' \
        "$SAMPLE_ROW" >"$volatile_row"
    local rc=0
    GITHUB_RUN_ID=2 "$INGEST" \
        --row "$volatile_row" --db-path "$RESULT_DB" \
        --tool rust --version 1.95.0 --dry-run --no-validate >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "volatile-only re-ingest exits 0"

    local count fresh_at head2
    count=$(jq '.tested | length' "$RESULT_FILE")
    assert_equals "1" "$count" "volatile-only re-ingest keeps a single row"
    fresh_at=$(jq -r '.tested[0].tested_at' "$RESULT_FILE")
    assert_equals "$original_at" "$fresh_at" \
        "volatile-only re-ingest leaves the recorded tested_at untouched"
    head2=$(git -C "$RESULT_DB" rev-parse HEAD)
    assert_equals "$head1" "$head2" "volatile-only re-ingest creates no new commit"
    command rm -f "$volatile_row"
    cleanup_db
}

test_repeated_fail_refreshes_tested_at() {
    # #1326: a fail row's tested_at is the last attempt, which the evidence
    # matrix's fail cooldown keys on. A repeated failure on the same digest
    # must replace the row (newer tested_at), not no-op, or the cooldown
    # would expire once and the cell would retry on every push after that.
    RESULT_DB="$(command mktemp -d)"
    make_fake_db "$RESULT_DB"
    RESULT_FILE="$RESULT_DB/tools/rust/versions/1.95.0.json"
    local fail_row refail_row
    fail_row=$(command mktemp)
    refail_row=$(command mktemp)
    jq '. + {"result": "fail", "error_class": "verify", "tested_at": "2026-10-01T00:00:00Z"}' \
        "$SAMPLE_ROW" >"$fail_row"
    jq '. + {"result": "fail", "error_class": "verify", "tested_at": "2026-10-09T00:00:00.5Z", "ci_run": "https://example.com/runs/99"}' \
        "$SAMPLE_ROW" >"$refail_row"

    local rc=0
    GITHUB_RUN_ID=1 "$INGEST" \
        --row "$fail_row" --db-path "$RESULT_DB" \
        --tool rust --version 1.95.0 --dry-run --no-validate >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "first fail ingest exits 0"
    # A later row for another digest, so an append-at-end would reorder.
    local other tmp
    other=$(jq -c '. + {"image_digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}' "$SAMPLE_ROW")
    tmp=$(command mktemp)
    jq --argjson row "$other" '.tested += [$row]' "$RESULT_FILE" >"$tmp"
    command mv "$tmp" "$RESULT_FILE"
    git -C "$RESULT_DB" -c user.email=test@example.com -c user.name=test \
        commit -q -am "seed a later row"
    assert_equals "fail 2026-10-01T00:00:00Z|pass" \
        "$(jq -r '[(.tested[0] | "\(.result) \(.tested_at)"), .tested[1].result] | join("|")' "$RESULT_FILE")" \
        "precondition: the first failure is recorded ahead of another row"
    local head1
    head1=$(git -C "$RESULT_DB" rev-parse HEAD)
    rc=0
    GITHUB_RUN_ID=2 "$INGEST" \
        --row "$refail_row" --db-path "$RESULT_DB" \
        --tool rust --version 1.95.0 --dry-run --no-validate >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "repeated-fail re-ingest exits 0"

    assert_equals "fail 2026-10-09T00:00:00.5Z|pass" \
        "$(jq -r '[(.tested[0] | "\(.result) \(.tested_at)"), .tested[1].result] | join("|")' "$RESULT_FILE")" \
        "the row is refreshed in place with the latest attempt's tested_at"
    local head2
    head2=$(git -C "$RESULT_DB" rev-parse HEAD)
    if [ "$head1" != "$head2" ]; then
        assert_true true "the refresh is committed"
    else
        assert_true false "a repeated failure produced no commit"
    fi

    # The byte-identical fail row again (a re-run of the same job) is a no-op.
    local head3
    head3=$(git -C "$RESULT_DB" rev-parse HEAD)
    rc=0
    GITHUB_RUN_ID=3 "$INGEST" \
        --row "$refail_row" --db-path "$RESULT_DB" \
        --tool rust --version 1.95.0 --dry-run --no-validate >/dev/null 2>&1 || rc=$?
    assert_equals "0" "$rc" "identical fail re-ingest exits 0"
    assert_equals "$head3" "$(git -C "$RESULT_DB" rev-parse HEAD)" \
        "an identical fail row creates no new commit"
    command rm -f "$fail_row" "$refail_row"
    cleanup_db
}

test_repeated_fail_merge_edge_cases() {
    # merge_evidence_row directly: two rows on one dedup key collapse to one
    # refreshed row in the first slot; a fail with a different error_class
    # is a meaningful change and replaces the row (appended, as before).
    # shellcheck source=bin/lib/evidence-merge.sh
    source "$PROJECT_ROOT/bin/lib/evidence-merge.sh"
    local f other fail1 fail2 refail newclass
    f=$(command mktemp)
    other=$(jq -c '. + {"image_digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222"}' "$SAMPLE_ROW")
    fail1=$(jq -c '. + {"result": "fail", "error_class": "verify", "tested_at": "2026-10-01T00:00:00Z"}' "$SAMPLE_ROW")
    fail2=$(jq -c '. + {"result": "fail", "error_class": "verify", "tested_at": "2026-10-02T00:00:00Z"}' "$SAMPLE_ROW")
    refail=$(jq -c '. + {"result": "fail", "error_class": "verify", "tested_at": "2026-10-09T00:00:00Z"}' "$SAMPLE_ROW")
    newclass=$(jq -c '. + {"result": "fail", "error_class": "install", "tested_at": "2026-10-10T00:00:00Z"}' "$SAMPLE_ROW")
    jq -n --argjson a "$fail1" --argjson b "$other" --argjson c "$fail2" \
        '{schemaVersion: 1, tool: "rust", version: "1.95.0", tested: [$a, $b, $c]}' >"$f"

    merge_evidence_row "$f" "$refail"
    assert_equals "fail verify 2026-10-09T00:00:00Z|pass" \
        "$(jq -r '[(.tested[0] | "\(.result) \(.error_class) \(.tested_at)"), .tested[1].result] | join("|")' "$f")" \
        "rows sharing a dedup key collapse into one refreshed row in the first slot"
    assert_equals "2" "$(jq '.tested | length' "$f")" "the duplicate match is dropped"

    merge_evidence_row "$f" "$newclass"
    assert_equals "pass|fail install 2026-10-10T00:00:00Z" \
        "$(jq -r '[.tested[0].result, (.tested[1] | "\(.result) \(.error_class) \(.tested_at)")] | join("|")' "$f")" \
        "a fail with a different error_class replaces the row"
    command rm -f "$f"
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
run_test test_branch_name_is_stable_per_tuple "branch name is stable per tuple (no run-id suffix)"
run_test test_explicit_branch_suffix_is_honored "--branch-suffix opts into a separate branch"
run_test test_reingest_updates_open_pr_instead_of_duplicating "re-ingest updates the open PR, never duplicates it"
run_test test_commit_lands_on_new_branch "commit lands on the new branch with conventional subject"
run_test test_dedup_replaces_same_tuple_same_digest "dedup replaces same (tuple, digest) row"
run_test test_dedup_appends_different_digest "different image_digest accumulates as history"
run_test test_noop_on_identical_reingest "identical re-ingest is a clean no-op"
run_test test_noop_on_volatile_only_reingest "volatile-only re-ingest is a clean no-op"
run_test test_repeated_fail_refreshes_tested_at "a repeated failure refreshes tested_at for the fail cooldown"
run_test test_repeated_fail_merge_edge_cases "repeated-fail merge: duplicate matches collapse, a new error_class replaces"
run_test test_stdin_row_via_dash "--row - reads JSON from stdin"
run_test test_rejects_missing_required_flag "missing --db-path is exit 2"
run_test test_rejects_unknown_argument "unknown flag is exit 2"
run_test test_rejects_invalid_row_json "malformed row JSON is exit 2"
run_test test_rejects_missing_version_file "missing version file is exit 2"

generate_report
