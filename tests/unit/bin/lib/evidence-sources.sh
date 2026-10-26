#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-sources.sh resolves the published-evidence
# sources for a push-triggered evidence run (#1328): containers-db main plus
# the rows each open ingest PR adds, failing closed on a truncated listing, a
# symlinked tools/ tree, an empty source list, or a network call that keeps
# failing after its retries.
#
# Tar extraction and _es_retry classification live in the sibling
# evidence-sources-extract.sh (#1482); both share the gh stub and fixtures in
# tests/lib/evidence-sources-fixtures.sh, which documents the hermetic setup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

init_test_framework

test_suite "Evidence sources (open containers-db PRs)"

# shellcheck source=bin/lib/evidence-sources.sh
source "$PROJECT_ROOT/bin/lib/evidence-sources.sh"
# shellcheck source=tests/lib/evidence-sources-fixtures.sh
source "$PROJECT_ROOT/tests/lib/evidence-sources-fixtures.sh"

test_open_pr_adds_only_its_rows() {
    _setup
    _open_pr 7 >/dev/null
    # Main moves on after the PR branched: its merge-base stays M0.
    _put "$SRC" 1.91.0 debian-13-amd64
    _commit "$SRC" m1 >/dev/null
    command git -C "$SRC" push --quiet origin main
    _listing 7
    _pr_state 7 OPEN
    _collect
    _assert_stubbed
    assert_equals "0" "$RC" "an open PR resolves"
    assert_equals "$T/_db:$T/_db_pr/7/rows" "$OUT" "main, then the PR's rows"
    assert_equals "$(_row debian-13-arm64)" \
        "$(command jq -c '.tested[]' "$T/_db_pr/7/rows/tools/rust/versions/1.90.0.json")" \
        "only the row the PR adds, not the one it inherited"
    assert_equals "$(command git -C "$SRC" rev-parse HEAD)" "$(command git -C "$T/_db" rev-parse HEAD)" \
        "_db is on the fetched main"
}

test_listing_at_1000_is_truncated() {
    _setup
    command jq -n '[range(1000) | {number: ., headRefName: "x", isCrossRepository: false,
        author: {login: "joshjhall"}, createdAt: "2026-10-01T00:00:00Z"}]' >"$GH_STUB_DIR/list.json"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "1000 listed PRs fail the job"
    assert_equals "containers-db has 1000+ open PRs; the listing may be truncated" "$ERR" "with the truncation message"
    assert_equals "" "$OUT" "and no sources"

    command jq 'del(.[0])' "$GH_STUB_DIR/list.json" >"$T/list" && command mv "$T/list" "$GH_STUB_DIR/list.json"
    _collect
    assert_equals "0" "$RC" "999 listed PRs pass the guard"
    assert_equals "$T/_db" "$OUT" "none of them an ingest PR, so main alone"
}

test_symlink_in_head_is_refused() {
    _setup
    command git -C "$SRC" checkout --quiet -b pr8
    _put "$SRC" 1.90.0 debian-13-amd64 debian-13-arm64
    command ln -s /etc/passwd "$SRC/tools/rust/versions/1.92.0.json"
    _commit "$SRC" "pr 8" >/dev/null
    command git -C "$SRC" push --quiet origin "HEAD:refs/pull/8/head"
    _listing 8
    _pr_state 8 OPEN
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a symlink in the PR head fails the job"
    assert_equals "containers-db#8 tools/ (head) contains symlinks or hardlinks; refusing it" "$ERR" "naming the head side"
    assert_equals "" "$OUT" "and no sources"
    assert_equals "" "$(command ls -A "$T/_db_pr/8/head")" "refused before anything was extracted"
    assert_file_not_exists "$T/_db_pr/8/head.tar" "and the archive is removed"
}

test_symlink_in_base_is_refused() {
    _setup
    # The merge-base carries the symlink; the PR head removes it.
    command ln -s /etc/passwd "$SRC/tools/rust/versions/1.92.0.json"
    _commit "$SRC" m1 >/dev/null
    command git -C "$SRC" push --quiet origin main
    command git -C "$SRC" checkout --quiet -b pr9
    command rm "$SRC/tools/rust/versions/1.92.0.json"
    _put "$SRC" 1.90.0 debian-13-amd64 debian-13-arm64
    _commit "$SRC" "pr 9" >/dev/null
    command git -C "$SRC" push --quiet origin "HEAD:refs/pull/9/head"
    _listing 9
    _pr_state 9 OPEN
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a symlink in the PR's merge-base fails the job"
    assert_equals "containers-db#9 tools/ (base) contains symlinks or hardlinks; refusing it" "$ERR" "naming the base side"
    assert_equals "" "$(command ls -A "$T/_db_pr/9/base")" "refused before anything was extracted"
}

test_closed_pr_is_skipped() {
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 CLOSED
    _collect
    _assert_stubbed
    assert_equals "0" "$RC" "a closed PR is not an error"
    assert_equals "$T/_db" "$OUT" "its rows do not count"
    assert_equals "containers-db#7 closed without merging since it was listed; its rows do not count" "$ERR" \
        "and the skip is reported"
}

test_merged_into_main_read_is_skipped() {
    _setup
    _open_pr 7 >/dev/null
    command git -C "$SRC" -c commit.gpgsign=false merge --quiet --no-ff -m "merge 7" pr7
    command git -C "$SRC" push --quiet origin main
    _listing 7
    _pr_state 7 MERGED "$(command git -C "$SRC" rev-parse HEAD)"
    _collect
    _assert_stubbed
    assert_equals "0" "$RC" "a PR merged into the main read is not an error"
    assert_equals "$T/_db" "$OUT" "its rows come from main"
    assert_equals "1" "$(_calls 'compare/')" "only the landed check was asked, no merge-base"
}

test_merged_after_main_read_counts() {
    _setup
    _open_pr 7 >/dev/null
    # The merge commit exists, but main as fetched does not have it yet.
    command git -C "$SRC" checkout --quiet -b later
    command git -C "$SRC" -c commit.gpgsign=false merge --quiet --no-ff -m "merge 7" pr7
    command git -C "$SRC" push --quiet origin later
    _listing 7
    _pr_state 7 MERGED "$(command git -C "$SRC" rev-parse HEAD)"
    _collect
    _assert_stubbed
    assert_equals "0" "$RC" "a PR merged after the main read resolves"
    assert_equals "$T/_db:$T/_db_pr/7/rows" "$OUT" "and its rows still count"
}

test_transient_listing_failure_is_retried() {
    _setup
    echo 2 >"$GH_STUB_DIR/fail_pr-list"
    _collect
    _assert_stubbed
    assert_equals "0" "$RC" "two failed listings then a good one resolve"
    assert_equals "$T/_db" "$OUT" "with the good listing's sources"
    assert_equals "3" "$(_calls '^pr list')" "after three listings"
    assert_equals "2" "$(command grep -c '^evidence_sources: attempt [12]/3 failed (exit 1): command gh pr list' <<<"$ERR")" \
        "each failed attempt is reported"
}

test_persistent_listing_failure_fails() {
    _setup
    echo 99 >"$GH_STUB_DIR/fail_pr-list"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a listing that never succeeds fails the job"
    assert_equals "3" "$(_calls '^pr list')" "after exactly three attempts"
    assert_equals "evidence_db_sources: cannot list open PRs of owner/db" "$(command tail -n1 <<<"$ERR")" \
        "with the listing named"
    assert_equals "" "$OUT" "and no sources"
}

test_persistent_state_failure_fails() {
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 OPEN
    echo 99 >"$GH_STUB_DIR/fail_pr-view"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a PR state that cannot be read fails the job"
    assert_equals "3" "$(_calls '^pr view 7')" "after exactly three attempts"
    assert_equals "evidence_db_sources: cannot read the state of containers-db#7" "$(command tail -n1 <<<"$ERR")" \
        "naming the PR"
}

test_persistent_fetch_failure_fails() {
    _setup
    command git -C "$T/_db" remote set-url origin "$T/no-such-origin.git"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a main that cannot be fetched fails the job"
    assert_equals "3" "$(command grep -c '^evidence_sources: attempt [123]/3 failed (exit [0-9]*): command git -C .* fetch' <<<"$ERR")" \
        "after exactly three fetch attempts"
    assert_equals "evidence_db_sources: cannot fetch owner/db main" "$(command tail -n1 <<<"$ERR")" "naming main"
}

test_persistent_compare_failure_fails() {
    # The merge-base lookup is a gh api compare call; when it keeps failing
    # the PR's rows cannot be isolated, so the job fails rather than count
    # its whole tree or drop it.
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 OPEN
    echo 99 >"$GH_STUB_DIR/fail_api-compare"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a merge-base that cannot be resolved fails the job"
    assert_equals "3" "$(_calls 'compare/')" "after exactly three attempts"
    assert_equals "evidence_db_sources: cannot resolve containers-db#7's merge-base" "$(command tail -n1 <<<"$ERR")" \
        "naming the PR"
    assert_equals "" "$OUT" "and no sources"
}

test_unparsable_listing_fails() {
    # A listing jq cannot read must not pass as "no open PRs", which would
    # re-queue every cell those PRs cover.
    _setup
    # An empty listing and one that is not a single array (jq would print
    # nothing, or several lengths) fail the same way.
    local listing
    for listing in 'not json' '' '[] []' '{}'; do
        command printf '%s' "$listing" >"$GH_STUB_DIR/list.json"
        _collect
        _assert_stubbed
        assert_equals "1" "$RC" "listing '$listing' fails the job"
        assert_equals "evidence_db_sources: unparsable PR listing" "$(command tail -n1 <<<"$ERR")" \
            "listing '$listing' is named unparsable"
        assert_equals "" "$OUT" "listing '$listing' yields no sources"
    done
}

test_unreadable_pr_rows_fail() {
    # A PR version file evidence_pr_rows cannot parse fails the job rather
    # than dropping that PR's rows and re-queueing its cells.
    _setup
    command git -C "$SRC" checkout --quiet -b pr7
    command printf '{not json\n' >"$SRC/tools/rust/versions/1.90.0.json"
    _commit "$SRC" "pr 7" >/dev/null
    command git -C "$SRC" push --quiet origin "HEAD:refs/pull/7/head"
    command git -C "$SRC" checkout --quiet main
    _listing 7
    _pr_state 7 OPEN
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "unreadable PR rows fail the job"
    assert_equals "evidence_pr_rows: unreadable tools/rust/versions/1.90.0.json in $T/_db_pr/7/head or $T/_db_pr/7/base" \
        "$(command tail -n1 <<<"$ERR")" "naming the file"
    assert_equals "" "$OUT" "and no sources"
}

test_retry_discards_a_failed_attempts_output() {
    local n="$TEST_TEMP_DIR/flaky.$$.$RANDOM" out
    echo 0 >"$n"
    _flaky() {
        local k
        k="$(command cat "$n")"
        echo $((k + 1)) >"$n"
        if [ "$k" -eq 0 ]; then
            command printf 'partial'
            return 7
        fi
        command printf 'full\n'
    }
    out="$(_es_retry _flaky 2>/dev/null)"
    assert_equals "full" "$out" "only the succeeding attempt's output is printed"
    assert_equals "2" "$(command cat "$n")" "after one retry"
    local rc=0
    out="$(EVIDENCE_RETRY_ATTEMPTS=2 _es_retry false 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "the last attempt's exit code is returned"
}

test_empty_source_list_is_refused() {
    local rc=0 err
    err="$(evidence_require_sources "" 2>&1)" || rc=$?
    assert_equals "1" "$rc" "an empty source list is exit 1"
    assert_equals "No published evidence source resolved" "$err" "with the guard's message"
    rc=0
    err="$(evidence_require_sources /db 2>&1)" || rc=$?
    assert_equals "0" "$rc" "a resolved source list passes"
    assert_equals "" "$err" "silently"
}

test_persistent_landed_check_failure_fails() {
    # A MERGED PR's landed check (is its merge commit in the main read?) is a
    # compare call too; when it keeps failing the PR can be neither counted
    # nor skipped, so the job fails.
    _setup
    _open_pr 7 >/dev/null
    command git -C "$SRC" -c commit.gpgsign=false merge --quiet --no-ff -m "merge 7" pr7
    command git -C "$SRC" push --quiet origin main
    _listing 7
    _pr_state 7 MERGED "$(command git -C "$SRC" rev-parse HEAD)"
    echo 99 >"$GH_STUB_DIR/fail_api-compare"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a landed check that never succeeds fails the job"
    assert_equals "3" "$(_calls 'compare/')" "after exactly three attempts"
    assert_equals "evidence_db_sources: cannot compare containers-db#7's merge to main" "$(command tail -n1 <<<"$ERR")" \
        "naming the PR"
    assert_equals "" "$OUT" "and no sources"
}

test_empty_merge_base_fails() {
    _setup
    _open_pr 7 >/dev/null
    _listing 7
    _pr_state 7 OPEN
    : >"$GH_STUB_DIR/compare_base"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a compare with no merge-base fails the job"
    assert_equals "1" "$(_calls 'compare/')" "after the one compare that answered"
    assert_equals "evidence_db_sources: no merge-base for containers-db#7" "$ERR" "naming the PR"
    assert_equals "" "$OUT" "and no sources"
}

test_merge_base_fetch_failure_fails() {
    # The merge-base is genuinely absent from a shallow _db clone, and the
    # origin refuses it: without uploadpack.allowAnySHA1InWant, a protocol v0
    # server will not serve an unadvertised object (v2 serves any reachable
    # one), and main has moved past it, so it is no ref's tip.
    _setup
    local base
    base="$(command git -C "$SRC" rev-parse HEAD)"
    _open_pr 7 >/dev/null
    _put "$SRC" 1.91.0 debian-13-amd64
    _commit "$SRC" m1 >/dev/null
    command git -C "$SRC" push --quiet origin main
    command rm -rf "$T/_db"
    command git clone --quiet --depth 1 "file://$T/origin.git" "$T/_db"
    command git -C "$T/_db" config protocol.version 0
    command git -C "$T/origin.git" config --unset uploadpack.allowAnySHA1InWant
    _listing 7
    _pr_state 7 OPEN
    local present=0
    command git -C "$T/_db" cat-file -e "$base" 2>/dev/null || present=$?
    assert_not_equals "0" "$present" "the merge-base is absent from the clone before collecting"
    _collect
    _assert_stubbed
    assert_equals "1" "$RC" "a merge-base that cannot be fetched fails the job"
    assert_equals "3" "$(command grep -c "^evidence_sources: attempt [123]/3 failed (exit [0-9]*): command git -C .* fetch --quiet --depth 1 origin $base\$" <<<"$ERR")" \
        "after exactly three fetch attempts"
    assert_contains "$ERR" "Server does not allow request for unadvertised object $base" "refused by the real server"
    assert_equals "evidence_db_sources: cannot fetch containers-db#7's merge-base" "$(command tail -n1 <<<"$ERR")" \
        "naming the PR"
    assert_equals "" "$OUT" "and no sources"
}

run_test test_open_pr_adds_only_its_rows "an open PR contributes only the rows it adds"
run_test test_listing_at_1000_is_truncated "a 1000-PR listing is refused as possibly truncated"
run_test test_symlink_in_head_is_refused "a symlink in a PR head's tools/ is refused"
run_test test_symlink_in_base_is_refused "a symlink in a PR merge-base's tools/ is refused"
run_test test_closed_pr_is_skipped "a PR closed since listing is skipped"
run_test test_merged_into_main_read_is_skipped "a PR merged into the main read is skipped"
run_test test_merged_after_main_read_counts "a PR merged after the main read still counts"
run_test test_transient_listing_failure_is_retried "a transient listing failure is retried"
run_test test_persistent_listing_failure_fails "a persistent listing failure fails after 3 attempts"
run_test test_persistent_state_failure_fails "a persistent state-read failure fails after 3 attempts"
run_test test_persistent_fetch_failure_fails "a persistent fetch failure fails after 3 attempts"
run_test test_persistent_compare_failure_fails "a persistent merge-base lookup failure fails after 3 attempts"
run_test test_unparsable_listing_fails "an unparsable listing fails the job"
run_test test_unreadable_pr_rows_fail "unreadable PR rows fail the job"
run_test test_retry_discards_a_failed_attempts_output "a failed attempt's partial output is discarded"
run_test test_empty_source_list_is_refused "an empty source list is refused"
run_test test_persistent_landed_check_failure_fails "a persistent landed-check failure fails after 3 attempts"
run_test test_empty_merge_base_fails "an empty merge-base sha fails the job"
run_test test_merge_base_fetch_failure_fails "a merge-base the origin will not serve fails after 3 attempts"

generate_report
