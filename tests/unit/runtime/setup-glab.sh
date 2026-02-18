#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/setup-glab
# Tests GitLab CLI authentication, GITLAB_HOST handling, and xtrace safety

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup-Glab Command Tests"

# Path to the script under test
SETUP_GLAB_SCRIPT="$PROJECT_ROOT/lib/runtime/commands/setup-glab"

# Setup function - runs before each test (overrides framework setup)
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-setup-glab-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    export TEST_HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$TEST_HOME"
}

# Teardown function - runs after each test (overrides framework teardown)
teardown() {
    command rm -rf "${TEST_TEMP_DIR:-}" 2>/dev/null || true
    unset TEST_TEMP_DIR TEST_HOME 2>/dev/null || true
    unset GITLAB_TOKEN GITLAB_HOST 2>/dev/null || true
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
    assert_file_contains "$SETUP_GLAB_SCRIPT" "set -euo pipefail" \
        "setup-glab should use strict mode"
}

# Test: No unconditional { set -x; } pattern
test_no_unconditional_set_x() {
    assert_file_not_contains "$SETUP_GLAB_SCRIPT" '{ set -x; }' \
        "setup-glab should not contain unconditional { set -x; }"
}

# Test: Auth block saves xtrace state
test_auth_block_saves_xtrace() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'set +o | grep xtrace' \
        "Auth block should save xtrace state"
}

# Test: Auth block disables xtrace
test_auth_block_disables_xtrace() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '{ set +x; } 2>/dev/null' \
        "Auth block should disable xtrace safely"
}

# Test: Auth block restores xtrace
test_auth_block_restores_xtrace() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'eval "$_xt"' \
        "Auth block should restore xtrace state"
}

# Test: Helper functions are defined
test_helper_functions_defined() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_info()' \
        "_info helper should be defined"
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_ok()' \
        "_ok helper should be defined"
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_skip()' \
        "_skip helper should be defined"
}

# ---------------------------------------------------------------------------
# Functional tests: Skip when glab not installed
# ---------------------------------------------------------------------------

# Test: Skips when glab is not installed
test_skip_when_glab_missing() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'command -v glab' \
        "Should check if glab CLI is installed"
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab CLI not installed' \
        "Should print skip message when glab not installed"
}

# Test: Checks glab auth status before authenticating
test_checks_auth_status() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab auth status' \
        "Should check glab auth status before authenticating"
}

# Test: Skips when already authenticated
test_skip_when_already_authenticated() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab already authenticated' \
        "Should skip when already authenticated"
}

# ---------------------------------------------------------------------------
# Functional tests: GITLAB_HOST handling
# ---------------------------------------------------------------------------

# Test: GITLAB_HOST defaults to gitlab.com
test_gitlab_host_default() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '${GITLAB_HOST:-gitlab.com}' \
        "GITLAB_HOST should default to gitlab.com"
}

# Test: GITLAB_HOST used in auth status check
test_gitlab_host_in_auth_status() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab auth status --hostname "$host"' \
        "glab auth status should use --hostname with host variable"
}

# Test: GITLAB_HOST used in auth login
test_gitlab_host_in_auth_login() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab auth login --hostname "$host"' \
        "glab auth login should use --hostname with host variable"
}

# Test: GITLAB_HOST used in config get token
test_gitlab_host_in_config_get() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab config get token --host "$host"' \
        "glab config get should use --host with host variable"
}

# ---------------------------------------------------------------------------
# Functional tests: Token handling
# ---------------------------------------------------------------------------

# Test: Token sanitization strips whitespace
test_token_sanitization() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" "tr -d '\\[:space\\:]'" \
        "Should strip whitespace from token"
}

# Test: Token piped via stdin
test_token_piped_via_stdin() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'printf.*token.*|.*glab auth login' \
        "Token should be piped via stdin to glab auth login"
}

# Test: Uses --stdin flag for glab auth login
test_auth_uses_stdin_flag() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab auth login --hostname "$host" --stdin' \
        "glab auth login should use --stdin flag"
}

# Test: Handles missing GITLAB_TOKEN gracefully
test_missing_token_graceful() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'GITLAB_TOKEN not set' \
        "Should print info when GITLAB_TOKEN not set"
}

# ---------------------------------------------------------------------------
# Functional tests: _persist_token
# ---------------------------------------------------------------------------

# Test: _persist_token function is defined
test_persist_token_defined() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_persist_token()' \
        "_persist_token function should be defined"
}

# Test: _persist_token uses marker to avoid duplicates
test_persist_token_marker() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '# setup-glab: GITLAB_TOKEN' \
        "_persist_token should use a marker comment"
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'grep -qF "$marker"' \
        "_persist_token should check for existing marker"
}

# Test: _persist_token writes to bashrc
test_persist_token_writes_bashrc() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GLAB_SCRIPT" > "$func_script"

    (
        set -euo pipefail
        export HOME="$TEST_HOME"
        touch "$HOME/.bashrc"
        source "$func_script"
        _persist_token
    )

    assert_file_contains "$TEST_HOME/.bashrc" "# setup-glab: GITLAB_TOKEN" \
        "bashrc should contain the marker"
    assert_file_contains "$TEST_HOME/.bashrc" "glab config get token" \
        "bashrc should contain glab config get token command"
}

# Test: _persist_token is idempotent (no duplicates)
test_persist_token_idempotent() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GLAB_SCRIPT" > "$func_script"

    (
        set -euo pipefail
        export HOME="$TEST_HOME"
        touch "$HOME/.bashrc"
        source "$func_script"
        _persist_token
        _persist_token
    )

    local marker_count
    marker_count=$(grep -c "# setup-glab: GITLAB_TOKEN" "$TEST_HOME/.bashrc" || echo "0")
    assert_equals "1" "$marker_count" "Marker should appear exactly once after two calls"
}

# Test: _persist_token bashrc block references GITLAB_HOST
test_persist_token_uses_gitlab_host() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GLAB_SCRIPT" > "$func_script"

    (
        set -euo pipefail
        export HOME="$TEST_HOME"
        touch "$HOME/.bashrc"
        source "$func_script"
        _persist_token
    )

    assert_file_contains "$TEST_HOME/.bashrc" 'GITLAB_HOST:-gitlab.com' \
        "bashrc block should reference GITLAB_HOST with default"
}

# ---------------------------------------------------------------------------
# Functional tests: Xtrace safety in auth block
# ---------------------------------------------------------------------------

# Test: Auth block does not leak token in xtrace
test_auth_no_token_leak() {
    local script_content
    script_content=$(cat "$SETUP_GLAB_SCRIPT")

    # Check the pattern exists: _xt save, set +x, glab auth login, eval restore
    assert_contains "$script_content" '_xt=$(set +o | grep xtrace)' \
        "Should save xtrace state before auth"
    assert_contains "$script_content" '{ set +x; } 2>/dev/null' \
        "Should disable xtrace before auth"

    # Verify the order: save comes before disable, which comes before auth
    local save_line disable_line auth_line restore_line
    save_line=$(grep -n '_xt=$(set +o | grep xtrace)' "$SETUP_GLAB_SCRIPT" | head -1 | cut -d: -f1)
    disable_line=$(grep -n '{ set +x; } 2>/dev/null' "$SETUP_GLAB_SCRIPT" | head -1 | cut -d: -f1)
    auth_line=$(grep -n 'glab auth login' "$SETUP_GLAB_SCRIPT" | head -1 | cut -d: -f1)
    restore_line=$(grep -n 'eval "$_xt"' "$SETUP_GLAB_SCRIPT" | head -1 | cut -d: -f1)

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
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab auth status' \
        "Should verify authentication after login"
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'glab authenticated' \
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
run_test_with_setup test_skip_when_glab_missing "Skips when glab CLI not installed"
run_test_with_setup test_checks_auth_status "Checks glab auth status before authenticating"
run_test_with_setup test_skip_when_already_authenticated "Skips when already authenticated"
run_test_with_setup test_gitlab_host_default "GITLAB_HOST defaults to gitlab.com"
run_test_with_setup test_gitlab_host_in_auth_status "GITLAB_HOST used in auth status check"
run_test_with_setup test_gitlab_host_in_auth_login "GITLAB_HOST used in auth login"
run_test_with_setup test_gitlab_host_in_config_get "GITLAB_HOST used in config get token"
run_test_with_setup test_token_sanitization "Token sanitization strips whitespace"
run_test_with_setup test_token_piped_via_stdin "Token piped via stdin to glab auth login"
run_test_with_setup test_auth_uses_stdin_flag "Auth login uses --stdin flag"
run_test_with_setup test_missing_token_graceful "Handles missing GITLAB_TOKEN gracefully"
run_test_with_setup test_persist_token_defined "_persist_token function is defined"
run_test_with_setup test_persist_token_marker "_persist_token uses marker to avoid duplicates"
run_test_with_setup test_persist_token_writes_bashrc "_persist_token writes to bashrc"
run_test_with_setup test_persist_token_idempotent "_persist_token is idempotent"
run_test_with_setup test_persist_token_uses_gitlab_host "_persist_token bashrc references GITLAB_HOST"
run_test_with_setup test_auth_no_token_leak "Auth block does not leak token in xtrace"
run_test_with_setup test_verification_after_auth "Verification step after authentication"

# Generate test report
generate_report
