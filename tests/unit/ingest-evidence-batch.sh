#!/usr/bin/env bash
# Unit tests for bin/ingest-evidence-batch.sh: every row of one evidence run
# lands in containers-db as ONE branch + ONE PR with auto-merge enabled.
#
# Hermetic: a local bare repo stands in for the containers-db origin and `gh`
# is a fake GitHub on PATH (tests/lib/gh-api-stub.sh) that logs its argv and
# captures every createCommitOnBranch payload, so the real API-commit / PR /
# auto-merge path runs without the network. The commit goes through the API
# so GitHub signs it (#1573): nothing may reach the origin with `git push`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# shellcheck source=tests/lib/gh-api-stub.sh
source "$SCRIPT_DIR/../lib/gh-api-stub.sh"

init_test_framework

test_suite "bin/ingest-evidence-batch.sh"

BATCH="$PROJECT_ROOT/bin/ingest-evidence-batch.sh"

# _fake_db <dir> — containers-db checkout (with a bare origin) holding
# rust 1.82.0 and 1.83.0 with empty tested[].
_fake_db() {
    local db="$1" origin="$1.git" v
    command mkdir -p "$db/tools/rust/versions"
    for v in 1.82.0 1.83.0; do
        command printf '{"schemaVersion":1,"tool":"rust","version":"%s","tested":[]}\n' "$v" \
            >"$db/tools/rust/versions/$v.json"
    done
    git -C "$db" init -q -b main
    git -C "$db" -c user.email=t@t -c user.name=t add .
    git -C "$db" -c user.email=t@t -c user.name=t commit -q -m seed
    git init -q --bare "$origin"
    git -C "$db" remote add origin "$origin"
    git -C "$db" push -q origin main 2>/dev/null
}

# _row <dir> <name> <version> <os> <osv> <arch> <result> [digest]
_row() {
    command mkdir -p "$1"
    command jq -n --arg v "$3" --arg os "$4" --arg ov "$5" --arg a "$6" --arg r "$7" \
        --arg d "${8:-sha256:$(printf 'a%.0s' {1..64})}" \
        '{tool:"rust", version:$v, os:$os, os_version:$ov, arch:$a, result:$r,
          tested_at:"2026-10-13T00:00:00Z", image_ref:"ghcr.io/x/base", image_digest:$d}' \
        >"$1/$2.json"
}

# _merged <db> — the checkout after the batch PR merged: commit what the
# ingest left in the working tree, as containers-db main would now hold it.
_merged() {
    git -C "$1" -c user.email=t@t -c user.name=t commit -q -am merged
}

# _run <rows> <db> [run-id] — run id defaults to 4242; a later run in the
# same test needs its own, as a real evidence run would have.
_run() {
    local rows="$1" db="$2" run_id="${3:-4242}" rc=0 err_file
    err_file="$(command mktemp "$TEST_TEMP_DIR/err.XXXXXX")"
    OUT=$(PATH="$STUB_DIR:$PATH" GH_TOKEN=dummy BASH_ENV='' \
        "$BATCH" --rows-dir "$rows" --db-path "$db" --run-id "$run_id" --no-validate 2>"$err_file") || rc=$?
    RC="$rc"
    ERR="$(command cat "$err_file")"
}

test_many_rows_one_pr_with_automerge() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    gh_stub_install
    # Five cells across two version files, nested like download-artifact
    # output (one subdirectory per artifact).
    _row "$rows/a" r1 1.82.0 debian 13 amd64 pass
    _row "$rows/b" r2 1.82.0 debian 13 arm64 pass
    _row "$rows/c" r3 1.82.0 rhel 10 amd64 fail
    _row "$rows/d" r4 1.83.0 ubuntu 26.04 amd64 pass
    _row "$rows/e" r5 1.83.0 alpine 3.24 arm64 pass
    _run "$rows" "$db"
    assert_equals "0" "$RC" "batch ingest exits 0"
    assert_equals "evidence/batch/4242" "$OUT" "prints the one batch branch"
    assert_equals "1" "$(command grep -c '^pr create' "$GH_LOG")" "exactly ONE PR for five rows"
    assert_equals "1" "$(command grep -c '^pr merge .*--auto --squash --delete-branch' "$GH_LOG")" \
        "auto-merge is enabled on it"
    assert_equals "1" "$(command grep -c '^api graphql' "$GH_LOG")" "in ONE API commit"
    assert_equals "1" "$(command grep -c '^api -X POST repos/joshjhall/containers-db/git/refs -f ref=refs/heads/evidence-staging/batch/4242 -f sha='"$(git -C "$db" rev-parse HEAD)"'$' "$GH_LOG")" \
        "the staging ref is created through the API at the checkout's HEAD"
    local p
    p="$(gh_stub_payload)"
    assert_equals "joshjhall/containers-db evidence-staging/batch/4242 $(git -C "$db" rev-parse HEAD)" \
        "$(command jq -r '.variables.input | "\(.branch.repositoryNameWithOwner) \(.branch.branchName) \(.expectedHeadOid)"' "$p")" \
        "the commit is built on the staging ref, expecting the checkout's HEAD"
    assert_equals "1" "$(command grep -c '^api -X POST repos/joshjhall/containers-db/git/refs -f ref=refs/heads/evidence/batch/4242 -f sha=c0ffee0001$' "$GH_LOG")" \
        "the batch branch is created only at the finished commit"
    assert_equals "1" "$(command grep -c '^api -X DELETE repos/joshjhall/containers-db/git/refs/heads/evidence-staging/batch/4242$' "$GH_LOG")" \
        "the staging ref is deleted"
    assert_equals "feat(evidence): record 5 evidence row(s) across 2 version file(s)" \
        "$(command jq -r '.variables.input.message.headline' "$p")" "headline carries the counts"
    assert_equals "3" "$(gh_stub_file "$p" tools/rust/versions/1.82.0.json | command jq '.tested|length')" \
        "1.82.0 got all three of its rows"
    assert_equals "2" "$(gh_stub_file "$p" tools/rust/versions/1.83.0.json | command jq '.tested|length')" \
        "1.83.0 got both of its rows"
    assert_equals "null" "$(gh_stub_file "$p" tools/rust/versions/1.82.0.json | command jq '.tested[0].tool')" \
        "routing fields are stripped from the stored TestEntry"
    assert_equals "" "$(git -C "$d/db.git" branch --list 'evidence/*')" \
        "nothing was pushed with git (an unsigned commit would be)"
}

test_nothing_new_is_a_clean_noop() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    gh_stub_install
    _row "$rows" r1 1.82.0 debian 13 amd64 pass
    _run "$rows" "$db"
    # Same row again on a checkout of the merged result: no commit, no PR.
    _merged "$db"
    : >"$GH_LOG"
    _run "$rows" "$db"
    assert_equals "0" "$RC" "re-ingesting recorded rows exits 0"
    assert_equals "" "$OUT" "prints no branch"
    assert_equals "0" "$(command grep -c '^api graphql' "$GH_LOG" || true)" "makes no API commit"
    assert_equals "0" "$(command grep -c '^pr create' "$GH_LOG" || true)" "and opens no PR"
}

test_repeated_fail_refreshes_and_identical_is_noop() {
    # #1326: on the production (batch) path, a same-digest repeated failure
    # with a newer tested_at is a change (it restarts the matrix's fail
    # cooldown), while the identical row again is still "nothing new".
    local d db rows rows2
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    rows2="$d/rows2"
    _fake_db "$db"
    gh_stub_install
    _row "$rows" r1 1.82.0 debian 13 amd64 fail
    _run "$rows" "$db"
    _merged "$db"

    _row "$rows2" r1 1.82.0 debian 13 amd64 fail
    command jq '.tested_at = "2026-10-20T00:00:00Z"' "$rows2/r1.json" >"$rows2/r1.tmp"
    command mv "$rows2/r1.tmp" "$rows2/r1.json"
    : >"$GH_LOG"
    _run "$rows2" "$db" 4243
    assert_equals "0" "$RC" "repeated-fail batch ingest exits 0"
    assert_equals "evidence/batch/4243" "$OUT" "the refresh is a change: a batch branch is printed"
    assert_equals "1 2026-10-20T00:00:00Z" \
        "$(gh_stub_file "$(gh_stub_payload)" tools/rust/versions/1.82.0.json | command jq -r '"\(.tested | length) \(.tested[0].tested_at)"')" \
        "one row, carrying the newer tested_at"

    _merged "$db"
    : >"$GH_LOG"
    _run "$rows2" "$db" 4244
    assert_equals "0" "$RC" "identical fail re-ingest exits 0"
    assert_equals "" "$OUT" "prints no branch"
    assert_equals "0" "$(command grep -c '^pr create' "$GH_LOG" || true)" "and opens no PR"
}

test_rows_for_unknown_versions_are_skipped() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    gh_stub_install
    _row "$rows" r1 9.9.9 debian 13 amd64 pass # not in containers-db
    _row "$rows" r2 1.82.0 debian 13 amd64 pass
    _run "$rows" "$db"
    assert_equals "0" "$RC" "an unknown version does not fail the batch"
    assert_equals "1" "$(gh_stub_file "$(gh_stub_payload)" tools/rust/versions/1.82.0.json | command jq '.tested|length')" \
        "the known row still lands"
}

test_dry_run_commits_locally_and_never_calls_github() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    gh_stub_install
    _row "$rows" r1 1.82.0 debian 13 amd64 pass
    OUT=$(PATH="$STUB_DIR:$PATH" BASH_ENV='' GH_TOKEN='' GITHUB_TOKEN='' \
        "$BATCH" --rows-dir "$rows" --db-path "$db" --run-id 7 --no-validate --dry-run 2>/dev/null) || RC=$?
    assert_equals "evidence/batch/7" "$OUT" "dry-run prints the branch"
    assert_equals "1" "$(git -C "$db" show evidence/batch/7:tools/rust/versions/1.82.0.json | command jq '.tested|length')" \
        "the merge is committed on the local branch"
    assert_equals "0" "$(command wc -l <"$GH_LOG" | command tr -d ' ')" "gh is never called"
}

test_api_commit_failure_fails_the_ingest_and_opens_no_pr() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    gh_stub_install
    _row "$rows" r1 1.82.0 debian 13 amd64 pass
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_FAIL=1 _run "$rows" "$db"
    assert_equals "1" "$RC" "a failed API commit is a runtime error"
    assert_equals "0" "$(command grep -c '^pr create' "$GH_LOG" || true)" "no PR is opened for a commit that never landed"
    # The stub keeps no ref store, so "no branch left behind" is read off the
    # call log: evidence/batch/* is never created or moved (#1584) ...
    assert_equals "0" "$(command grep -cE '^api -X (POST|PATCH) .*(refs/heads/)evidence/batch/' "$GH_LOG" || true)" \
        "no evidence/batch/* ref is created or moved for a commit that never landed"
    # ... and the staging ref the commit was attempted on is deleted.
    assert_equals "1" "$(command grep -c '^api -X DELETE repos/joshjhall/containers-db/git/refs/heads/evidence-staging/batch/4242$' "$GH_LOG")" \
        "the staging ref is deleted on the failure path"
}

test_automerge_failure_fails_the_ingest() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    gh_stub_install
    _row "$rows" r1 1.82.0 debian 13 amd64 pass
    GH_API_RETRY_DELAY=0 GH_STUB_PR_MERGE_FAIL_FIRST=99 _run "$rows" "$db"
    assert_equals "1" "$RC" "auto-merge that never enables fails the ingest (#1574)"
    assert_equals "" "$OUT" "no branch is printed for a PR that will not merge"
    assert_equals "1" "$(command grep -c '^pr create' "$GH_LOG")" "the PR was opened before the failure"
    assert_equals "3" "$(command grep -c '^pr merge ' "$GH_LOG")" "every retry attempt was spent first"
    assert_equals "1" "$(command grep -c '^::error::could not enable auto-merge on https://github.com/joshjhall/containers-db/pull/9;' <<<"$ERR")" \
        "one ::error:: line names the stuck PR"
    assert_equals "0" "$(command grep -c '^::warning::' <<<"$ERR" || true)" "it is not downgraded to a warning"
}

test_transient_automerge_failure_is_retried() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    gh_stub_install
    _row "$rows" r1 1.82.0 debian 13 amd64 pass
    GH_API_RETRY_DELAY=0 GH_STUB_PR_MERGE_FAIL_FIRST=1 _run "$rows" "$db"
    assert_equals "0" "$RC" "a transient auto-merge failure is retried, not fatal"
    assert_equals "evidence/batch/4242" "$OUT" "prints the batch branch"
    assert_equals "2" "$(command grep -c '^pr merge ' "$GH_LOG")" "the second attempt enabled auto-merge"
    assert_equals "0" "$(command grep -c '::error::' <<<"$ERR" || true)" "no error is reported"
}

test_unsafe_run_id_is_refused() {
    local rc=0
    "$BATCH" --rows-dir "$TEST_TEMP_DIR" --db-path "$TEST_TEMP_DIR/x" --run-id 'a;b' >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "a run id with shell metacharacters is a usage error"
}

# _run_expected <rows> <db> <cells> [succeeded] — _run with --expected-cells
# and --succeeded-cells (default 0); also keeps stderr.
_run_expected() {
    local rc=0
    OUT=$(PATH="$STUB_DIR:$PATH" GH_TOKEN=dummy BASH_ENV='' \
        "$BATCH" --rows-dir "$1" --db-path "$2" --run-id 4242 --expected-cells "$3" \
        --succeeded-cells "${4:-0}" --no-validate 2>"$STUB_DIR/err") || rc=$?
    RC="$rc"
    ERR="$(command cat "$STUB_DIR/err")"
}

test_all_cancelled_run_is_a_neutral_skip() {
    # #1569: every cell timed out, so download-artifact made no rows/ dir.
    local d db
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    _fake_db "$db"
    gh_stub_install
    _run_expected "$d/rows" "$db" 3
    assert_equals "0" "$RC" "an all-cancelled run exits 0 (neutral skip)"
    assert_contains "$ERR" "no evidence rows: none of 3 cells reached upload (cancelled, timed out, or failed)" "says why there is nothing to ingest"
    assert_not_contains "$ERR" "is not a directory" "not the misleading path error"
    assert_equals "" "$OUT" "prints no branch"
    # gh_stub_install creates GH_LOG empty, so "never called" is "still empty".
    assert_equals "" "$(command cat "$GH_LOG")" "gh is never called: no API commit, no PR"
    # An existing but empty download dir is the same state.
    command mkdir -p "$d/rows/evidence-row-x"
    _run_expected "$d/rows" "$db" 3
    assert_equals "0" "$RC" "an empty rows dir is also a neutral skip"
    assert_contains "$ERR" "no evidence rows: none of 3 cells reached upload" "with the same message"
    assert_equals "0" "$(git -C "$db" branch --list 'evidence/batch/*' | command wc -l | command tr -d ' ')" \
        "no batch branch is created"
}

test_all_cancelled_skip_edge_cases() {
    # Review follow-up: the skip keys on "no *.json under rows-dir", so a dir
    # holding only other files is still all-cancelled; --dry-run (the PR
    # path) skips the same way; and 0 is accepted and reported literally.
    local d db rc=0 err
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    _fake_db "$db"
    gh_stub_install
    command mkdir -p "$d/rows/evidence-row-x"
    command printf 'not a row\n' >"$d/rows/evidence-row-x/manifest.txt"
    _run_expected "$d/rows" "$db" 4 0
    assert_equals "0" "$RC" "a rows dir with only non-JSON files, no cell succeeded, is a neutral skip"
    assert_contains "$ERR" "no evidence rows: none of 4 cells reached upload" "with the neutral message"
    err="$(PATH="$STUB_DIR:$PATH" GH_TOKEN=dummy BASH_ENV='' "$BATCH" --rows-dir "$d/none" --db-path "$db" \
        --run-id 4242 --expected-cells 2 --succeeded-cells 0 --dry-run --no-validate 2>&1 >/dev/null)" || rc=$?
    assert_equals "0" "$rc" "--dry-run with no rows is the same neutral skip"
    assert_contains "$err" "no evidence rows: none of 2 cells reached upload" "and says so"
    _run_expected "$d/none" "$db" 0
    assert_equals "0" "$RC" "--expected-cells 0 is accepted"
    assert_contains "$ERR" "no evidence rows: none of 0 cells reached upload" "and reported as given"
    assert_equals "0" "$(git -C "$db" branch --list 'evidence/batch/*' | command wc -l | command tr -d ' ')" \
        "none of them creates a batch branch"
}

test_no_rows_after_successful_cells_fails_loud() {
    # Cells that all passed but left no rows mean the upload/download is
    # broken (e.g. a renamed artifact pattern): that must not read as a skip.
    local d db
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    _fake_db "$db"
    gh_stub_install
    # 3/3 succeeded, and the PR-review case: 1 of 3 succeeded while the other
    # two timed out (the aggregate result would read `failure` and hide it).
    local s
    for s in 3 1; do
        _run_expected "$d/rows" "$db" 3 "$s"
        assert_equals "1" "$RC" "no rows while $s of 3 cells succeeded is a runtime error"
        assert_contains "$ERR" "no evidence rows, yet $s of 3 evidence cells succeeded: the row upload or download is broken" \
            "and names the contradiction"
        assert_not_contains "$ERR" "nothing to ingest" "not the neutral skip"
    done
}

test_succeeded_cells_is_validated() {
    local d rc=0 err
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    err="$("$BATCH" --rows-dir "$d/nope" --db-path "$d/db" --run-id 1 --expected-cells 3 2>&1 >/dev/null)" || rc=$?
    assert_equals "2" "$rc" "--expected-cells without --succeeded-cells is a usage error"
    assert_contains "$err" "--expected-cells needs --succeeded-cells" "and says so"
    rc=0
    err="$("$BATCH" --rows-dir "$d/nope" --db-path "$d/db" --run-id 1 --expected-cells 3 --succeeded-cells '' 2>&1 >/dev/null)" || rc=$?
    assert_equals "2" "$rc" "a blank --succeeded-cells (unset step output) is refused, not read as 0"
    assert_contains "$err" "--succeeded-cells must be a non-negative integer" "as a bad value"
    rc=0
    err="$("$BATCH" --rows-dir "$d/nope" --db-path "$d/db" --run-id 1 --expected-cells 3 --succeeded-cells 4 2>&1 >/dev/null)" || rc=$?
    assert_equals "2" "$rc" "more successes than cells is a usage error"
    assert_contains "$err" "--succeeded-cells (4) exceeds --expected-cells (3)" "and names both"
    rc=0
    err="$("$BATCH" --rows-dir "$d/nope" --db-path "$d/db" --run-id 1 --succeeded-cells 0 2>&1 >/dev/null)" || rc=$?
    assert_equals "2" "$rc" "--succeeded-cells alone is a usage error"
    assert_contains "$err" "--succeeded-cells needs --expected-cells" "and says so"
}

test_expected_cells_with_rows_still_ingests() {
    local d db
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    _fake_db "$db"
    gh_stub_install
    _row "$d/rows" r1 1.82.0 debian 13 amd64 pass
    _run_expected "$d/rows" "$db" 2 1
    assert_equals "0" "$RC" "a partial run ingests normally"
    assert_equals "evidence/batch/4242" "$OUT" "and prints its branch"
    assert_not_contains "$ERR" "no evidence rows" "no all-cancelled message when a row exists"
}

test_missing_rows_dir_without_expected_cells_is_a_usage_error() {
    local d rc=0 err
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    err="$("$BATCH" --rows-dir "$d/nope" --db-path "$d/db" --run-id 1 2>&1 >/dev/null)" || rc=$?
    assert_equals "2" "$rc" "a mistyped --rows-dir without --expected-cells stays exit 2"
    assert_contains "$err" "--rows-dir is not a directory" "with the path error"
}

test_bad_expected_cells_is_refused() {
    local d rc=0 err
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    err="$("$BATCH" --rows-dir "$d/nope" --db-path "$d/db" --run-id 1 --expected-cells 'x1' 2>&1 >/dev/null)" || rc=$?
    assert_equals "2" "$rc" "a non-integer --expected-cells is a usage error"
    assert_contains "$err" "--expected-cells must be a non-negative integer" "and says so"
    rc=0
    err="$("$BATCH" --rows-dir "$d/nope" --db-path "$d/db" --run-id 1 --expected-cells '' 2>&1 >/dev/null)" || rc=$?
    assert_equals "2" "$rc" "an empty --expected-cells (blank job output) is not a skip"
    assert_contains "$err" "--expected-cells must be a non-negative integer" "refused as a bad value, not as a missing dir"
}

run_test test_many_rows_one_pr_with_automerge "many rows land as one PR with auto-merge"
run_test test_nothing_new_is_a_clean_noop "re-ingesting recorded rows opens no PR"
run_test test_repeated_fail_refreshes_and_identical_is_noop "a newer repeated fail refreshes; the identical row is a no-op"
run_test test_rows_for_unknown_versions_are_skipped "rows for versions not in the db are skipped"
run_test test_dry_run_commits_locally_and_never_calls_github "dry-run commits locally and never calls GitHub"
run_test test_api_commit_failure_fails_the_ingest_and_opens_no_pr "a failed API commit fails the ingest with no PR"
run_test test_automerge_failure_fails_the_ingest "auto-merge that cannot be enabled fails the ingest, naming the PR"
run_test test_transient_automerge_failure_is_retried "a transient auto-merge failure is retried and succeeds"
run_test test_unsafe_run_id_is_refused "unsafe run id is refused"
run_test test_all_cancelled_run_is_a_neutral_skip "an all-cancelled run (no rows) is a clear neutral skip"
run_test test_all_cancelled_skip_edge_cases "all-cancelled skip: non-JSON-only dir, --dry-run, zero cells"
run_test test_no_rows_after_successful_cells_fails_loud "no rows while any cell succeeded fails loudly (incl. mixed)"
run_test test_succeeded_cells_is_validated "--succeeded-cells is validated and paired with --expected-cells"
run_test test_expected_cells_with_rows_still_ingests "--expected-cells does not change a run with rows"
run_test test_missing_rows_dir_without_expected_cells_is_a_usage_error "absent --rows-dir without --expected-cells is exit 2"
run_test test_bad_expected_cells_is_refused "a bad --expected-cells is refused"

generate_report
