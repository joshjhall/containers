#!/usr/bin/env bash
# Unit tests for bin/lib/compat-matrix-pr.sh (#1584): the auto-patch
# post-merge job lands its compatibility-matrix update as an API-signed commit
# on chore/compat-matrix-v<version>, reuses or creates the PR, and enables
# auto-merge with a retry. `gh` is a fake GitHub on PATH
# (tests/lib/gh-api-stub.sh) that logs its argv.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../framework.sh"
# shellcheck source=tests/lib/gh-api-stub.sh
source "$SCRIPT_DIR/../../../lib/gh-api-stub.sh"

init_test_framework

test_suite "Bin Lib Compat Matrix PR Tests"

# shellcheck source=bin/lib/compat-matrix-pr.sh
source "$PROJECT_ROOT/bin/lib/compat-matrix-pr.sh"

STUB_PR="https://github.com/joshjhall/containers-db/pull/9"
OPEN_PR="https://github.com/o/r/pull/77"

# _setup — a checkout whose matrix file has an uncommitted change, plus the stub.
_setup() {
    REPO="$(command mktemp -d "$TEST_TEMP_DIR/r.XXXXXX")"
    git -C "$REPO" init -q -b main
    command printf '{"v":1}\n' >"$REPO/matrix.json"
    git -C "$REPO" add .
    git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
    command printf '{"v":2}\n' >"$REPO/matrix.json"
    gh_stub_install
}

# _publish — compat_matrix_publish_pr with the stub on PATH; sets OUT, ERR, RC.
_publish() {
    local rc=0
    OUT="$(PATH="$STUB_DIR:$PATH" GH_API_RETRY_DELAY=0 COMPAT_MATRIX_MERGE_DELAY=0 \
        compat_matrix_publish_pr o/r 1.2.3 "$REPO" matrix.json 2>"$REPO.err")" || rc=$?
    ERR="$(command cat "$REPO.err")"
    RC="$rc"
}

_count() { command grep -cE "$1" "$GH_LOG" || true; }

test_creates_pr_and_enables_automerge() {
    _setup
    _publish
    assert_equals "0" "$RC" "publish succeeds"
    assert_equals "$STUB_PR" "$OUT" "prints the created PR's URL"
    assert_equals "1" "$(_count '^pr create .*--head chore/compat-matrix-v1\.2\.3 ')" \
        "exactly one PR is created for the versioned branch"
    assert_equals "1" "$(_count '^api -X POST repos/o/r/git/refs -f ref=refs/heads/chore/compat-matrix-v1\.2\.3 -f sha=c0ffee0001$')" \
        "the matrix branch is created at the finished commit"
    assert_equals "1" "$(_count "^pr merge $STUB_PR --repo o/r --auto --squash --delete-branch$")" \
        "auto-merge is enabled once, on the created PR"
    local p
    p="$(gh_stub_payload)"
    assert_equals "chore: update compatibility matrix for v1.2.3" \
        "$(command jq -r '.variables.input.message.headline' "$p")" "headline names the version"
    assert_equals '{"v":2}' "$(gh_stub_file "$p" matrix.json)" "the commit carries the updated matrix"
}

test_reuses_open_pr() {
    _setup
    GH_STUB_PR_EXISTING="$OPEN_PR" _publish
    assert_equals "0" "$RC" "publish succeeds"
    assert_equals "$OPEN_PR" "$OUT" "prints the already-open PR's URL"
    assert_equals "0" "$(_count '^pr create')" "no second PR is created"
    assert_equals "1" "$(_count "^pr merge $OPEN_PR --repo o/r --auto --squash --delete-branch$")" \
        "auto-merge is enabled on the reused PR"
}

test_automerge_is_retried() {
    _setup
    GH_STUB_PR_MERGE_FAIL_FIRST=2 _publish
    assert_equals "0" "$RC" "publish succeeds"
    assert_equals "3" "$(_count '^pr merge ')" "two refusals, then the third attempt sticks"
    assert_contains "$ERR" "Auto-merge enabled on attempt 3" "reports the attempt that worked"
    assert_not_contains "$ERR" "::warning::" "no warning once auto-merge sticks"
}

test_automerge_exhausted_is_a_warning() {
    _setup
    GH_STUB_PR_MERGE_FAIL_FIRST=99 _publish
    assert_equals "0" "$RC" "an open PR without auto-merge is still a success"
    assert_equals "$STUB_PR" "$OUT" "the PR URL is still printed"
    assert_equals "5" "$(_count '^pr merge ')" "auto-merge is tried exactly 5 times"
    assert_contains "$ERR" "::warning::could not enable auto-merge on $STUB_PR" "warns to merge manually"
}

test_commit_failure_opens_no_pr() {
    _setup
    GH_STUB_GRAPHQL_FAIL=1 _publish
    assert_equals "1" "$RC" "a failed commit fails the publish"
    assert_equals "" "$OUT" "no PR URL is printed"
    assert_equals "0" "$(_count '^pr (create|list)')" "no PR is looked up or created"
    assert_equals "0" "$(_count '^pr merge')" "auto-merge is never attempted"
    assert_equals "0" "$(_count '^api -X (POST|PATCH) .*refs/heads/chore/compat-matrix-v')" \
        "the matrix branch is never created"
    assert_equals "1" "$(_count '^api -X DELETE repos/o/r/git/refs/heads/chore-staging/compat-matrix-v1\.2\.3$')" \
        "the staging ref the commit was attempted on is deleted"
    assert_contains "$ERR" "could not commit matrix.json to o/r:chore/compat-matrix-v1.2.3" "names what failed"
}

test_pr_failure_fails_without_automerge() {
    _setup
    GH_STUB_PR_CREATE_FAIL=1 _publish
    assert_equals "1" "$RC" "a PR that cannot be opened fails the publish"
    assert_equals "" "$OUT" "no PR URL is printed"
    assert_equals "0" "$(_count '^pr merge')" "auto-merge is never attempted"
    assert_contains "$ERR" "could not open a PR for chore/compat-matrix-v1.2.3" "names what failed"
}

run_test test_creates_pr_and_enables_automerge "no open PR: creates one and enables auto-merge"
run_test test_reuses_open_pr "an open PR for the branch is reused, not duplicated"
run_test test_automerge_is_retried "a refused auto-merge is retried until it sticks"
run_test test_automerge_exhausted_is_a_warning "auto-merge refused 5 times is a warning, not a failure"
run_test test_commit_failure_opens_no_pr "a failed commit opens no PR and no branch"
run_test test_pr_failure_fails_without_automerge "a failed PR create fails without trying auto-merge"

generate_report
