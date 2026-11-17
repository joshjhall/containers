#!/usr/bin/env bash
# Unit tests: bin/sync-repo-baseline.sh (#1748).
#
# stibbons embeds containers-db's repo-baseline templates
# (baseline/templates/). The sync must read them from an explicit full commit
# SHA — never a branch, tag, short SHA or the working tree — record
# `containers-db <sha>` in SOURCE, and carry no local patch.
#
# Offline: every containers-db tree is a fixture git repo, except the
# tracked-copy round trip, which uses $CONTAINERS_DB_REPO (default: the
# containers-db sibling of the main checkout) and skips when it lacks the
# pinned commit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

init_test_framework

test_suite "sync-repo-baseline"

SYNC="$PROJECT_ROOT/bin/sync-repo-baseline.sh"
TRACKED="$PROJECT_ROOT/crates/stibbons/assets/repo-baseline"

# Hermetic git: no user/system config, no leaked GIT_DIR from a hook.
_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
        GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
        git "$@"
}

# _fixture <repo> — a minimal containers-db repo: one commit whose
# baseline/templates/ manifest names two sources (plus an unreferenced README).
_fixture() {
    local t="$1/baseline/templates"
    command mkdir -p "$t/core" "$t/python"
    command printf 'a.txt\tcore\talways\tcore/a.txt\nrequirements.txt\tpython\talways\tpython/requirements.txt\n' \
        >"$t/manifest.tsv"
    command printf 'core\n' >"$t/core/a.txt"
    command printf 'pytest==9.1.1\n' >"$t/python/requirements.txt"
    command printf 'readme\n' >"$t/README.md"
    _git -C "$1" init -q -b main
    _git -C "$1" add -A
    _git -C "$1" commit -q -m fixture
}

# _head <repo> — full SHA of HEAD.
_head() { _git -C "$1" rev-parse HEAD; }

# _sync <dest> <args...> — run the sync into <dest>; prints the exit code.
_sync() {
    local dest="$1" rc=0
    shift
    REPO_BASELINE_DEST="$dest" "$SYNC" "$@" >/dev/null 2>&1 || rc=$?
    command echo "$rc"
}

test_vendors_manifest_sources_and_records_sha() {
    local repo dest sha
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    sha="$(_head "$repo")"
    assert_equals "0" "$(_sync "$dest" "$sha" "$repo")" "sync at a full SHA succeeds"
    assert_equals "containers-db $sha" "$(command cat "$dest/SOURCE")" "SOURCE names containers-db and the SHA"
    assert_equals "core" "$(command cat "$dest/core/a.txt")" "manifest source vendored"
    assert_file_exists "$dest/manifest.tsv" "manifest vendored"
    assert_file_not_exists "$dest/README.md" "unreferenced files are not vendored"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_no_local_patch() {
    local repo dest
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    _sync "$dest" "$(_head "$repo")" "$repo" >/dev/null
    assert_equals "pytest==9.1.1" "$(command cat "$dest/python/requirements.txt")" \
        "requirements are vendored verbatim — no pygments pin appended"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_rejects_non_sha_refs() {
    local repo dest sha
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    sha="$(_head "$repo")"
    _git -C "$repo" tag v1
    assert_equals "2" "$(_sync "$dest" main "$repo")" "a branch name is refused"
    assert_equals "2" "$(_sync "$dest" v1 "$repo")" "a tag is refused"
    assert_equals "2" "$(_sync "$dest" "${sha:0:7}" "$repo")" "a short SHA is refused"
    assert_equals "2" "$(_sync "$dest" "$(command printf '%s' "$sha" | command tr 'a-f' 'A-F')" "$repo")" \
        "an upper-case SHA is refused"
    assert_equals "2" "$(_sync "$dest" 0000000000000000000000000000000000000000 "$repo")" \
        "a SHA absent from the repo is refused"
    assert_dir_not_exists "$dest" "nothing written on refusal"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_reads_commit_not_working_tree() {
    local repo dest sha
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    sha="$(_head "$repo")"
    command printf 'dirty\n' >"$repo/baseline/templates/core/a.txt"
    _sync "$dest" "$sha" "$repo" >/dev/null
    assert_equals "core" "$(command cat "$dest/core/a.txt")" "the committed bytes win over a dirty checkout"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_pins_older_commit_not_head() {
    local repo dest old
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    old="$(_head "$repo")"
    command printf 'newer\n' >"$repo/baseline/templates/core/a.txt"
    _git -C "$repo" commit -q -am newer
    _sync "$dest" "$old" "$repo" >/dev/null
    assert_equals "core" "$(command cat "$dest/core/a.txt")" "the pinned commit is vendored, not HEAD"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_defaults_to_pinned_sha_in_source() {
    local repo dest sha
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    sha="$(_head "$repo")"
    _sync "$dest" "$sha" "$repo" >/dev/null
    command printf 'newer\n' >"$repo/baseline/templates/core/a.txt"
    _git -C "$repo" commit -q -am newer
    assert_equals "0" "$(_sync "$dest" "" "$repo")" "an empty SHA re-syncs the current pin"
    assert_equals "containers-db $sha" "$(command cat "$dest/SOURCE")" "pin kept"
    assert_equals "core" "$(command cat "$dest/core/a.txt")" "pinned content, not HEAD"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_no_sha_and_no_pin_is_refused() {
    local repo dest
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    command mkdir -p "$dest"
    command printf 'librarian 0.18.0 +pygments-pin\n' >"$dest/SOURCE"
    assert_equals "2" "$(_sync "$dest" "" "$repo")" "a non-containers-db SOURCE gives no default pin"
    assert_equals "librarian 0.18.0 +pygments-pin" "$(command cat "$dest/SOURCE")" "nothing overwritten"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_dropped_fragment_does_not_linger() {
    local repo dest
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    command mkdir -p "$dest/core"
    command printf 'stale\n' >"$dest/core/gone.txt"
    _sync "$dest" "$(_head "$repo")" "$repo" >/dev/null
    assert_file_not_exists "$dest/core/gone.txt" "a fragment the manifest no longer names is removed"
    assert_file_exists "$dest/core/a.txt" "manifest sources are vendored"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

# _escape <manifest-source> — commit a fixture whose manifest names <source>
# (with committed file and directory symlinks available); prints
# "<exit code> <written|none>".
_escape() {
    local repo dest rc=0 t
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    t="$repo/baseline/templates"
    command printf 'x\tcore\talways\t%s\n' "$1" >>"$t/manifest.tsv"
    command printf 'secret\n' >"$repo/outside.txt"
    command ln -s ../../../outside.txt "$t/core/link.txt"
    command mkdir -p "$repo/elsewhere"
    command printf 'secret\n' >"$repo/elsewhere/f.txt"
    command ln -s ../../elsewhere "$t/dirlink"
    _git -C "$repo" add -A
    _git -C "$repo" commit -q -m escape
    REPO_BASELINE_DEST="$dest" "$SYNC" "$(_head "$repo")" "$repo" >/dev/null 2>&1 || rc=$?
    command echo "$rc $([ -e "$dest" ] && command echo written || command echo none)"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_rejects_escaping_sources() {
    assert_equals "2 none" "$(_escape '../../outside.txt')" "a .. source is refused"
    assert_equals "2 none" "$(_escape "$(command mktemp -u)")" "an absolute source is refused"
    assert_equals "2 none" "$(_escape 'core/link.txt')" "a symlinked source is refused"
    assert_equals "2 none" "$(_escape 'dirlink/f.txt')" "a source under a symlinked directory is refused"
}

test_tracked_copy_round_trips() {
    # Re-vendoring at the pinned SHA must reproduce the committed copy byte for
    # byte — proves the tracked tree carries no local patch.
    local repo="${CONTAINERS_DB_REPO:-}" common origin sha out diffout
    if [ -z "$repo" ]; then
        # Same default as the script: containers-db beside the main checkout.
        common="$(_git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
        repo="$(command dirname "$(command dirname "${common:-$PROJECT_ROOT/.git}")")/containers-db"
    fi
    read -r origin sha _ <"$TRACKED/SOURCE" || true
    if [ "$origin" != containers-db ]; then
        assert_equals "containers-db" "$origin" "tracked SOURCE names containers-db"
        return 0
    fi
    if ! _git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        skip_test "no containers-db checkout with $sha at $repo"
        return 0
    fi
    out="$(command mktemp -d)/out"
    REPO_BASELINE_DEST="$out" "$SYNC" "$sha" "$repo" >/dev/null
    diffout="$(command diff -r "$out" "$TRACKED" 2>&1 || true)"
    assert_equals "" "$diffout" "re-vendor reproduces crates/stibbons/assets/repo-baseline"
    command rm -rf "$(command dirname "$out")"
}

run_test test_vendors_manifest_sources_and_records_sha "vendors manifest sources and records the SHA"
run_test test_no_local_patch "carries no local patch"
run_test test_rejects_non_sha_refs "rejects branches, tags, short and unknown SHAs"
run_test test_reads_commit_not_working_tree "reads the commit, not the working tree"
run_test test_pins_older_commit_not_head "vendors the pinned commit, not HEAD"
run_test test_defaults_to_pinned_sha_in_source "defaults to the SHA pinned in SOURCE"
run_test test_no_sha_and_no_pin_is_refused "no SHA and no containers-db pin is refused"
run_test test_dropped_fragment_does_not_linger "dropped fragment does not linger"
run_test test_rejects_escaping_sources "rejects sources escaping the templates dir"
run_test test_tracked_copy_round_trips "tracked copy round-trips from the pinned SHA"

generate_report
