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
    export TEST_TEMP_DIR="$RESULTS_DIR/test-setup-gh-$unique_id"
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
    assert_file_contains "$SETUP_GH_SCRIPT" 'set +o | grep xtrace' \
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
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GH_SCRIPT" > "$func_script"

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
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GH_SCRIPT" > "$func_script"

    (
        set -euo pipefail
        export HOME="$TEST_HOME"
        touch "$HOME/.bashrc"
        source "$func_script"
        _persist_token
        _persist_token
    )

    local marker_count
    marker_count=$(grep -c "# setup-gh: GITHUB_TOKEN" "$TEST_HOME/.bashrc" || echo "0")
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
    script_content=$(cat "$SETUP_GH_SCRIPT")

    # Check the pattern exists: _xt save, set +x, gh auth login, eval restore
    assert_contains "$script_content" '_xt=$(set +o | grep xtrace)' \
        "Should save xtrace state before auth"
    assert_contains "$script_content" '{ set +x; } 2>/dev/null' \
        "Should disable xtrace before auth"

    # Verify the order: save comes before disable, which comes before auth
    local save_line disable_line auth_line restore_line
    save_line=$(grep -n '_xt=$(set +o | grep xtrace)' "$SETUP_GH_SCRIPT" | head -1 | cut -d: -f1)
    disable_line=$(grep -n '{ set +x; } 2>/dev/null' "$SETUP_GH_SCRIPT" | head -1 | cut -d: -f1)
    auth_line=$(grep -n 'gh auth login --with-token' "$SETUP_GH_SCRIPT" | head -1 | cut -d: -f1)
    restore_line=$(grep -n 'eval "$_xt"' "$SETUP_GH_SCRIPT" | head -1 | cut -d: -f1)

    # Verify correct ordering
    assert_true [ "$save_line" -lt "$disable_line" ] \
        "Xtrace save should come before disable"
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
run_test_with_setup test_auth_no_token_leak "Auth block does not leak token in xtrace"
run_test_with_setup test_verification_after_auth "Verification step after authentication"

# Generate test report
generate_report
