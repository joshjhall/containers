#!/usr/bin/env bash
# Unit tests for bin/lib/github-api-commit.sh (#1573): commits are created
# through the GitHub API (createCommitOnBranch) so GitHub signs them. `gh` is
# a fake GitHub on PATH (tests/lib/gh-api-stub.sh) that captures each GraphQL
# payload, so the suite asserts on exactly what would be sent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"
# shellcheck source=tests/lib/gh-api-stub.sh
source "$SCRIPT_DIR/../../../lib/gh-api-stub.sh"

init_test_framework

test_suite "Bin Lib GitHub API Commit Tests"

# shellcheck source=bin/lib/github-api-commit.sh
source "$PROJECT_ROOT/bin/lib/github-api-commit.sh"

# _repo — a checkout with keep.txt, gone.txt and an executable run.sh on HEAD.
_repo() {
    REPO="$(command mktemp -d "$TEST_TEMP_DIR/r.XXXXXX")"
    git -C "$REPO" init -q -b main
    command printf 'keep\n' >"$REPO/keep.txt"
    command printf 'gone\n' >"$REPO/gone.txt"
    command printf '#!/bin/sh\n' >"$REPO/run.sh"
    command chmod +x "$REPO/run.sh"
    git -C "$REPO" add .
    git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
    MSG="$REPO.msg"
    command printf 'chore: headline\n\n\nbody line 1\nbody line 2\n' >"$MSG"
}

# _commit [pathspec...] — gh_api_commit_worktree on $REPO with the stub on
# PATH; sets OUT (stdout), ERR (stderr) and RC.
_commit() {
    local rc=0
    OUT="$(PATH="$STUB_DIR:$PATH" gh_api_commit_worktree o/r b "$REPO" "$MSG" "$@" 2>"$REPO.err")" || rc=$?
    ERR="$(command cat "$REPO.err")"
    RC="$rc"
}

test_payload_carries_additions_deletions_and_expected_head() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    command mkdir -p "$REPO/sub dir"
    command printf 'new \xe2\x9c\x93\n' >"$REPO/sub dir/new.json"
    command rm "$REPO/gone.txt"
    _commit
    assert_equals "0" "$RC" "commit succeeds"
    assert_equals "c0ffee0001" "$OUT" "prints the new commit oid"
    local p
    p="$(gh_stub_payload)"
    assert_equals "o/r b $(git -C "$REPO" rev-parse HEAD)" \
        "$(command jq -r '.variables.input | "\(.branch.repositoryNameWithOwner) \(.branch.branchName) \(.expectedHeadOid)"' "$p")" \
        "targets the branch and expects the local HEAD"
    assert_equals "changed" "$(gh_stub_file "$p" keep.txt)" "a modified file is sent with its new bytes"
    assert_equals "$(command cat "$REPO/sub dir/new.json")" "$(gh_stub_file "$p" 'sub dir/new.json')" \
        "a new file (space in path, UTF-8 content) round-trips byte-exact"
    assert_equals '["gone.txt"]' "$(command jq -c '[.variables.input.fileChanges.deletions[].path]' "$p")" \
        "a removed file is a deletion"
    assert_equals "chore: headline" "$(command jq -r '.variables.input.message.headline' "$p")" "first line is the headline"
    assert_equals $'body line 1\nbody line 2' "$(command jq -r '.variables.input.message.body' "$p")" \
        "the rest, leading blank lines trimmed, is the body"
    assert_equals "" "$ERR" "a verified commit warns about nothing"
}

test_pathspec_limits_what_is_committed() {
    _repo
    gh_stub_install
    command mkdir -p "$REPO/tools"
    command printf 'x\n' >"$REPO/tools/a.json"
    command printf 'stray\n' >"$REPO/keep.txt"
    _commit tools
    assert_equals "0" "$RC" "commit succeeds"
    assert_equals '["tools/a.json"]' "$(command jq -c '[.variables.input.fileChanges.additions[].path]' "$(gh_stub_payload)")" \
        "only the pathspec is sent"
}

test_new_executable_is_refused_before_any_api_call() {
    _repo
    gh_stub_install
    command printf '#!/bin/sh\n' >"$REPO/new.sh"
    command chmod +x "$REPO/new.sh"
    _commit
    assert_equals "1" "$RC" "a new executable cannot be committed through the API"
    assert_contains "$ERR" "new.sh is new with mode 100755" "and says why"
    assert_equals "0" "$(command grep -c '^api graphql' "$GH_LOG" || true)" "nothing is sent"
}

test_mode_change_is_refused() {
    _repo
    gh_stub_install
    command chmod -x "$REPO/run.sh"
    _commit
    assert_equals "1" "$RC" "a mode change cannot be committed through the API"
    assert_contains "$ERR" "run.sh changes mode 100755 -> 100644" "and says why"
}

test_modified_executable_keeps_its_mode() {
    _repo
    gh_stub_install
    command printf '#!/bin/sh\necho hi\n' >"$REPO/run.sh"
    GH_STUB_TREE_MODE=100755 _commit
    assert_equals "0" "$RC" "editing an executable's content is fine when GitHub keeps the mode"
}

test_mode_lost_after_commit_is_an_error() {
    _repo
    gh_stub_install
    command printf '#!/bin/sh\necho hi\n' >"$REPO/run.sh"
    GH_STUB_TREE_MODE=100644 _commit
    assert_equals "1" "$RC" "a remote tree that dropped the exec bit fails the commit"
    assert_contains "$ERR" "run.sh committed as mode '100644', expected 100755" "and names the file"
}

test_unverified_commit_warns_but_succeeds() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_STUB_VERIFIED=false _commit
    assert_equals "0" "$RC" "an unverified commit is still a commit"
    assert_contains "$ERR" "::warning::commit c0ffee0001 on o/r:b is not reported as verified" "but is flagged"
}

test_nothing_staged_is_an_error() {
    _repo
    gh_stub_install
    _commit
    assert_equals "1" "$RC" "an empty change set is refused"
    assert_equals "0" "$(command grep -c '^api graphql' "$GH_LOG" || true)" "nothing is sent"
}

test_graphql_failure_is_an_error() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_FAIL=1 _commit
    assert_equals "1" "$RC" "a failed mutation fails the commit"
    assert_equals "3" "$(command grep -c '^api graphql' "$GH_LOG")" "after three attempts"
}

test_ensure_branch_creates_or_force_moves() {
    gh_stub_install
    PATH="$STUB_DIR:$PATH" gh_api_ensure_branch o/r feat/x abc123
    assert_equals "1" "$(command grep -cx 'api -X POST repos/o/r/git/refs -f ref=refs/heads/feat/x -f sha=abc123' "$GH_LOG")" \
        "a missing branch is created at the sha"
    : >"$GH_LOG"
    GH_STUB_REF_EXISTS=1 PATH="$STUB_DIR:$PATH" gh_api_ensure_branch o/r feat/x abc123
    assert_equals "1" "$(command grep -cx 'api -X PATCH repos/o/r/git/refs/heads/feat/x -f sha=abc123 -F force=true' "$GH_LOG")" \
        "an existing branch is force-moved to the sha"
    assert_equals "0" "$(command grep -c 'X POST' "$GH_LOG" || true)" "and not re-created"
}

test_publish_branch_creates_the_real_ref_only_at_the_signed_commit() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local rc=0 head out
    head="$(git -C "$REPO" rev-parse HEAD)"
    out="$(PATH="$STUB_DIR:$PATH" gh_api_publish_branch o/r auto-patch/20261102 "$REPO" "$MSG" 2>/dev/null)" || rc=$?
    assert_equals "0" "$rc" "publish succeeds"
    assert_equals "c0ffee0001" "$out" "prints the commit oid"
    assert_equals "auto-patch-staging/20261102" "$(command jq -r '.variables.input.branch.branchName' "$(gh_stub_payload)")" \
        "the commit is built on the staging ref"
    assert_equals "api -X POST repos/o/r/git/refs -f ref=refs/heads/auto-patch-staging/20261102 -f sha=$head
api -X POST repos/o/r/git/refs -f ref=refs/heads/auto-patch/20261102 -f sha=c0ffee0001
api -X DELETE repos/o/r/git/refs/heads/auto-patch-staging/20261102" \
        "$(command grep -E '^api -X (POST|DELETE)' "$GH_LOG")" \
        "the real ref is created once, at the signed commit, then staging is removed"
    assert_equals "0" "$(command grep -c 'refs/heads/auto-patch/20261102 -f sha='"$head" "$GH_LOG" || true)" \
        "the real ref never points at the bare base"
}

test_publish_branch_failure_cleans_up_staging() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local rc=0
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_FAIL=1 PATH="$STUB_DIR:$PATH" \
        gh_api_publish_branch o/r auto-patch/x "$REPO" "$MSG" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "a failed commit fails the publish"
    assert_equals "0" "$(command grep -c 'ref=refs/heads/auto-patch/x' "$GH_LOG" || true)" "the real ref is never created"
    assert_equals "1" "$(command grep -cx 'api -X DELETE repos/o/r/git/refs/heads/auto-patch-staging/x' "$GH_LOG")" \
        "the staging ref is removed"
}

run_test test_payload_carries_additions_deletions_and_expected_head "payload carries additions, deletions and expected head"
run_test test_pathspec_limits_what_is_committed "pathspec limits what is committed"
run_test test_new_executable_is_refused_before_any_api_call "a new executable is refused before any API call"
run_test test_mode_change_is_refused "a mode change is refused"
run_test test_modified_executable_keeps_its_mode "a modified executable keeps its mode"
run_test test_mode_lost_after_commit_is_an_error "a mode lost after the commit is an error"
run_test test_unverified_commit_warns_but_succeeds "an unverified commit warns but succeeds"
run_test test_nothing_staged_is_an_error "nothing staged is an error"
run_test test_graphql_failure_is_an_error "a GraphQL failure is an error after retries"
run_test test_ensure_branch_creates_or_force_moves "ensure_branch creates or force-moves"

run_test test_publish_branch_creates_the_real_ref_only_at_the_signed_commit "publish_branch creates the real ref only at the signed commit"
run_test test_publish_branch_failure_cleans_up_staging "publish_branch failure cleans up staging"

generate_report
