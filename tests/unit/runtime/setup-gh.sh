#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/setup-gh
# Tests GitHub CLI authentication and xtrace safety

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup-GH Command Tests"

# Path to the script under test
SETUP_GH_SCRIPT="$PROJECT_ROOT/lib/runtime/commands/setup-gh"

# Setup function - runs before each test (overrides framework setup)
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-setup-gh-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    export TEST_HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$TEST_HOME"
}

# Teardown function - runs after each test (overrides framework teardown)
teardown() {
    command rm -rf "${TEST_TEMP_DIR:-}" 2>/dev/null || true
    unset TEST_TEMP_DIR TEST_HOME 2>/dev/null || true
    unset GITHUB_TOKEN 2>/dev/null || true
}

# Wrapper for running tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ---------------------------------------------------------------------------
# Static analysis tests
# ---------------------------------------------------------------------------

# Test: Script uses set -euo pipefail
test_strict_mode() {
    assert_file_contains "$SETUP_GH_SCRIPT" "set -euo pipefail" \
        "setup-gh should use strict mode"
}

# Test: No unconditional { set -x; } pattern
test_no_unconditional_set_x() {
    assert_file_not_contains "$SETUP_GH_SCRIPT" '{ set -x; }' \
        "setup-gh should not contain unconditional { set -x; }"
}

# Test: Auth block saves xtrace state
test_auth_block_saves_xtrace() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'set +o | command grep xtrace' \
        "Auth block should save xtrace state"
}

# Test: Auth block disables xtrace
test_auth_block_disables_xtrace() {
    assert_file_contains "$SETUP_GH_SCRIPT" '{ set +x; } 2>/dev/null' \
        "Auth block should disable xtrace safely"
}

# Test: Auth block restores xtrace
test_auth_block_restores_xtrace() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'eval "$_xt"' \
        "Auth block should restore xtrace state"
}

# Test: Helper functions are defined
test_helper_functions_defined() {
    assert_file_contains "$SETUP_GH_SCRIPT" '_info()' \
        "_info helper should be defined"
    assert_file_contains "$SETUP_GH_SCRIPT" '_ok()' \
        "_ok helper should be defined"
    assert_file_contains "$SETUP_GH_SCRIPT" '_skip()' \
        "_skip helper should be defined"
}

# ---------------------------------------------------------------------------
# Functional tests: Skip when gh not installed
# ---------------------------------------------------------------------------

# Test: Skips when gh is not installed
test_skip_when_gh_missing() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'command -v gh' \
        "Should check if gh CLI is installed"
    assert_file_contains "$SETUP_GH_SCRIPT" 'gh CLI not installed' \
        "Should print skip message when gh not installed"
}

# Test: Checks gh auth status before authenticating
test_checks_auth_status() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'gh auth status' \
        "Should check gh auth status before authenticating"
}

# Test: Skips when already authenticated
test_skip_when_already_authenticated() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'gh already authenticated' \
        "Should skip when already authenticated"
}

# ---------------------------------------------------------------------------
# Functional tests: Token handling
# ---------------------------------------------------------------------------

# Test: Token sanitization strips whitespace
test_token_sanitization() {
    assert_file_contains "$SETUP_GH_SCRIPT" "tr -d '\\[:space:\\]'" \
        "Should strip whitespace from token"
}

# Test: Token piped via stdin (not in process args)
test_token_piped_via_stdin() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'printf.*token.*|.*gh auth login --with-token' \
        "Token should be piped via stdin to gh auth login"
}

# Test: Handles missing GITHUB_TOKEN gracefully
test_missing_token_graceful() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'GITHUB_TOKEN not set' \
        "Should print info when GITHUB_TOKEN not set"
}

# ---------------------------------------------------------------------------
# Functional tests: _persist_token
# ---------------------------------------------------------------------------

# Test: _persist_token function is defined
test_persist_token_defined() {
    assert_file_contains "$SETUP_GH_SCRIPT" '_persist_token()' \
        "_persist_token function should be defined"
}

# Test: _persist_token uses marker to avoid duplicates
test_persist_token_marker() {
    assert_file_contains "$SETUP_GH_SCRIPT" '# setup-gh: GITHUB_TOKEN' \
        "_persist_token should use a marker comment"
    assert_file_contains "$SETUP_GH_SCRIPT" 'grep -qF "$marker"' \
        "_persist_token should check for existing marker"
}

# Test: _persist_token writes to bashrc
test_persist_token_writes_bashrc() {
    # Source just the _persist_token function and test it
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GH_SCRIPT" >"$func_script"

    (
        set -euo pipefail
        export HOME="$TEST_HOME"
        touch "$HOME/.bashrc"
        source "$func_script"
        _persist_token
    )

    assert_file_contains "$TEST_HOME/.bashrc" "# setup-gh: GITHUB_TOKEN" \
        "bashrc should contain the marker"
    assert_file_contains "$TEST_HOME/.bashrc" "gh auth token" \
        "bashrc should contain gh auth token command"
}

# Test: _persist_token is idempotent (no duplicates)
test_persist_token_idempotent() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GH_SCRIPT" >"$func_script"

    (
        set -euo pipefail
        export HOME="$TEST_HOME"
        touch "$HOME/.bashrc"
        source "$func_script"
        _persist_token
        _persist_token
    )

    local marker_count
    marker_count=$(command grep -c "# setup-gh: GITHUB_TOKEN" "$TEST_HOME/.bashrc" || echo "0")
    assert_equals "1" "$marker_count" "Marker should appear exactly once after two calls"
}

# ---------------------------------------------------------------------------
# Functional tests: Xtrace safety in auth block
# ---------------------------------------------------------------------------

# Test: Auth block does not leak token in xtrace
test_auth_no_token_leak() {
    # Verify the pattern: save xtrace, disable, do auth, restore
    # This is a static check of the code sequence
    local script_content
    script_content=$(command cat "$SETUP_GH_SCRIPT")

    # Check the pattern exists: _xt save, set +x, gh auth login, eval restore
    assert_contains "$script_content" '_xt=$(set +o | command grep xtrace)' \
        "Should save xtrace state before auth"
    assert_contains "$script_content" '{ set +x; } 2>/dev/null' \
        "Should disable xtrace before auth"

    # Verify the order: save comes before disable, which comes before auth
    local save_line disable_line auth_line restore_line
    # Use main() as anchor to skip the OP cache block which also has xtrace patterns
    local main_line
    main_line=$(command grep -n '^main()' "$SETUP_GH_SCRIPT" | command head -1 | command cut -d: -f1)
    save_line=$(command sed -n "${main_line},\$p" "$SETUP_GH_SCRIPT" | command grep -n '_xt=$(set +o | command grep xtrace)' | command head -1 | command cut -d: -f1)
    save_line=$((main_line + save_line - 1))
    disable_line=$(command sed -n "${main_line},\$p" "$SETUP_GH_SCRIPT" | command grep -n '{ set +x; } 2>/dev/null' | command head -1 | command cut -d: -f1)
    disable_line=$((main_line + disable_line - 1))
    auth_line=$(command grep -n 'gh auth login --with-token' "$SETUP_GH_SCRIPT" | command head -1 | command cut -d: -f1)
    # Early returns restore xtrace too, so take the first restore after login
    restore_line=$(command sed -n "${auth_line},\$p" "$SETUP_GH_SCRIPT" | command grep -n 'eval "$_xt"' | command head -1 | command cut -d: -f1)
    restore_line=$((auth_line + restore_line - 1))
    # The region must open before main() first expands the token (#1468)
    local deref_line
    deref_line=$(command sed -n "${main_line},\$p" "$SETUP_GH_SCRIPT" | command grep -n '\$GITHUB_TOKEN\|\${GITHUB_TOKEN' | command head -1 | command cut -d: -f1)
    deref_line=$((main_line + deref_line - 1))

    # Verify correct ordering
    assert_true [ "$save_line" -lt "$disable_line" ] \
        "Xtrace save should come before disable"
    assert_true [ "$disable_line" -lt "$deref_line" ] \
        "Xtrace disable should come before the first GITHUB_TOKEN expansion in main()"
    assert_true [ "$disable_line" -lt "$auth_line" ] \
        "Xtrace disable should come before auth login"
    assert_true [ "$auth_line" -lt "$restore_line" ] \
        "Auth login should come before xtrace restore"
}

# Test: Verification step after authentication
test_verification_after_auth() {
    assert_file_contains "$SETUP_GH_SCRIPT" 'gh auth status' \
        "Should verify authentication after login"
    assert_file_contains "$SETUP_GH_SCRIPT" 'gh authenticated' \
        "Should report successful authentication"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_no_unconditional_set_x "No unconditional { set -x; } pattern"
run_test_with_setup test_auth_block_saves_xtrace "Auth block saves xtrace state"
run_test_with_setup test_auth_block_disables_xtrace "Auth block disables xtrace safely"
run_test_with_setup test_auth_block_restores_xtrace "Auth block restores xtrace state"
run_test_with_setup test_helper_functions_defined "Helper functions are defined"
run_test_with_setup test_skip_when_gh_missing "Skips when gh CLI not installed"
run_test_with_setup test_checks_auth_status "Checks gh auth status before authenticating"
run_test_with_setup test_skip_when_already_authenticated "Skips when already authenticated"
run_test_with_setup test_token_sanitization "Token sanitization strips whitespace"
run_test_with_setup test_token_piped_via_stdin "Token piped via stdin not in process args"
run_test_with_setup test_missing_token_graceful "Handles missing GITHUB_TOKEN gracefully"
run_test_with_setup test_persist_token_defined "_persist_token function is defined"
run_test_with_setup test_persist_token_marker "_persist_token uses marker to avoid duplicates"
run_test_with_setup test_persist_token_writes_bashrc "_persist_token writes to bashrc"
run_test_with_setup test_persist_token_idempotent "_persist_token is idempotent"

# ---------------------------------------------------------------------------
# OP secrets cache sourcing (via _wait-for-op-cache helper)
# ---------------------------------------------------------------------------

# Test: Script sources _wait-for-op-cache helper
test_sources_wait_for_op_cache() {
    assert_file_contains "$SETUP_GH_SCRIPT" '_wait-for-op-cache' \
        "setup-gh should source _wait-for-op-cache helper"
}

# Test: Script does NOT contain inline OP cache block (regression guard)
test_no_inline_op_cache() {
    assert_file_not_contains "$SETUP_GH_SCRIPT" '/dev/shm/op-secrets-cache' \
        "setup-gh should NOT contain inline /dev/shm/op-secrets-cache reference"
}

# ---------------------------------------------------------------------------
# Input validation tests
# ---------------------------------------------------------------------------

# Test: _warn helper is defined
test_warn_defined() {
    assert_file_contains "$SETUP_GH_SCRIPT" '_warn()' \
        "_warn helper should be defined"
}

# Test: _validate_token function is defined
test_validate_token_defined() {
    assert_file_contains "$SETUP_GH_SCRIPT" '_validate_token()' \
        "_validate_token function should be defined"
}

# Test: _validate_token accepts valid token
test_validate_token_accepts_valid() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GH_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_token "ghp_abcdef123456" "GITHUB_TOKEN"
    ) 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "_validate_token should accept a valid token"
}

# Test: _validate_token rejects short token
test_validate_token_rejects_short() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GH_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_token "ab" "GITHUB_TOKEN"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_token should reject token shorter than 4 chars"
}

# Test: _validate_token rejects token with control characters
test_validate_token_rejects_control_chars() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GH_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_token $'ghp_\nmalicious' "GITHUB_TOKEN"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_token should reject token with newlines"
}

# Test: main calls _validate_token before auth
test_main_validates_token() {
    assert_file_contains "$SETUP_GH_SCRIPT" '_validate_token "$token" "GITHUB_TOKEN"' \
        "main should validate token before authenticating"
}

# ---------------------------------------------------------------------------
# Behavioral tests: login runs with GITHUB_TOKEN/GH_TOKEN cleared (#1457)
# ---------------------------------------------------------------------------

# Install a stub gh in $TEST_TEMP_DIR/bin. Every invocation appends one line to
# $TEST_TEMP_DIR/gh.calls: argv plus whether GITHUB_TOKEN/GH_TOKEN were set in
# its env. Like real gh, `auth login` is refused while either token is set.
# `auth status` fails until a login succeeds. $1=fail makes every login fail.
# `auth token` prints a stored token distinct from the env one.
_install_stub_gh() {
    local mode="${1:-ok}"
    mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/gh" <<STUB
#!/bin/bash
state="$TEST_TEMP_DIR"
STUB
    command cat >>"$TEST_TEMP_DIR/bin/gh" <<'STUB'
printf '%s GITHUB_TOKEN=%s GH_TOKEN=%s\n' "$*" \
    "${GITHUB_TOKEN:+set}" "${GH_TOKEN:+set}" >>"$state/gh.calls"
case "$*" in
    *"auth status"*) [ -f "$state/gh.loggedin" ] ;;
    *"auth token"*) echo "gho_fake_stored_token_5555555555" ;;
    *"auth login"*)
        command cat >"$state/gh.stdin"
        if [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ]; then
            echo "The value of the GITHUB_TOKEN environment variable is being used for authentication." >&2
            exit 1
        fi
STUB
    if [ "$mode" = "fail" ]; then
        printf '        echo "error validating token" >&2\n        exit 1 ;;\n' >>"$TEST_TEMP_DIR/bin/gh"
    else
        printf '        touch "$state/gh.loggedin"\n        exit 0 ;;\n' >>"$TEST_TEMP_DIR/bin/gh"
    fi
    command cat >>"$TEST_TEMP_DIR/bin/gh" <<'STUB'
    *) exit 0 ;;
esac
STUB
    chmod +x "$TEST_TEMP_DIR/bin/gh"
}

# Run setup-gh against the stub. BASH_ENV is unset (it rebuilds PATH on
# non-interactive bash and would bypass the stub); the loaded flags keep the
# host's .env.secrets / OP cache out of the run. GH_TOKEN is set too, so the
# stub refuses the login unless setup-gh clears BOTH variables.
_run_setup_gh() {
    command env -u BASH_ENV \
        HOME="$TEST_HOME" PATH="$TEST_TEMP_DIR/bin:$PATH" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        GITHUB_TOKEN="ghp_fake_token_for_testing_1234567890" \
        GH_TOKEN="ghp_fake_gh_token_for_testing_0987654321" \
        bash "$SETUP_GH_SCRIPT" 2>&1
}

# Guard every behavioral test: the stub must have been the gh that ran, and the
# login must have reached it with no token in its env. A stub bypassed via PATH,
# or a fall-through to the real gh, leaves the log empty and fails here.
_assert_stub_login_without_env_token() {
    local calls=""
    [ -f "$TEST_TEMP_DIR/gh.calls" ] && calls=$(command cat "$TEST_TEMP_DIR/gh.calls")
    assert_not_empty "$calls" "Stub gh call log must be non-empty (stub was invoked)"
    # Whole-line match: a substring would also accept "GH_TOKEN=set".
    local login_line
    login_line=$(printf '%s\n' "$calls" | command grep -F 'auth login' || true)
    assert_equals "auth login --with-token GITHUB_TOKEN= GH_TOKEN=" "$login_line" \
        "gh auth login --with-token must run once, with GITHUB_TOKEN and GH_TOKEN cleared"
}

test_login_clears_env_token() {
    _install_stub_gh ok

    local output rc=0
    output=$(_run_setup_gh) || rc=$?

    _assert_stub_login_without_env_token
    assert_equals "0" "$rc" "setup-gh should succeed when login runs without env token"
    assert_contains "$output" "gh authenticated" "Post-login verify should pass"
    assert_not_contains "$output" "environment variable is being used" "gh must not refuse login"
    assert_equals "ghp_fake_token_for_testing_1234567890" "$(command cat "$TEST_TEMP_DIR/gh.stdin")" \
        "Token should be piped to gh on stdin"
    assert_file_contains "$TEST_HOME/.bashrc" "# setup-gh: GITHUB_TOKEN" \
        "_persist_token should run on the login path"
}

test_login_failure_reported() {
    _install_stub_gh fail

    local output rc=0
    output=$(_run_setup_gh) || rc=$?

    _assert_stub_login_without_env_token
    assert_equals "1" "$rc" "setup-gh should return gh's exit code when gh rejects the token"
    assert_contains "$output" "gh auth login failed" "Login failure should be reported"
    assert_not_contains "$output" "gh authenticated" "Must not claim success after a failed login"
}

# Under bash -x no token may appear anywhere in the trace (#1468): not in the
# sanitize/validate steps before the login, not in the login itself. The fail
# path must also restore xtrace before it warns.
test_xtrace_no_token_leak() {
    local mode output
    for mode in ok fail; do
        command rm -rf "$TEST_TEMP_DIR/bin" "$TEST_TEMP_DIR"/gh.*
        _install_stub_gh "$mode"
        output=$(command env -u BASH_ENV \
            HOME="$TEST_HOME" PATH="$TEST_TEMP_DIR/bin:$PATH" \
            _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
            GITHUB_TOKEN="ghp_fake_token_for_testing_1234567890" \
            bash -x "$SETUP_GH_SCRIPT" 2>&1) || true
        _assert_stub_login_without_env_token
        # A trace that never got past startup would pass the leak check vacuously
        assert_contains "$output" "+ main" "[$mode] trace should be non-empty and enter main"
        assert_contains "$output" "authenticating gh CLI" "[$mode] trace should reach the login"
        assert_not_contains "$output" "ghp_fake_token_for_testing_1234567890" \
            "[$mode] token must not appear anywhere in the xtrace"
        if [ "$mode" = "fail" ]; then
            assert_contains "$output" "+ _warn 'gh auth login failed" \
                "[fail] xtrace should be restored before the failure warning"
        fi
    done
}

# Already authenticated with GITHUB_TOKEN unset: the token read back from
# `gh auth token` and exported must stay out of the trace too.
test_xtrace_no_stored_token_leak() {
    local output
    _install_stub_gh ok
    touch "$TEST_TEMP_DIR/gh.loggedin"
    output=$(command env -u BASH_ENV -u GITHUB_TOKEN -u GH_TOKEN \
        HOME="$TEST_HOME" PATH="$TEST_TEMP_DIR/bin:$PATH" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        bash -x "$SETUP_GH_SCRIPT" 2>&1) || true
    assert_file_contains "$TEST_TEMP_DIR/gh.calls" "auth token" \
        "Stub gh auth token must have been called (already-authenticated path)"
    assert_contains "$output" "gh already authenticated" "Should take the already-authenticated path"
    assert_contains "$output" "+ _persist_token" "xtrace should be restored before _persist_token"
    assert_not_contains "$output" "gho_fake_stored_token_5555555555" \
        "Stored token must not appear anywhere in the xtrace"
}

# The no-token and invalid-token returns must restore xtrace too. Without the
# restore the trace ends at the `_xt=` save; with it, the traced `_info` (no
# token) or `return 0` (invalid token) follows.
test_xtrace_restored_on_early_returns() {
    local output last
    _install_stub_gh ok
    output=$(command env -u BASH_ENV -u GITHUB_TOKEN -u GH_TOKEN \
        HOME="$TEST_HOME" PATH="$TEST_TEMP_DIR/bin:$PATH" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        bash -x "$SETUP_GH_SCRIPT" 2>&1) || true
    assert_contains "$output" "+ _info 'GITHUB_TOKEN not set" \
        "[no-token] xtrace should be restored before the help message"

    # Sanitizes to "zq9" (too short), so _validate_token rejects it
    output=$(command env -u BASH_ENV -u GH_TOKEN \
        HOME="$TEST_HOME" PATH="$TEST_TEMP_DIR/bin:$PATH" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        GITHUB_TOKEN="zq9 " \
        bash -x "$SETUP_GH_SCRIPT" 2>&1) || true
    assert_contains "$output" "GITHUB_TOKEN is too short" "[invalid] should take the validate-fail path"
    assert_not_contains "$output" "zq9" "[invalid] token must not appear anywhere in the xtrace"
    last=$(printf '%s\n' "$output" | command tail -n 1)
    assert_equals "+ return 0" "$last" "[invalid] xtrace should be restored before the return"
}

run_test_with_setup test_login_clears_env_token "Login runs with env tokens cleared and persists"
run_test_with_setup test_login_failure_reported "Failed login is reported with non-zero exit"
run_test_with_setup test_xtrace_no_token_leak "Whole xtrace is token-free on login, restored on failure"
run_test_with_setup test_xtrace_no_stored_token_leak "Already-authenticated path keeps stored token out of xtrace"
run_test_with_setup test_xtrace_restored_on_early_returns "No-token and invalid-token returns restore xtrace"

run_test_with_setup test_warn_defined "_warn helper is defined"
run_test_with_setup test_validate_token_defined "_validate_token function is defined"
run_test_with_setup test_validate_token_accepts_valid "_validate_token accepts valid token"
run_test_with_setup test_validate_token_rejects_short "_validate_token rejects short token"
run_test_with_setup test_validate_token_rejects_control_chars "_validate_token rejects control characters"
run_test_with_setup test_main_validates_token "main validates token before auth"

run_test_with_setup test_sources_wait_for_op_cache "Script sources _wait-for-op-cache helper"
run_test_with_setup test_no_inline_op_cache "No inline OP cache block (regression guard)"
run_test_with_setup test_auth_no_token_leak "Auth block does not leak token in xtrace"
run_test_with_setup test_verification_after_auth "Verification step after authentication"

# Generate test report
generate_report
