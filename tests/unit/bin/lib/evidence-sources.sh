#!/usr/bin/env bash
# Unit tests: bin/lib/evidence-sources.sh resolves the published-evidence
# sources for a push-triggered evidence run (#1328): containers-db main plus
# the rows each open ingest PR adds, failing closed on a truncated listing, a
# symlinked tools/ tree, an empty source list, or a network call that keeps
# failing after its retries.
#
# Hermetic: a local bare repo stands in for containers-db's origin, and a PATH
# stub stands in for gh. The stub answers `pr list`/`pr view` from fixture
# files and computes `api .../compare` from the fixture repo with real git, so
# the merge-base and status it returns are ones GitHub could return. The lib
# runs `command gh`, which only a PATH entry can intercept, and /etc/bash_env
# rebuilds PATH in a child bash, so every call runs in this shell process and
# every collect test asserts the stub was reached: a missed stub must fail the
# test, not fall through to real gh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"

init_test_framework

test_suite "Evidence sources (open containers-db PRs)"

# shellcheck source=bin/lib/evidence-sources.sh
source "$PROJECT_ROOT/bin/lib/evidence-sources.sh"

# Fixture commits need an identity, and an inherited repo must not leak in.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export EVIDENCE_RETRY_DELAY=0 EVIDENCE_DB_REPO=owner/db

# Fixed clock; PRs are created an hour before it.
_NOW=1792540800
_CREATED="$(command date -u -d "@$((_NOW - 3600))" +%Y-%m-%dT%H:%M:%SZ)"

# The stub's body; _setup writes it into each test's own PATH directory.
_GH_STUB="$(
    command cat <<'STUB'
#!/usr/bin/env bash
# gh stub: logs each call, fails the first fail_<op> calls (with stderr from
# fail_msg_<op>, default a transient error), and answers from $GH_STUB_DIR
# (list.json, pr-<n>.json, repo/ = the bare origin; compare_base, when
# present, overrides the merge-base sha) with the suite's own git and jq
# ($GH_STUB_GIT, $GH_STUB_JQ).
set -u
d="$GH_STUB_DIR"
printf '%s\n' "$*" >>"$d/calls"
op="$1-$2"
case "$op" in api-*/compare/*) op=api-compare ;; esac
q=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[$i]}" = -q ] && q="${args[$((i + 1))]}"
done
if [ -s "$d/fail_$op" ]; then
    k="$(cat "$d/fail_$op")"
    if [ "$k" -gt 0 ]; then
        echo $((k - 1)) >"$d/fail_$op"
        printf 'partial'
        if [ -s "$d/fail_msg_$op" ]; then cat "$d/fail_msg_$op" >&2; else echo "gh: transient error" >&2; fi
        exit 1
    fi
fi
case "$op" in
    pr-list) cat "$d/list.json" ;;
    pr-view) "$GH_STUB_JQ" -r "$q" "$d/pr-$3.json" ;;
    api-compare)
        spec="${2##*/compare/}"
        a="${spec%%...*}" b="${spec##*...}"
        g() { "$GH_STUB_GIT" -C "$d/repo" "$@"; }
        base="$(g merge-base "$a" "$b")" || exit 1
        if [ "$a" = "$b" ]; then st=identical
        elif g merge-base --is-ancestor "$a" "$b"; then st=ahead
        elif g merge-base --is-ancestor "$b" "$a"; then st=behind
        else st=diverged; fi
        [ -e "$d/compare_base" ] && base="$(cat "$d/compare_base")"
        "$GH_STUB_JQ" -nr --arg s "$st" --arg m "$base" "{status: \$s, merge_base_commit: {sha: \$m}} | $q"
        ;;
    *) echo "gh stub: unhandled $*" >&2; exit 2 ;;
esac
STUB
)"
_BASE_PATH="$PATH"
# Resolved once, before any stub dir is on PATH: images differ in where git
# lives (/usr/local/bin vs /usr/bin), and a baked-in path that is missing on
# the runner fails every compare for the wrong reason.
GH_STUB_GIT="$(command -v git)"
GH_STUB_JQ="$(command -v jq)"
export GH_STUB_GIT GH_STUB_JQ

# _row <tuple> — one pass row for os-osv-arch.
_row() {
    command jq -cn --arg t "$1" '$t | split("-") as $x
        | {os: $x[0], os_version: $x[1], arch: $x[2], result: "pass", tested_at: "2026-10-01T00:00:00Z"}'
}

# _put <src> <version> <tuple>... — write rust <version> with a row per tuple.
_put() {
    local src="$1" v="$2" t rows=()
    shift 2
    for t in "$@"; do rows+=("$(_row "$t")"); done
    command mkdir -p "$src/tools/rust/versions"
    command jq -n --arg v "$v" --argjson r "$(command printf '%s\n' "${rows[@]}" | command jq -cs .)" \
        '{schemaVersion: 1, tool: "rust", version: $v, tested: $r}' >"$src/tools/rust/versions/$v.json"
}

# _commit <src> <msg> — commit everything in src; echoes the sha.
_commit() {
    command git -C "$1" add -A
    command git -C "$1" -c commit.gpgsign=false commit --quiet -m "$2"
    command git -C "$1" rev-parse HEAD
}

# _listing <n>... — a gh pr list answer with one trusted ingest PR per n.
_listing() {
    local n
    for n in "$@"; do
        command jq -cn --argjson n "$n" --arg c "$_CREATED" \
            '{number: $n, headRefName: "evidence/batch/\($n)", isCrossRepository: false,
              author: {login: "joshjhall"}, createdAt: $c}'
    done | command jq -cs . >"$GH_STUB_DIR/list.json"
}

# _pr_state <n> <state> [merge_sha] — the gh pr view answer for PR n.
_pr_state() {
    command jq -n --arg s "$2" --arg m "${3:-}" \
        '{state: $s, mergeCommit: (if $m == "" then null else {oid: $m} end)}' >"$GH_STUB_DIR/pr-$1.json"
}

# _setup — fresh origin (bare, by-SHA fetch allowed), an author clone `src`
# with main = M0 (rust 1.90.0 passing on debian-13-amd64), a `_db` clone, and
# an empty PR listing, with the gh stub first on PATH. Sets T, SRC and
# GH_STUB_DIR.
_setup() {
    T="$(command mktemp -d "$TEST_TEMP_DIR/es.XXXXXX")"
    export GH_STUB_DIR="$T/gh"
    command mkdir -p "$GH_STUB_DIR" "$T/bin"
    command printf '%s\n' "$_GH_STUB" >"$T/bin/gh"
    command chmod +x "$T/bin/gh"
    export PATH="$T/bin:$_BASE_PATH"
    : >"$GH_STUB_DIR/calls"
    command git init --quiet --bare -b main "$T/origin.git"
    command git -C "$T/origin.git" config uploadpack.allowAnySHA1InWant true
    command ln -s "$T/origin.git" "$GH_STUB_DIR/repo"
    SRC="$T/src"
    command git init --quiet -b main "$SRC"
    command git -C "$SRC" remote add origin "$T/origin.git"
    _put "$SRC" 1.90.0 debian-13-amd64
    _commit "$SRC" m0 >/dev/null
    command git -C "$SRC" push --quiet origin main
    command git clone --quiet "$T/origin.git" "$T/_db"
    _listing
}

# _open_pr <n> — branch PR n off main, add rust 1.90.0 debian-13-arm64, push
# it as refs/pull/<n>/head, and return to main. Echoes the head sha.
_open_pr() {
    local head
    command git -C "$SRC" checkout --quiet -b "pr$1"
    _put "$SRC" 1.90.0 debian-13-amd64 debian-13-arm64
    head="$(_commit "$SRC" "pr $1")"
    command git -C "$SRC" push --quiet origin "HEAD:refs/pull/$1/head"
    command git -C "$SRC" checkout --quiet main
    command echo "$head"
}

# _collect — run evidence_db_sources in this shell; sets OUT, ERR, RC.
_collect() {
    local err="$T/stderr"
    RC=0
    OUT="$(evidence_db_sources "$T/_db" "$T" "$_NOW" 2>"$err")" || RC=$?
    ERR="$(command cat "$err")"
}

# _calls [pattern] — how many stub calls (matching pattern) were made.
_calls() {
    command grep -c -- "${1:-}" "$GH_STUB_DIR/calls" || true
}

# _assert_stubbed — the gh stub, not a real gh, answered this test.
_assert_stubbed() {
    assert_greater_than "$(_calls)" 0 "the gh stub was reached"
}

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
        "fatal: unable to access 'https://x/': The requested URL returned error: 404"; do
        echo 0 >"$n"
        rc=0
        err="$(_es_retry _failing "$msg" 2>&1 >/dev/null)" || rc=$?
        assert_equals "1" "$rc" "'$msg' returns its exit code"
        assert_equals "1" "$(command cat "$n")" "'$msg' is attempted once"
        assert_contains "$err" "$msg" "'$msg' is still shown"
    done
    echo 0 >"$n"
    rc=0
    err="$(_es_retry _failing "HTTP 502: Bad Gateway" 2>&1 >/dev/null)" || rc=$?
    assert_equals "1" "$rc" "a persistent 502 fails"
    assert_equals "3" "$(command cat "$n")" "after three attempts: a 5xx is transient"
    assert_not_contains "$err" "not retrying" "and is not called permanent"
}

test_tar_link_listing() {
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
run_test test_tar_extraction_failure_fails "a tools/ tree tar cannot extract fails the job"
run_test test_archive_failure_removes_partial_tar "a failed git archive fails the job and removes its partial tar"
run_test test_non_empty_extraction_dir_is_refused "a non-empty extraction dir is refused"
run_test test_permanent_failure_is_not_retried "a 404 is not retried"
run_test test_retry_classifies_by_stderr "401/403/404 are permanent, 5xx is retried"
run_test test_tar_link_listing "symlink and hardlink tar entries are found before extraction"

generate_report
