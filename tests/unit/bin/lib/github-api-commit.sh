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

test_publish_branch_rerun_force_moves_an_existing_branch() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local rc=0 out
    out="$(GH_STUB_REF_EXISTS=1 GH_STUB_REF_EXISTS_ONLY=heads/chore/m \
        PATH="$STUB_DIR:$PATH" gh_api_publish_branch o/r chore/m "$REPO" "$MSG" 2>/dev/null)" || rc=$?
    assert_equals "0" "$rc" "a re-run whose branch already exists still publishes"
    assert_equals "c0ffee0001" "$out" "and prints the oid"
    assert_equals "0" "$(command grep -c 'ref=refs/heads/chore/m' "$GH_LOG" || true)" "the existing branch is never re-created"
    assert_equals "1" "$(command grep -cx 'api -X PATCH repos/o/r/git/refs/heads/chore/m -f sha=c0ffee0001 -F force=true' "$GH_LOG")" \
        "the existing branch is force-moved to the new commit"
    assert_equals "1" "$(command grep -cx 'api -X DELETE repos/o/r/git/refs/heads/chore-staging/m' "$GH_LOG")" \
        "and staging is removed"
}

test_publish_branch_real_ref_failure_cleans_up_staging() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local rc=0 out
    # Both create and force-move of the real ref fail ("/auto-patch/x" is in
    # both argvs, never in the staging ref's "auto-patch-staging/x").
    out="$(GH_API_RETRY_DELAY=0 GH_STUB_FAIL_MATCH='heads/auto-patch/x' \
        PATH="$STUB_DIR:$PATH" gh_api_publish_branch o/r auto-patch/x "$REPO" "$MSG" 2>"$REPO.err")" || rc=$?
    assert_equals "1" "$rc" "failing to create the real ref fails the publish"
    assert_contains "$(command cat "$REPO.err")" "could not point auto-patch/x at c0ffee0001" "and names the branch and commit"
    assert_equals "" "$out" "and prints no oid"
    assert_equals "1" "$(command grep -cx 'api -X DELETE repos/o/r/git/refs/heads/auto-patch-staging/x' "$GH_LOG")" \
        "the staging ref is still removed"
}

test_publish_branch_force_move_failure_cleans_up_staging() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local rc=0 out
    out="$(GH_API_RETRY_DELAY=0 GH_STUB_REF_EXISTS=1 GH_STUB_REF_EXISTS_ONLY=heads/auto-patch/x \
        GH_STUB_FAIL_MATCH='heads/auto-patch/x' PATH="$STUB_DIR:$PATH" \
        gh_api_publish_branch o/r auto-patch/x "$REPO" "$MSG" 2>"$REPO.err")" || rc=$?
    assert_equals "1" "$rc" "a refused force-move of an existing branch fails the publish"
    assert_equals "" "$out" "and prints no oid"
    assert_contains "$(command cat "$REPO.err")" "could not point auto-patch/x at c0ffee0001" "and says so"
    assert_equals "1" "$(command grep -cx 'api -X DELETE repos/o/r/git/refs/heads/auto-patch-staging/x' "$GH_LOG")" \
        "the staging ref is still removed"
}

test_lost_response_adopts_the_commit_that_landed() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local head
    head="$(git -C "$REPO" rev-parse HEAD)"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_LANDED=1 GH_STUB_REF_EXISTS=1 \
        GH_STUB_BRANCH_HEAD=feedbeef GH_STUB_PARENT="$head" GH_STUB_TREE_MODE=100644 \
        GH_STUB_MESSAGE=$'chore: headline\n\nbody line 1\nbody line 2' _commit
    assert_equals "0" "$RC" "a commit that landed despite a failed response is success"
    assert_equals "feedbeef" "$OUT" "its oid is the branch head"
    assert_equals "1" "$(command grep -c '^api graphql' "$GH_LOG")" "and the mutation is not re-sent"
}

test_failed_mutation_with_unmoved_branch_is_retried() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_FAIL=1 GH_STUB_REF_EXISTS=1 \
        GH_STUB_BRANCH_HEAD="$(git -C "$REPO" rev-parse HEAD)" _commit
    assert_equals "1" "$RC" "nothing landed after three attempts"
    assert_equals "3" "$(command grep -c '^api graphql' "$GH_LOG")" "a branch still at base is retried"
}

test_branch_moved_elsewhere_is_an_error() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_FAIL=1 GH_STUB_REF_EXISTS=1 \
        GH_STUB_BRANCH_HEAD=d00dfeed GH_STUB_PARENT=unrelated _commit
    assert_equals "1" "$RC" "a branch moved by someone else is not adopted"
    assert_contains "$ERR" "moved to d00dfeed, not our commit on" "and says so"
    assert_equals "1" "$(command grep -c '^api graphql' "$GH_LOG")" "nor retried into an expectedHeadOid failure"
}

test_foreign_child_of_base_is_not_adopted() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_FAIL=1 GH_STUB_REF_EXISTS=1 GH_STUB_BRANCH_HEAD=feedbeef \
        GH_STUB_PARENT="$(git -C "$REPO" rev-parse HEAD)" GH_STUB_MESSAGE='someone else' _commit
    assert_equals "1" "$RC" "a child of base with another message is not ours"
    assert_equals "" "$OUT" "and is not adopted"
    assert_contains "$ERR" "moved to feedbeef, not our commit on" "it is refused as foreign"
    assert_not_contains "$ERR" "landed on" "never adopted first and failed later"
}

test_transient_failure_then_success_returns_the_new_oid() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_FAIL_FIRST=1 GH_STUB_REF_EXISTS=1 \
        GH_STUB_BRANCH_HEAD="$(git -C "$REPO" rev-parse HEAD)" _commit
    assert_equals "0" "$RC" "a transient failure with nothing landed recovers"
    assert_equals "c0ffee0001" "$OUT" "with the retried attempt's oid"
    assert_equals "2" "$(command grep -c '^api graphql' "$GH_LOG")" "after exactly one retry"
}

test_failed_probe_on_existing_branch_still_force_moves() {
    gh_stub_install
    local rc=0
    # Probe fails (reads as absent), create is refused (422): must force-move.
    GH_STUB_FAIL_MATCH='-X POST' PATH="$STUB_DIR:$PATH" gh_api_ensure_branch o/r chore/m abc123 || rc=$?
    assert_equals "0" "$rc" "an existing branch behind a failed probe is still pointed at the sha"
    assert_equals "1" "$(command grep -cx 'api -X PATCH repos/o/r/git/refs/heads/chore/m -f sha=abc123 -F force=true' "$GH_LOG")" \
        "by falling back from create to force-move"
}

test_probe_hit_then_vanished_branch_is_created() {
    gh_stub_install
    local rc=0
    # Probe sees the branch, it is deleted before the force-move: must create.
    GH_STUB_REF_EXISTS=1 GH_STUB_FAIL_MATCH='-X PATCH' PATH="$STUB_DIR:$PATH" \
        gh_api_ensure_branch o/r chore/m abc123 || rc=$?
    assert_equals "0" "$rc" "a branch that vanished after the probe is still pointed at the sha"
    assert_equals "1" "$(command grep -cx 'api -X POST repos/o/r/git/refs -f ref=refs/heads/chore/m -f sha=abc123' "$GH_LOG")" \
        "by falling back from force-move to create"
}

test_unreadable_file_never_becomes_an_empty_addition() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    # A base64 that fails stands in for a file that cannot be read.
    command printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB_DIR/base64"
    command chmod +x "$STUB_DIR/base64"
    _commit
    assert_equals "1" "$RC" "a failed read fails the commit"
    assert_contains "$ERR" "could not encode keep.txt" "and names the file"
    assert_equals "0" "$(command grep -c '^api graphql' "$GH_LOG" || true)" "nothing (and no empty contents) is sent"
}

test_symlink_and_submodule_changes_are_refused() {
    _repo
    gh_stub_install
    command ln -s keep.txt "$REPO/link"
    git -C "$REPO" add link
    git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m link
    command ln -sfn gone.txt "$REPO/link"
    _commit
    assert_equals "1" "$RC" "a modified symlink is refused (the API would commit it as a file)"
    assert_contains "$ERR" "link has mode 120000; the API commits only regular files" "and says why"
    assert_equals "0" "$(command grep -c '^api graphql' "$GH_LOG" || true)" "nothing is sent"
}

test_staging_create_failure_still_cleans_up_staging() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local rc=0
    GH_API_RETRY_DELAY=0 GH_STUB_FAIL_MATCH='auto-patch-staging/x -f sha' PATH="$STUB_DIR:$PATH" \
        gh_api_publish_branch o/r auto-patch/x "$REPO" "$MSG" >/dev/null 2>&1 || rc=$?
    assert_equals "1" "$rc" "failing to set the staging ref fails the publish"
    assert_equals "0" "$(command grep -c '^api graphql' "$GH_LOG" || true)" "no commit is attempted"
    assert_equals "1" "$(command grep -cx 'api -X DELETE repos/o/r/git/refs/heads/auto-patch-staging/x' "$GH_LOG")" \
        "a staging ref that may have landed is still removed"
}

test_staging_delete_failure_only_warns() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local rc=0 out
    out="$(GH_STUB_FAIL_MATCH='-X DELETE' PATH="$STUB_DIR:$PATH" \
        gh_api_publish_branch o/r auto-patch/x "$REPO" "$MSG" 2>"$REPO.err")" || rc=$?
    assert_equals "0" "$rc" "a leftover staging ref does not fail a landed publish"
    assert_equals "c0ffee0001" "$out" "the oid is still printed"
    assert_contains "$(command cat "$REPO.err")" "::warning::could not delete staging branch auto-patch-staging/x" \
        "but it is flagged"
}

test_truncated_tree_warns_and_tree_read_failure_errors() {
    _repo
    gh_stub_install
    command printf '#!/bin/sh\necho hi\n' >"$REPO/run.sh"
    GH_STUB_TREE_TRUNCATED=1 GH_STUB_TREE_MODE=100644 _commit
    assert_equals "0" "$RC" "a truncated tree cannot be checked, so it does not fail the commit"
    assert_contains "$ERR" "::warning::tree of c0ffee0001 is truncated; file modes not verified" "but says so"
    command printf '#!/bin/sh\necho bye\n' >"$REPO/run.sh"
    GH_STUB_FAIL_MATCH='git/trees/' _commit
    assert_equals "1" "$RC" "an unreadable tree fails the commit: the modes are unverified"
    assert_contains "$ERR" "could not read the tree" "and says why"
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
run_test test_publish_branch_rerun_force_moves_an_existing_branch "publish_branch re-run force-moves an existing branch"
run_test test_publish_branch_real_ref_failure_cleans_up_staging "publish_branch real-ref failure cleans up staging"
run_test test_publish_branch_force_move_failure_cleans_up_staging "publish_branch force-move failure cleans up staging"
run_test test_lost_response_adopts_the_commit_that_landed "a lost response adopts the commit that landed"
run_test test_failed_mutation_with_unmoved_branch_is_retried "a failed mutation with an unmoved branch is retried"
run_test test_branch_moved_elsewhere_is_an_error "a branch moved elsewhere is an error"
run_test test_foreign_child_of_base_is_not_adopted "a foreign child of base is not adopted"
run_test test_transient_failure_then_success_returns_the_new_oid "a transient failure then success returns the new oid"
run_test test_failed_probe_on_existing_branch_still_force_moves "a failed probe on an existing branch still force-moves"
run_test test_probe_hit_then_vanished_branch_is_created "a branch that vanished after the probe is created"
run_test test_unreadable_file_never_becomes_an_empty_addition "an unreadable file never becomes an empty addition"
run_test test_symlink_and_submodule_changes_are_refused "symlink and submodule changes are refused"
run_test test_staging_create_failure_still_cleans_up_staging "a staging create failure still cleans up staging"
run_test test_staging_delete_failure_only_warns "a staging delete failure only warns"
run_test test_truncated_tree_warns_and_tree_read_failure_errors "truncated tree warns; unreadable tree errors"

generate_report
