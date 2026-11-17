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
# The default repo: containers-db beside the main checkout (worktree-aware).
SIBLING="$(command dirname "$(command dirname "$(env -u GIT_DIR -u GIT_WORK_TREE \
    git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir)")")/containers-db"

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

test_rejects_symlinked_manifest() {
    local repo dest t
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    t="$repo/baseline/templates"
    command mv "$t/manifest.tsv" "$repo/real-manifest.tsv"
    # Absolute, so it resolves to a real host file after extraction — a
    # relative link would dangle in scratch and fail for the wrong reason.
    command ln -s "$repo/real-manifest.tsv" "$t/manifest.tsv"
    _git -C "$repo" add -A
    _git -C "$repo" commit -q -m symlink-manifest
    assert_equals "2" "$(_sync "$dest" "$(_head "$repo")" "$repo")" "a symlinked manifest.tsv is refused"
    assert_dir_not_exists "$dest" "nothing written"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

# _sync_env <dest> <sha> [VAR=value ...] — run the sync with no repo argument
# and the given environment; prints the exit code.
_sync_env() {
    local dest="$1" sha="$2" rc=0
    shift 2
    env -u CONTAINERS_DB -u CONTAINERS_DB_REPO "$@" REPO_BASELINE_DEST="$dest" \
        "$SYNC" "$sha" >/dev/null 2>&1 || rc=$?
    command echo "$rc"
}

test_repo_default_resolution() {
    local repo other dest sha notgit
    repo="$(command mktemp -d)"
    other="$(command mktemp -d)"
    notgit="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    # A distinct repo that never held <repo>'s commit (a _fixture copy would
    # share its SHA: same bytes, same second).
    command printf 'other\n' >"$other/marker"
    _git -C "$other" init -q -b main
    _git -C "$other" add -A
    _git -C "$other" commit -q -m other
    sha="$(_head "$repo")"
    assert_not_equals "$sha" "$(_head "$other")" "fixtures have distinct SHAs"
    assert_equals "0" "$(_sync_env "$dest" "$sha" CONTAINERS_DB_REPO="$repo")" \
        "CONTAINERS_DB_REPO is honoured"
    assert_equals "0" "$(_sync_env "$dest" "$sha" CONTAINERS_DB="$repo")" \
        "a git-checkout CONTAINERS_DB is used"
    # A non-git CONTAINERS_DB (the in-image catalog snapshot) must be skipped,
    # never used. Either way the run fails (the fallback sibling lacks the
    # fixture SHA), so the exit code cannot tell them apart — assert on which
    # repo the error names instead.
    local err
    err="$(env -u CONTAINERS_DB_REPO CONTAINERS_DB="$notgit" REPO_BASELINE_DEST="$dest" \
        "$SYNC" "$sha" 2>&1 >/dev/null || true)"
    assert_not_contains "$err" "$notgit" "a non-git CONTAINERS_DB is never used as the repo"
    assert_contains "$err" " in $SIBLING " "the sibling of the main checkout is tried instead"
    assert_equals "2" "$(_sync "$dest" "$sha" "$notgit")" "a non-git repo argument is refused"
    assert_equals "2" "$(_sync "$dest" "$sha" "$other")" "a repo lacking the SHA is refused"
    command rm -rf "$repo" "$other" "$notgit" "$(command dirname "$dest")"
}

test_leaked_git_dir_is_ignored() {
    local repo decoy dest sha
    repo="$(command mktemp -d)"
    decoy="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    _fixture "$repo"
    _git -C "$decoy" init -q
    sha="$(_head "$repo")"
    assert_equals "0" "$(GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" _sync "$dest" "$sha" "$repo")" \
        "a leaked GIT_DIR does not redirect git -C <repo>"
    command rm -rf "$repo" "$decoy" "$(command dirname "$dest")"
}

test_fallback_outside_any_git_repo() {
    # With no git checkout around the script, the default repo is
    # <script>/../../containers-db — not anything under bin/.
    local root sha repo err
    root="$(command mktemp -d)"
    repo="$(command mktemp -d)"
    command mkdir -p "$root/proj/bin"
    command cp "$SYNC" "$root/proj/bin/sync-repo-baseline.sh"
    _fixture "$repo"
    sha="$(_head "$repo")"
    err="$(cd "$root" && env -u CONTAINERS_DB -u CONTAINERS_DB_REPO GIT_CEILING_DIRECTORIES="$root" \
        REPO_BASELINE_DEST="$root/out" "$root/proj/bin/sync-repo-baseline.sh" "$sha" 2>&1 >/dev/null || true)"
    assert_contains "$err" "not a git checkout of containers-db: $root/containers-db" \
        "outside git, the default is the checkout's parent's containers-db"
    command rm -rf "$root" "$repo"
}

test_missing_templates_dir_is_named() {
    local repo dest sha err
    repo="$(command mktemp -d)"
    dest="$(command mktemp -d)/out"
    command printf 'x\n' >"$repo/x"
    _git -C "$repo" init -q -b main
    _git -C "$repo" add -A
    _git -C "$repo" commit -q -m no-templates
    sha="$(_head "$repo")"
    err="$(REPO_BASELINE_DEST="$dest" "$SYNC" "$sha" "$repo" 2>&1 >/dev/null || true)"
    assert_contains "$err" "$sha has no baseline/templates" "a commit without the templates dir is named as such"
    assert_dir_not_exists "$dest" "nothing written"
    command rm -rf "$repo" "$(command dirname "$dest")"
}

test_tracked_copy_round_trips() {
    # Re-vendoring at the pinned SHA must reproduce the committed copy byte for
    # byte — proves the tracked tree carries no local patch.
    local repo="${CONTAINERS_DB_REPO:-$SIBLING}" origin sha out diffout
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
run_test test_rejects_symlinked_manifest "rejects a symlinked manifest.tsv"
run_test test_repo_default_resolution "repo default resolution (env, non-git, missing SHA)"
run_test test_leaked_git_dir_is_ignored "a leaked GIT_DIR is ignored"
run_test test_fallback_outside_any_git_repo "default repo outside any git checkout"
run_test test_missing_templates_dir_is_named "a commit without baseline/templates is named"
run_test test_tracked_copy_round_trips "tracked copy round-trips from the pinned SHA"

generate_report
