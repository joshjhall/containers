#!/usr/bin/env bash
# Shared fixtures for the evidence-sources suites (#1482):
# tests/unit/bin/lib/evidence-sources.sh (listing, state, compare, landed
# checks) and tests/unit/bin/lib/evidence-sources-extract.sh (tar extraction
# and _es_retry classification). Sourced only — it lives outside tests/unit/
# so the unit runner does not execute it as a suite. Callers source
# tests/framework.sh and bin/lib/evidence-sources.sh first: _setup writes
# under TEST_TEMP_DIR and _collect runs evidence_db_sources.
#
# Hermetic: a local bare repo stands in for containers-db's origin, and a PATH
# stub stands in for gh. The stub answers `pr list`/`pr view` from fixture
# files and computes `api .../compare` from the fixture repo with real git, so
# the merge-base and status it returns are ones GitHub could return. The lib
# runs `command gh`, which only a PATH entry can intercept, and /etc/bash_env
# rebuilds PATH in a child bash, so every call runs in the suite's shell
# process and every collect test asserts the stub was reached: a missed stub
# must fail the test, not fall through to real gh.

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
# The suites pass the PR numbers; _setup's bare call is the empty listing.
# shellcheck disable=SC2120
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
# The sourcing suites read those three, so shellcheck sees them as unused here.
# shellcheck disable=SC2034
_collect() {
    local err="$T/stderr"
    RC=0
    OUT="$(evidence_db_sources "$T/_db" "$T" "$_NOW" 2>"$err")" || RC=$?
    ERR="$(command cat "$err")"
}

# _calls [pattern] — how many stub calls (matching pattern) were made.
# The suites pass the pattern; _assert_stubbed's bare call counts every call.
# shellcheck disable=SC2120
_calls() {
    command grep -c -- "${1:-}" "$GH_STUB_DIR/calls" || true
}

# _assert_stubbed — the gh stub, not a real gh, answered this test.
_assert_stubbed() {
    assert_greater_than "$(_calls)" 0 "the gh stub was reached"
}
