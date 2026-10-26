#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-sources.sh extracts each PR's tools/ tree
# fail-closed (#1328) — a tar that cannot extract or list, a partial archive,
# a non-empty or reused extraction dir, and symlink/hardlink entries all fail
# the job — and _es_retry retries only transient failures, classified by
# stderr.
#
# Split from evidence-sources.sh (#1482); the gh stub and fixtures are shared
# via tests/lib/evidence-sources-fixtures.sh, which documents the hermetic
# setup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

init_test_framework

test_suite "Evidence sources (extraction and retry)"

# shellcheck source=bin/lib/evidence-sources.sh
source "$PROJECT_ROOT/bin/lib/evidence-sources.sh"
# shellcheck source=tests/lib/evidence-sources-fixtures.sh
source "$PROJECT_ROOT/tests/lib/evidence-sources-fixtures.sh"

test_tar_extraction_failure_fails() {
    # git archive accepts a 300-byte file name; tar -x cannot create it.
    _setup
    local long blob tools tree head
    long="$(command printf 'n%.0s' $(command seq 300))"
    blob="$(command echo '{}' | command git -C "$SRC" hash-object -w --stdin)"
    tools="$(command printf '100644 blob %s\t%s\n' "$blob" "$long" | command git -C "$SRC" mktree)"
    tree="$(command printf '040000 tree %s\ttools\n' "$tools" | command git -C "$SRC" mktree)"
    head="$(command git -C "$SRC" -c commit.gpgsign=false commit-tree "$tree" -p HEAD -m "pr 7")"
    command git -C "$SRC" push --quiet origin "$head:refs/pull/7/head"
    _listing 7
    _pr_state 7 OPEN
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a tools/ tree tar cannot extract fails the job"
    assert_contains "$ERR" "File name too long" "for tar's reason"
    assert_equals "evidence_db_sources: cannot extract containers-db#7 tools/ (head)" "$(command tail -n1 <<<"$ERR")" \
        "naming the PR and side"
    assert_file_not_exists "$T/_db_pr/7/head.tar" "the archive is removed"
    assert_equals "" "$OUT" "and no sources"
}

test_archive_failure_removes_partial_tar() {
    # A PR head without tools/ makes git archive fail after it has already
    # created the (empty) output file.
    _setup
    command git -C "$SRC" checkout --quiet -b pr7
    command git -C "$SRC" rm --quiet -r tools
    command printf 'x\n' >"$SRC/README"
    _commit "$SRC" "pr 7" >/dev/null
    command git -C "$SRC" push --quiet origin "HEAD:refs/pull/7/head"
    command git -C "$SRC" checkout --quiet main
    _listing 7
    _pr_state 7 OPEN
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a head git archive cannot export fails the job"
    assert_contains "$ERR" "pathspec 'tools' did not match" "for git's reason"
    assert_equals "evidence_db_sources: cannot extract containers-db#7 tools/ (head)" "$(command tail -n1 <<<"$ERR")" \
        "naming the PR and side"
    assert_file_not_exists "$T/_db_pr/7/head.tar" "the partial archive is removed"
    assert_equals "" "$OUT" "and no sources"
}

test_unlistable_archive_fails_closed() {
    # git archive always writes a listable tar, so the listing helper itself
    # is overridden (not git) to answer "cannot list"; the lib is re-sourced
    # after, restoring it for later tests.
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 OPEN
    _es_tar_has_links() { return 2; }
    _collect
    # shellcheck source=bin/lib/evidence-sources.sh
    source "$PROJECT_ROOT/bin/lib/evidence-sources.sh"
    _assert_stubbed
    assert_equals "1" "$RC" "an archive that cannot be listed fails the job"
    assert_equals "evidence_db_sources: cannot extract containers-db#7 tools/ (head)" "$ERR" \
        "naming the PR and side"
    assert_equals "" "$(command ls -A "$T/_db_pr/7/head")" "nothing is extracted"
    assert_file_not_exists "$T/_db_pr/7/head.tar" "the archive is removed"
    assert_equals "" "$OUT" "and no sources"
}

test_non_empty_extraction_dir_is_refused() {
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 OPEN
    command mkdir -p "$T/_db_pr/7/head"
    : >"$T/_db_pr/7/head/stale"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "leftovers in the extraction dir fail the job"
    assert_equals "evidence_db_sources: $T/_db_pr/7/head is not empty; refusing to extract into it" "$ERR" \
        "naming the directory"
    assert_file_not_exists "$T/_db_pr/7/head/tools" "and nothing is merged into it"
}

test_rerun_in_the_same_work_dir_is_refused() {
    # The first call keeps the PR trees it extracted; a second call into the
    # same work dir refuses them rather than merging two runs' trees.
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 OPEN
    _collect
    _assert_stubbed
    assert_equals "0" "$RC" "the first call resolves"
    assert_equals "$T/_db:$T/_db_pr/7/rows" "$OUT" "with the PR's rows"
    _collect
    assert_equals "1" "$RC" "a second call into the same work dir fails the job"
    assert_equals "evidence_db_sources: $T/_db_pr/7/head is not empty; refusing to extract into it" \
        "$(command tail -n1 <<<"$ERR")" "naming the kept tree"
    assert_equals "" "$OUT" "and no sources"
}

test_permanent_failure_is_not_retried() {
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 OPEN
    echo 99 >"$GH_STUB_DIR/fail_pr-view"
    echo "HTTP 404: Not Found (https://api.github.com/graphql)" >"$GH_STUB_DIR/fail_msg_pr-view"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a 404 still fails the job"
    assert_equals "1" "$(_calls '^pr view 7')" "after a single attempt"
    assert_contains "$ERR" "evidence_sources: not retrying a permanent failure (exit 1): command gh pr view 7" \
        "the permanent failure is reported"
    assert_equals "evidence_db_sources: cannot read the state of containers-db#7" "$(command tail -n1 <<<"$ERR")" \
        "naming the PR"
}

test_retry_classifies_by_stderr() {
    local n="$TEST_TEMP_DIR/classify.$$.$RANDOM" rc err
    _failing() {
        echo $(($(command cat "$n") + 1)) >"$n"
        command echo "$1" >&2
        return 1
    }
    local msg
    for msg in "HTTP 401: Bad credentials" "HTTP 403: Resource not accessible" \
        "fatal: unable to access 'https://x/': The requested URL returned error: 401" \
        "fatal: unable to access 'https://x/': The requested URL returned error: 404"; do
        echo 0 >"$n"
        rc=0
        err="$(_es_retry _failing "$msg" 2>&1 >/dev/null)" || rc=$?
        assert_equals "1" "$rc" "'$msg' returns its exit code"
        assert_equals "1" "$(command cat "$n")" "'$msg' is attempted once"
        assert_contains "$err" "$msg" "'$msg' is still shown"
    done
    for msg in "HTTP 502: Bad Gateway" \
        "HTTP 403: API rate limit exceeded for installation ID 1. (https://api.github.com/graphql)" \
        "HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." \
        "fatal: unable to access 'https://x/': The requested URL returned error: 403"; do
        echo 0 >"$n"
        rc=0
        err="$(_es_retry _failing "$msg" 2>&1 >/dev/null)" || rc=$?
        assert_equals "1" "$rc" "a persistent '$msg' fails"
        assert_equals "3" "$(command cat "$n")" "'$msg' is transient: three attempts"
        assert_not_contains "$err" "not retrying" "'$msg' is not called permanent"
    done
}

test_tar_link_listing() {
    # Direct, because evidence_db_sources cannot reach these answers with real
    # git: no git tree holds a hardlink, and git archive never writes an
    # unlistable tar. A git stub that did would answer what git cannot.
    local d rc
    d="$(command mktemp -d "$TEST_TEMP_DIR/tl.XXXXXX")"
    command mkdir -p "$d/src/tools"
    command echo x >"$d/src/tools/a"
    command tar -cf "$d/plain.tar" -C "$d/src" tools
    rc=0
    _es_tar_has_links "$d/plain.tar" || rc=$?
    assert_equals "1" "$rc" "a tree of plain files has no links"
    command ln "$d/src/tools/a" "$d/src/tools/b"
    command tar -cf "$d/hard.tar" -C "$d/src" tools
    rc=0
    _es_tar_has_links "$d/hard.tar" || rc=$?
    assert_equals "0" "$rc" "a hardlink entry is found"
    command rm "$d/src/tools/b"
    command ln -s a "$d/src/tools/b"
    command tar -cf "$d/sym.tar" -C "$d/src" tools
    rc=0
    _es_tar_has_links "$d/sym.tar" || rc=$?
    assert_equals "0" "$rc" "a symlink entry is found"
    command printf 'not a tar' >"$d/bad.tar"
    rc=0
    _es_tar_has_links "$d/bad.tar" 2>/dev/null || rc=$?
    assert_equals "2" "$rc" "an unlistable archive is its own answer"
}

run_test test_tar_extraction_failure_fails "a tools/ tree tar cannot extract fails the job"
run_test test_archive_failure_removes_partial_tar "a failed git archive fails the job and removes its partial tar"
run_test test_unlistable_archive_fails_closed "an archive that cannot be listed fails closed"
run_test test_non_empty_extraction_dir_is_refused "a non-empty extraction dir is refused"
run_test test_rerun_in_the_same_work_dir_is_refused "a second call into the same work dir is refused"
run_test test_permanent_failure_is_not_retried "a 404 is not retried"
run_test test_retry_classifies_by_stderr "gh 401/403/404 and git 401/404 are permanent; 5xx, rate-limit and git 403s are retried"
run_test test_tar_link_listing "symlink and hardlink tar entries are found before extraction"

generate_report
