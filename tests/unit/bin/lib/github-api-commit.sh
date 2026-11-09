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

# _ensure <status> — gh_api_ensure_branch on a missing branch whose ref
# create/move both fail with "HTTP <status>"; sets RC and ERR.
_ensure() {
    local rc=0
    GH_API_RETRY_DELAY=0 GH_STUB_FAIL_MATCH='git/refs' GH_STUB_FAIL_STATUS="$1" PATH="$STUB_DIR:$PATH" \
        gh_api_ensure_branch o/r feat/x abc123 2>"$STUB_DIR/err" || rc=$?
    RC="$rc"
    ERR="$(command cat "$STUB_DIR/err")"
}

test_permanent_4xx_is_not_retried_and_logged() {
    gh_stub_install
    _ensure 403
    assert_equals "1" "$RC" "a 403 fails the call"
    assert_equals "1" "$(command grep -c 'X POST' "$GH_LOG")" "after ONE attempt"
    assert_contains "$ERR" "gh: Failed (HTTP 403)" "GitHub's message is shown"
    assert_contains "$ERR" "permanent error from _gh_api_create_or_move" "and why it stopped"
}

test_429_and_5xx_are_retried() {
    local s
    for s in 429 502; do
        gh_stub_install
        _ensure "$s"
        assert_equals "1" "$RC" "HTTP $s still fails in the end"
        assert_equals "3" "$(command grep -c 'X POST' "$GH_LOG")" "but HTTP $s is retried three times"
        assert_not_contains "$ERR" "permanent error" "HTTP $s is transient"
    done
}

test_graphql_permission_error_is_not_retried_and_logged() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS='FORBIDDEN:Resource not accessible by integration' _commit
    assert_equals "1" "$RC" "a permission error fails the commit"
    assert_equals "1" "$(command grep -c '^api graphql' "$GH_LOG")" "after ONE attempt"
    assert_contains "$ERR" "FORBIDDEN: Resource not accessible by integration" "the errors body is logged"
    assert_contains "$ERR" "permanent error on o/r:b, not retrying" "and why it stopped"
}

test_graphql_unresolvable_repository_is_not_retried() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS='NOT_FOUND:Could not resolve to a Repository with the name o/r.' _commit
    assert_equals "1" "$RC" "a missing repository fails the commit"
    assert_equals "1" "$(command grep -c '^api graphql' "$GH_LOG")" "after ONE attempt"
    assert_contains "$ERR" "permanent error on o/r:b, not retrying" "and says why it stopped"
}

test_create_pr_stderr_cannot_issue_workflow_commands() {
    gh_stub_install
    GH_STUB_PR_CREATE_FAIL=1 GH_STUB_PR_CREATE_URL='::add-mask::x' _pr
    assert_contains "$ERR" "  ::add-mask::x" "gh pr create's stderr is replayed indented"
    assert_equals "0" "$(command grep -c '^::' <<<"$ERR")" "so no line starts with '::'"
}

test_graphql_forbidden_rate_limit_is_retried() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS='FORBIDDEN:You have exceeded a secondary rate limit' _commit
    assert_equals "3" "$(command grep -c '^api graphql' "$GH_LOG")" "a FORBIDDEN rate limit is retried every attempt"
    assert_not_contains "$ERR" "permanent error" "and is not called permanent"
}

test_exit0_errors_body_is_logged_and_classified() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS_EXIT0=1 \
        GH_STUB_GRAPHQL_ERRORS='UNPROCESSABLE:Repository rule violations found' _commit
    assert_equals "1" "$RC" "an exit-0 errors body fails the commit"
    assert_equals "1" "$(command grep -c '^api graphql' "$GH_LOG")" "a ruleset rejection is not retried"
    assert_contains "$ERR" "$(command printf '(exit 0):\n  UNPROCESSABLE: Repository rule violations found')" \
        "its message is logged, indented on its own line"
    gh_stub_install
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS_EXIT0=1 GH_STUB_GRAPHQL_ERRORS='INTERNAL:Something went wrong' _commit
    assert_equals "1" "$RC" "an unknown errors body fails the commit"
    assert_equals "3" "$(command grep -c '^api graphql' "$GH_LOG")" "but an unknown error is retried"
    assert_contains "$ERR" "INTERNAL: Something went wrong" "and logged"
}

# _pr — gh_api_create_pr with the stub on PATH; sets OUT, ERR and RC.
_pr() {
    local rc=0
    OUT="$(GH_API_RETRY_DELAY=0 PATH="$STUB_DIR:$PATH" \
        gh_api_create_pr --repo o/r --base main --head ev/b --title t --body b 2>"$STUB_DIR/err")" || rc=$?
    RC="$rc"
    ERR="$(command cat "$STUB_DIR/err")"
}

test_create_pr_reuses_an_open_pr() {
    gh_stub_install
    GH_STUB_PR_EXISTING=https://x/pull/7 _pr
    assert_equals "0" "$RC" "an open PR for the head is success"
    assert_equals "https://x/pull/7" "$OUT" "and resolves to that PR"
    assert_equals "0" "$(command grep -c '^pr create' "$GH_LOG" || true)" "no second PR is created"
    assert_equals "1" "$(command grep -c '^pr list --repo o/r --head ev/b --state open --json url,isCrossRepository,baseRefName ' "$GH_LOG")" \
        "the lookup is scoped to the repo and head"
}

test_create_pr_whose_attempt_landed_resolves_to_it() {
    gh_stub_install
    GH_STUB_PR_CREATE_FAIL=1 GH_STUB_PR_AFTER_CREATE=https://x/pull/8 _pr
    assert_equals "0" "$RC" "a create that landed but failed here is success"
    assert_equals "https://x/pull/8" "$OUT" "and resolves to the existing PR"
    assert_equals "1" "$(command grep -c '^pr create' "$GH_LOG")" "without re-sending the create"
    assert_contains "$ERR" "create failed but a PR for ev/b is open; using it" "and says so"
}

test_create_pr_failure_with_no_pr_fails() {
    gh_stub_install
    GH_STUB_PR_CREATE_FAIL=1 _pr
    assert_equals "1" "$RC" "no PR anywhere is a failure"
    assert_equals "" "$OUT" "and prints no URL"
    assert_contains "$ERR" "already exists" "gh's message is shown"
    gh_stub_install
    _pr
    assert_equals "https://github.com/joshjhall/containers-db/pull/9" "$OUT" "a plain create prints the new PR"
}

# _perm <stderr text> — "permanent" or "transient" per _gh_api_is_permanent.
_perm() {
    local f="$STUB_DIR/perm.err"
    command printf '%b' "$1" >"$f"
    if _gh_api_is_permanent "$f"; then command echo permanent; else command echo transient; fi
}

test_is_permanent_classifies_by_last_line() {
    gh_stub_install
    local want text
    while IFS='|' read -r want text; do
        assert_equals "$want" "$(_perm "$text")" "'$text' is $want"
    done <<'TABLE'
permanent|gh: Bad credentials (HTTP 401)
permanent|gh: Not Found (HTTP 404)
permanent|gh: Validation Failed (HTTP 422)
permanent|GraphQL: No commits between main and x (createPullRequest)
permanent|GraphQL: Could not resolve to a Repository
permanent|gh: Resource not accessible by integration (HTTP 403)
permanent|gh: Repository rule violations found
permanent|gh: Merge not permitted
transient|gh: Object does not exist (HTTP 422)
transient|gh: Reference does not exist (HTTP 422)
transient|gh: Conflict (HTTP 409)
transient|gh: Request Timeout (HTTP 408)
transient|gh: API rate limit exceeded (HTTP 403)
transient|gh: You have triggered an abuse detection mechanism (HTTP 403)
transient|gh: Too Many Requests (HTTP 429)
transient|gh: Bad Gateway (HTTP 502)
transient|dial tcp: i/o timeout
transient|Could not resolve host: api.github.com
transient|
transient|gh: Reference already exists (HTTP 422)\ngh: Bad Gateway (HTTP 502)\n\n
permanent|gh: Bad Gateway (HTTP 502)\ngh: Forbidden (HTTP 403)
transient|gh: Bad Gateway (HTTP 502)\ngh: Reference already exists (HTTP 422)
permanent|gh: Forbidden (HTTP 403)\ngh: Reference already exists (HTTP 422)
transient|GraphQL: Could not resolve to a PullRequest with the number of 7.
transient|GraphQL: Could not resolve to a Ref with the name b
transient|gh: Reference already exists (HTTP 422)
permanent|GraphQL: Could not resolve to a Repository\ngh: Reference already exists (HTTP 422)
TABLE
}

test_transient_move_then_existing_create_is_retried() {
    gh_stub_install
    local rc=0
    # Probe sees the branch; the force-move hits a 502 once and the fallback
    # create answers "already exists". That last line must not make the
    # transient 502 permanent: the retry's force-move succeeds.
    GH_API_RETRY_DELAY=0 GH_STUB_REF_EXISTS=1 GH_STUB_CREATE_EXISTS=1 \
        GH_STUB_FAIL_MATCH='-X PATCH' GH_STUB_FAIL_TIMES=1 GH_STUB_FAIL_STATUS=502 \
        GH_STUB_FAIL_MSG='Bad Gateway' PATH="$STUB_DIR:$PATH" \
        gh_api_ensure_branch o/r chore/m abc123 2>"$STUB_DIR/err" || rc=$?
    assert_equals "0" "$rc" "a transient force-move failure is recovered"
    assert_equals "2" "$(command grep -cx 'api -X PATCH repos/o/r/git/refs/heads/chore/m -f sha=abc123 -F force=true' "$GH_LOG")" \
        "by retrying the force-move once"
    assert_not_contains "$(command cat "$STUB_DIR/err")" "permanent error" "and is not called permanent"
}

test_permanent_move_then_existing_create_is_not_retried() {
    gh_stub_install
    local rc=0
    GH_API_RETRY_DELAY=0 GH_STUB_REF_EXISTS=1 GH_STUB_CREATE_EXISTS=1 \
        GH_STUB_FAIL_MATCH='-X PATCH' GH_STUB_FAIL_STATUS=403 GH_STUB_FAIL_MSG='Forbidden' \
        PATH="$STUB_DIR:$PATH" gh_api_ensure_branch o/r chore/m abc123 2>"$STUB_DIR/err" || rc=$?
    assert_equals "1" "$rc" "a refused force-move fails"
    assert_equals "1" "$(command grep -c 'X PATCH' "$GH_LOG")" "after ONE attempt"
    assert_contains "$(command cat "$STUB_DIR/err")" "Forbidden (HTTP 403)" "with GitHub's message"
}

test_409_conflict_is_retried() {
    gh_stub_install
    _ensure 409
    assert_equals "3" "$(command grep -c 'X POST' "$GH_LOG")" "a racing-update 409 is retried"
    assert_not_contains "$ERR" "permanent error" "and is not called permanent"
}

test_replayed_stderr_cannot_issue_workflow_commands() {
    gh_stub_install
    _ensure 403
    assert_contains "$ERR" "  gh: Failed (HTTP 403)" "gh's stderr is replayed indented"
    assert_equals "0" "$(command grep -c '^gh:' <<<"$ERR" || true)" "never at column 0, where :: would be a command"
}

test_create_pr_requires_head_and_scopes_lookup_without_repo() {
    gh_stub_install
    local rc=0
    PATH="$STUB_DIR:$PATH" gh_api_create_pr --base main --title t 2>"$STUB_DIR/err" || rc=$?
    assert_equals "1" "$rc" "no --head is an error"
    assert_contains "$(command cat "$STUB_DIR/err")" "gh_api_create_pr: --head is required" "and says why"
    assert_equals "0" "$(command grep -c '^pr ' "$GH_LOG" || true)" "before any gh call"
    local out
    out="$(GH_STUB_PR_EXISTING=https://x/pull/3 PATH="$STUB_DIR:$PATH" gh_api_create_pr -H m/x --base main 2>/dev/null)"
    assert_equals "https://x/pull/3" "$out" "the -H alias and the current repo work"
    assert_equals "1" "$(command grep -c '^pr list --head m/x ' "$GH_LOG")" "the lookup carries no --repo"
}

test_create_pr_ignores_a_fork_pr_on_the_same_branch() {
    gh_stub_install
    GH_STUB_PR_EXISTING=https://x/pull/66 GH_STUB_PR_FORK=1 _pr
    assert_equals "0" "$RC" "a fork PR does not block creating ours"
    assert_equals "https://github.com/joshjhall/containers-db/pull/9" "$OUT" "ours is created, the fork PR never adopted"
    assert_equals "1" "$(command grep -c '^pr create' "$GH_LOG")" "with one create"
}

test_graphql_errors_cannot_issue_workflow_commands() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS_EXIT0=1 \
        GH_STUB_GRAPHQL_ERRORS="$(command printf 'FORBIDDEN:denied\n::add-mask::x')" _commit
    assert_equals "1" "$RC" "the commit fails"
    assert_contains "$ERR" "  ::add-mask::x" "a later '::' line of GitHub's message is logged indented"
    assert_equals "0" "$(command grep -c '^::add-mask::' <<<"$ERR" || true)" "and never at column 0"
}

test_not_found_graphql_error_is_retried() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS="NOT_FOUND:Could not resolve to a Ref with the name b" _commit
    assert_equals "1" "$RC" "an unresolved branch still fails in the end"
    assert_equals "3" "$(command grep -c '^api graphql' "$GH_LOG")" "but is retried: a new ref can lag"
    assert_not_contains "$ERR" "permanent error" "and is not called permanent"
}

test_permanent_error_does_not_preempt_adopting_a_landed_commit() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    local base
    base="$(git -C "$REPO" rev-parse HEAD)"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS='FORBIDDEN:Resource not accessible by integration' \
        GH_STUB_REF_EXISTS=1 GH_STUB_BRANCH_HEAD=d00dfeed GH_STUB_PARENT="$base" _commit
    assert_equals "0" "$RC" "a commit that landed is adopted despite the permanent error"
    assert_equals "d00dfeed" "$OUT" "and its oid is printed"
    assert_not_contains "$ERR" "permanent error on" "the read-back runs before the permanent stop"
}

test_create_pr_with_failing_lookup_still_creates_or_fails() {
    gh_stub_install
    GH_STUB_PR_LIST_FAIL=1 _pr
    assert_equals "0" "$RC" "a failed lookup does not block the create"
    assert_equals "https://github.com/joshjhall/containers-db/pull/9" "$OUT" "the new PR is printed"
    gh_stub_install
    GH_STUB_PR_LIST_FAIL=1 GH_STUB_PR_CREATE_FAIL=1 _pr
    assert_equals "1" "$RC" "a failed create with no lookup to rescue it fails"
    assert_equals "" "$OUT" "and prints no URL"
    assert_equals "3" "$(command grep -c '^pr create' "$GH_LOG")" "after the transient retries"
}

test_ref_replication_lag_422_is_retried_until_it_clears() {
    gh_stub_install
    local rc=0 n
    # create and move both fail with a lag 422 on the first two attempts.
    GH_STUB_FAIL_MATCH='git/refs' GH_STUB_FAIL_STATUS=422 GH_STUB_FAIL_MSG='Reference does not exist' \
        GH_API_RETRY_DELAY=0 PATH="$STUB_DIR:$PATH" gh_api_ensure_branch o/r feat/x abc123 2>"$STUB_DIR/err" || rc=$?
    n="$(command grep -c 'X POST' "$GH_LOG")"
    assert_equals "3" "$n" "a lag 422 is retried, not failed after one attempt"
    assert_not_contains "$(command cat "$STUB_DIR/err")" "permanent error" "and is not called permanent"
}

test_create_pr_uses_the_url_gh_reports_when_lookup_fails() {
    gh_stub_install
    GH_STUB_PR_LIST_FAIL=1 GH_STUB_PR_CREATE_FAIL=1 GH_STUB_PR_CREATE_URL=https://github.com/o/r/pull/12 _pr
    assert_equals "0" "$RC" "an 'already exists' create is success"
    assert_equals "https://github.com/o/r/pull/12" "$OUT" "resolving to the PR gh names"
    assert_equals "1" "$(command grep -c '^pr create' "$GH_LOG")" "without re-sending the create"
}

test_create_pr_ignores_a_reported_url_for_another_repo() {
    gh_stub_install
    GH_STUB_PR_LIST_FAIL=1 GH_STUB_PR_CREATE_FAIL=1 GH_STUB_PR_CREATE_URL=https://github.com/evil/r/pull/12 _pr
    assert_equals "1" "$RC" "a URL naming another repo is not adopted"
    assert_equals "" "$OUT" "and nothing is printed for auto-merge"
    gh_stub_install
    GH_STUB_PR_LIST_FAIL=1 GH_STUB_PR_CREATE_FAIL=1 GH_STUB_PR_CREATE_URL=https://evil.example/o/r/pull/12 _pr
    assert_equals "1" "$RC" "nor one on another host"
    local out rc=0
    gh_stub_install
    out="$(GH_API_RETRY_DELAY=0 GITHUB_REPOSITORY=o/r GH_STUB_PR_LIST_FAIL=1 GH_STUB_PR_CREATE_FAIL=1 \
        GH_STUB_PR_CREATE_URL=https://github.com/o/r/pull/5 PATH="$STUB_DIR:$PATH" \
        gh_api_create_pr --base main --head m/x 2>/dev/null)" || rc=$?
    assert_equals "0" "$rc" "without --repo, GITHUB_REPOSITORY names the target"
    assert_equals "https://github.com/o/r/pull/5" "$out" "and its PR is adopted"
    rc=0
    gh_stub_install
    out="$(GH_API_RETRY_DELAY=0 GITHUB_REPOSITORY='' GH_STUB_PR_LIST_FAIL=1 GH_STUB_PR_CREATE_FAIL=1 \
        GH_STUB_PR_CREATE_URL=https://github.com/o/r/pull/5 PATH="$STUB_DIR:$PATH" \
        gh_api_create_pr --base main --head m/x 2>/dev/null)" || rc=$?
    assert_equals "1" "$rc" "with no repository known, no URL is adopted"
}

test_create_pr_short_repo_and_base_flags() {
    gh_stub_install
    local out
    out="$(GH_STUB_PR_EXISTING=https://github.com/o/r/pull/4 GH_STUB_PR_BASE=dev PATH="$STUB_DIR:$PATH" \
        gh_api_create_pr -R o/r -H x -B dev --title t 2>/dev/null)"
    assert_equals "https://github.com/o/r/pull/4" "$out" "-R/-H/-B find the open PR"
    assert_equals "1" "$(command grep -c '^pr list --repo o/r --head x ' "$GH_LOG")" "the lookup carries -R as --repo"
    out="$(GH_STUB_PR_EXISTING=https://github.com/o/r/pull/4 GH_STUB_PR_BASE=main PATH="$STUB_DIR:$PATH" \
        gh_api_create_pr -R o/r -H x -B dev --title t 2>/dev/null)" || true
    assert_not_contains "$out" "pull/4" "and -B filters out a PR into another base"
}

test_graphql_insufficient_scopes_is_not_retried() {
    _repo
    gh_stub_install
    command printf 'changed\n' >"$REPO/keep.txt"
    GH_API_RETRY_DELAY=0 GH_STUB_GRAPHQL_ERRORS='INSUFFICIENT_SCOPES:Your token has not been granted the required scopes' _commit
    assert_equals "1" "$RC" "a scope error fails the commit"
    assert_equals "1" "$(command grep -c '^api graphql' "$GH_LOG")" "after ONE attempt"
}

test_create_pr_parses_equals_forms_and_filters_on_base() {
    gh_stub_install
    local out
    out="$(GH_STUB_PR_EXISTING=https://x/pull/5 PATH="$STUB_DIR:$PATH" \
        gh_api_create_pr --repo=o/r --head=ev/b --base=main --title t 2>/dev/null)"
    assert_equals "https://x/pull/5" "$out" "--repo=/--head=/--base= are understood"
    assert_equals "1" "$(command grep -c '^pr list --repo o/r --head ev/b ' "$GH_LOG")" "the lookup targets that repo and head"
    gh_stub_install
    GH_STUB_PR_EXISTING=https://x/pull/6 GH_STUB_PR_BASE=release _pr
    assert_equals "https://github.com/joshjhall/containers-db/pull/9" "$OUT" "a PR into another base is not adopted"
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

run_test test_permanent_4xx_is_not_retried_and_logged "a permanent 4xx is not retried and is logged"
run_test test_429_and_5xx_are_retried "429 and 5xx are retried"
run_test test_graphql_permission_error_is_not_retried_and_logged "a GraphQL permission error is not retried and is logged"
run_test test_graphql_unresolvable_repository_is_not_retried "an unresolvable GraphQL Repository is not retried"
run_test test_create_pr_stderr_cannot_issue_workflow_commands "gh pr create stderr cannot issue workflow commands"
run_test test_graphql_forbidden_rate_limit_is_retried "a GraphQL FORBIDDEN rate limit is retried"
run_test test_exit0_errors_body_is_logged_and_classified "an exit-0 errors body is logged and classified"
run_test test_create_pr_reuses_an_open_pr "create_pr reuses an open PR"
run_test test_create_pr_whose_attempt_landed_resolves_to_it "create_pr whose attempt landed resolves to it"
run_test test_create_pr_failure_with_no_pr_fails "create_pr failure with no PR fails"

run_test test_is_permanent_classifies_by_last_line "the classifier judges the last stderr line"
run_test test_transient_move_then_existing_create_is_retried "a transient force-move then an existing create is retried"
run_test test_permanent_move_then_existing_create_is_not_retried "a refused force-move then an existing create is not retried"
run_test test_409_conflict_is_retried "a 409 conflict is retried"
run_test test_replayed_stderr_cannot_issue_workflow_commands "replayed stderr cannot issue workflow commands"
run_test test_create_pr_requires_head_and_scopes_lookup_without_repo "create_pr requires --head; works without --repo"
run_test test_create_pr_ignores_a_fork_pr_on_the_same_branch "create_pr ignores a fork PR on the same branch"

run_test test_graphql_errors_cannot_issue_workflow_commands "GraphQL errors cannot issue workflow commands"
run_test test_not_found_graphql_error_is_retried "a NOT_FOUND GraphQL error is retried"
run_test test_permanent_error_does_not_preempt_adopting_a_landed_commit "a permanent error does not pre-empt adopting a landed commit"
run_test test_create_pr_with_failing_lookup_still_creates_or_fails "create_pr with a failing lookup still creates or fails"
run_test test_ref_replication_lag_422_is_retried_until_it_clears "a ref replication-lag 422 is retried"
run_test test_create_pr_uses_the_url_gh_reports_when_lookup_fails "create_pr uses the URL gh reports when the lookup fails"
run_test test_create_pr_ignores_a_reported_url_for_another_repo "create_pr ignores a reported URL for another repo"
run_test test_create_pr_short_repo_and_base_flags "create_pr accepts -R and -B"
run_test test_graphql_insufficient_scopes_is_not_retried "an INSUFFICIENT_SCOPES error is not retried"
run_test test_create_pr_parses_equals_forms_and_filters_on_base "create_pr parses --x= forms and filters on base"

generate_report
