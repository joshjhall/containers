#!/usr/bin/env bash
# Unit tests for bin/check-author-identity.sh
# The pre-commit hook that refuses placeholder author/committer emails
# (31 commits on main were GitHub-attributed to a stranger via t@t.t).

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Check Author Identity Tests"

SCRIPT="$PROJECT_ROOT/bin/check-author-identity.sh"

# Each test gets a scratch repo and an empty HOME so the developer's real
# global identity (and any ambient GIT_* env) can't decide the outcome.
setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(mktemp -d -t "author-identity-test-XXXXXX")
    export TEST_REPO="$TEST_TEMP_DIR/repo"
    command mkdir -p "$TEST_REPO" "$TEST_TEMP_DIR/home"
    git -C "$TEST_REPO" init -q
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR TEST_REPO
}

# Run the hook in the scratch repo under a hermetic env. Extra args are
# VAR=value pairs added to that env. Sets HOOK_OUT and HOOK_RC.
run_hook() {
    HOOK_RC=0
    HOOK_OUT=$(cd "$TEST_REPO" && env -i \
        PATH="$PATH" HOME="$TEST_TEMP_DIR/home" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TEST_TEMP_DIR/home/.gitconfig" \
        "$@" bash "$SCRIPT" 2>&1) || HOOK_RC=$?
}

set_local_identity() {
    git -C "$TEST_REPO" config user.name "$1"
    git -C "$TEST_REPO" config user.email "$2"
}

expect_reject() {
    local email="$1"
    set_local_identity "T" "$email"
    run_hook
    if [ "$HOOK_RC" -ne 1 ]; then
        fail_test "<$email> should be rejected (rc=$HOOK_RC): $HOOK_OUT"
        return 0
    fi
    # Discriminate: the refusal must name the email and come from the
    # placeholder check, not from some other failure path.
    if [[ "$HOOK_OUT" != *"author email <$email> is a placeholder"* ]]; then
        fail_test "<$email> rejected for the wrong reason: $HOOK_OUT"
    fi
}

expect_accept() {
    local email="$1"
    set_local_identity "Real Person" "$email"
    run_hook
    if [ "$HOOK_RC" -ne 0 ]; then
        fail_test "<$email> should be accepted (rc=$HOOK_RC): $HOOK_OUT"
    fi
}

test_script_executable() {
    assert_file_executable "$SCRIPT"
}

test_rejects_the_incident_email() {
    expect_reject "t@t.t"
}

test_rejects_reserved_domains() {
    local e
    for e in "t@example.com" "dev@mail.example.org" "a@example.net" \
        "x@foo.test" "x@foo.invalid" "devcontainer@localhost" \
        "x@box.localhost" "x@box.local" "test@test.com" "T@EXAMPLE.COM"; do
        expect_reject "$e"
        if [ "$TEST_STATUS" = "failed" ]; then return 0; fi
    done
}

test_rejects_malformed() {
    local e
    for e in "nobody" "@github.com" "x@host.(none)" "x@intranet"; do
        expect_reject "$e"
        if [ "$TEST_STATUS" = "failed" ]; then return 0; fi
    done
}

test_accepts_real_emails() {
    local e
    for e in "josh@yaplabs.com" "1234+user@users.noreply.github.com" \
        "first.last@sub.example-corp.co.uk" "someone@exampleco.com"; do
        expect_accept "$e"
        if [ "$TEST_STATUS" = "failed" ]; then return 0; fi
    done
}

# The incident: a repo-local identity silently shadowing a good global one.
test_local_shadows_good_global() {
    git config --file "$TEST_TEMP_DIR/home/.gitconfig" user.name "Real Person"
    git config --file "$TEST_TEMP_DIR/home/.gitconfig" user.email "real@yaplabs.com"
    set_local_identity "t" "t@t.t"
    run_hook
    assert_equals "1" "$HOOK_RC" "local t@t.t must win over a good global and be refused"
    assert_contains "$HOOK_OUT" "git config --local --unset user.email" \
        "refusal should print the local-unset remedy"
    assert_contains "$HOOK_OUT" ".git/config" "refusal should name the config file holding the email"
}

# Env overrides config, exactly as `git commit` resolves it.
test_env_committer_override_checked() {
    set_local_identity "Real Person" "real@yaplabs.com"
    run_hook GIT_COMMITTER_EMAIL="ci@example.com"
    assert_equals "1" "$HOOK_RC" "placeholder GIT_COMMITTER_EMAIL must be refused"
    assert_contains "$HOOK_OUT" "committer email <ci@example.com> is a placeholder" \
        "refusal should name the committer, not the author"
}

test_env_author_override_accepted() {
    set_local_identity "t" "t@t.t"
    run_hook GIT_AUTHOR_EMAIL="real@yaplabs.com" GIT_COMMITTER_EMAIL="real@yaplabs.com"
    assert_equals "0" "$HOOK_RC" "good env identity overrides a bad config one: $HOOK_OUT"
}

run_test test_script_executable "Script is executable"
run_test test_rejects_the_incident_email "Rejects t@t.t"
run_test test_rejects_reserved_domains "Rejects reserved/test domains"
run_test test_rejects_malformed "Rejects malformed and auto-guessed emails"
run_test test_accepts_real_emails "Accepts real emails"
run_test test_local_shadows_good_global "Catches a local identity shadowing a good global"
run_test test_env_committer_override_checked "Checks the committer identity from env"
run_test test_env_author_override_accepted "Env identity overrides config"

generate_report
