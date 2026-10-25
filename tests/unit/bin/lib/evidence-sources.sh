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
# gh stub: logs each call, fails the first fail_<op> calls, and answers from
# $GH_STUB_DIR (list.json, pr-<n>.json, repo/ = the bare origin) with the
# suite's own git and jq ($GH_STUB_GIT, $GH_STUB_JQ).
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
        echo "gh: transient error" >&2
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
    assert_equals "containers-db#8 tools/ (head) contains symlinks; refusing it" "$ERR" "naming the head side"
    assert_equals "" "$OUT" "and no sources"
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
    assert_equals "containers-db#9 tools/ (base) contains symlinks; refusing it" "$ERR" "naming the base side"
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
run_test test_retry_discards_a_failed_attempts_output "a failed attempt's partial output is discarded"
run_test test_empty_source_list_is_refused "an empty source list is refused"

generate_report
