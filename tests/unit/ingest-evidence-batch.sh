#!/usr/bin/env bash
# Unit tests for bin/ingest-evidence-batch.sh: every row of one evidence run
# lands in containers-db as ONE branch + ONE PR with auto-merge enabled.
#
# Hermetic: a local bare repo stands in for the containers-db origin and `gh`
# is a stub on PATH that logs its argv, so the real push / PR / auto-merge
# path runs without the network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

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

# _gh_stub — a `gh` that logs argv to $GH_LOG and prints a PR URL on create.
_gh_stub() {
    STUB_DIR="$(command mktemp -d "$TEST_TEMP_DIR/gh.XXXXXX")"
    GH_LOG="$STUB_DIR/gh.log"
    export GH_LOG
    command cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
[ "$1 $2" = "pr create" ] && printf 'https://github.com/joshjhall/containers-db/pull/9\n'
exit 0
STUB
    command chmod +x "$STUB_DIR/gh"
}

_run() {
    local rows="$1" db="$2" rc=0
    OUT=$(PATH="$STUB_DIR:$PATH" GH_TOKEN=dummy BASH_ENV='' \
        "$BATCH" --rows-dir "$rows" --db-path "$db" --run-id 4242 --no-validate 2>/dev/null) || rc=$?
    RC="$rc"
}

test_many_rows_one_pr_with_automerge() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    _gh_stub
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
    assert_equals "3" "$(git -C "$d/db.git" show evidence/batch/4242:tools/rust/versions/1.82.0.json | command jq '.tested|length')" \
        "1.82.0 got all three of its rows"
    assert_equals "2" "$(git -C "$d/db.git" show evidence/batch/4242:tools/rust/versions/1.83.0.json | command jq '.tested|length')" \
        "1.83.0 got both of its rows"
    assert_equals "1" "$(git -C "$d/db.git" rev-list --count main..evidence/batch/4242)" "in one commit"
    assert_equals "null" "$(git -C "$d/db.git" show evidence/batch/4242:tools/rust/versions/1.82.0.json | command jq '.tested[0].tool')" \
        "routing fields are stripped from the stored TestEntry"
}

test_nothing_new_is_a_clean_noop() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    _gh_stub
    _row "$rows" r1 1.82.0 debian 13 amd64 pass
    _run "$rows" "$db"
    # Same row again on a fresh checkout of the merged result: no PR.
    git -C "$db" checkout -q main
    git -C "$db" -c user.email=t@t -c user.name=t merge -q --ff-only evidence/batch/4242 2>/dev/null ||
        git -C "$db" reset -q --hard evidence/batch/4242
    : >"$GH_LOG"
    _run "$rows" "$db"
    assert_equals "0" "$RC" "re-ingesting recorded rows exits 0"
    assert_equals "" "$OUT" "prints no branch"
    assert_equals "0" "$(command grep -c '^pr create' "$GH_LOG" || true)" "and opens no PR"
}

test_rows_for_unknown_versions_are_skipped() {
    local d db rows
    d="$(command mktemp -d "$TEST_TEMP_DIR/b.XXXXXX")"
    db="$d/db"
    rows="$d/rows"
    _fake_db "$db"
    _gh_stub
    _row "$rows" r1 9.9.9 debian 13 amd64 pass # not in containers-db
    _row "$rows" r2 1.82.0 debian 13 amd64 pass
    _run "$rows" "$db"
    assert_equals "0" "$RC" "an unknown version does not fail the batch"
    assert_equals "1" "$(git -C "$d/db.git" show evidence/batch/4242:tools/rust/versions/1.82.0.json | command jq '.tested|length')" \
        "the known row still lands"
}

test_unsafe_run_id_is_refused() {
    local rc=0
    "$BATCH" --rows-dir "$TEST_TEMP_DIR" --db-path "$TEST_TEMP_DIR/x" --run-id 'a;b' >/dev/null 2>&1 || rc=$?
    assert_equals "2" "$rc" "a run id with shell metacharacters is a usage error"
}

run_test test_many_rows_one_pr_with_automerge "many rows land as one PR with auto-merge"
run_test test_nothing_new_is_a_clean_noop "re-ingesting recorded rows opens no PR"
run_test test_rows_for_unknown_versions_are_skipped "rows for versions not in the db are skipped"
run_test test_unsafe_run_id_is_refused "unsafe run id is refused"

generate_report
