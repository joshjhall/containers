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
    assert_file_contains "$SETUP_GLAB_SCRIPT" 'set +o | command grep xtrace' \
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
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GLAB_SCRIPT" >"$func_script"

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
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GLAB_SCRIPT" >"$func_script"

    (
        set -euo pipefail
        export HOME="$TEST_HOME"
        touch "$HOME/.bashrc"
        source "$func_script"
        _persist_token
        _persist_token
    )

    local marker_count
    marker_count=$(command grep -c "# setup-glab: GITLAB_TOKEN" "$TEST_HOME/.bashrc" || echo "0")
    assert_equals "1" "$marker_count" "Marker should appear exactly once after two calls"
}

# Test: _persist_token bashrc block references GITLAB_HOST
test_persist_token_uses_gitlab_host() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_persist_token()/,/^}/p' "$SETUP_GLAB_SCRIPT" >"$func_script"

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
    script_content=$(command cat "$SETUP_GLAB_SCRIPT")

    # Check the pattern exists: _xt save, set +x, glab auth login, eval restore
    assert_contains "$script_content" '_xt=$(set +o | command grep xtrace)' \
        "Should save xtrace state before auth"
    assert_contains "$script_content" '{ set +x; } 2>/dev/null' \
        "Should disable xtrace before auth"

    # Verify the order: save comes before disable, which comes before auth
    local save_line disable_line auth_line restore_line
    # Use main() as anchor to skip the OP cache block which also has xtrace patterns
    local main_line
    main_line=$(command grep -n '^main()' "$SETUP_GLAB_SCRIPT" | command head -1 | command cut -d: -f1)
    save_line=$(command sed -n "${main_line},\$p" "$SETUP_GLAB_SCRIPT" | command grep -n '_xt=$(set +o | command grep xtrace)' | command head -1 | command cut -d: -f1)
    save_line=$((main_line + save_line - 1))
    disable_line=$(command sed -n "${main_line},\$p" "$SETUP_GLAB_SCRIPT" | command grep -n '{ set +x; } 2>/dev/null' | command head -1 | command cut -d: -f1)
    disable_line=$((main_line + disable_line - 1))
    auth_line=$(command grep -n 'glab auth login' "$SETUP_GLAB_SCRIPT" | command head -1 | command cut -d: -f1)
    restore_line=$(command sed -n "${main_line},\$p" "$SETUP_GLAB_SCRIPT" | command grep -n 'eval "$_xt"' | command head -1 | command cut -d: -f1)
    restore_line=$((main_line + restore_line - 1))

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

# ---------------------------------------------------------------------------
# OP secrets cache sourcing (via _wait-for-op-cache helper)
# ---------------------------------------------------------------------------

# Test: Script sources _wait-for-op-cache helper
test_sources_wait_for_op_cache() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_wait-for-op-cache' \
        "setup-glab should source _wait-for-op-cache helper"
}

# Test: Script does NOT contain inline OP cache block (regression guard)
test_no_inline_op_cache() {
    assert_file_not_contains "$SETUP_GLAB_SCRIPT" '/dev/shm/op-secrets-cache' \
        "setup-glab should NOT contain inline /dev/shm/op-secrets-cache reference"
}

# ---------------------------------------------------------------------------
# Input validation tests
# ---------------------------------------------------------------------------

# Test: _warn helper is defined
test_warn_defined() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_warn()' \
        "_warn helper should be defined"
}

# Test: _validate_token function is defined
test_validate_token_defined() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_validate_token()' \
        "_validate_token function should be defined"
}

# Test: _validate_hostname function is defined
test_validate_hostname_defined() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_validate_hostname()' \
        "_validate_hostname function should be defined"
}

# Test: _validate_token accepts valid token
test_validate_token_accepts_valid() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GLAB_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_token "glpat-abcdef123456" "GITLAB_TOKEN"
    ) 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "_validate_token should accept a valid token"
}

# Test: _validate_token rejects short token
test_validate_token_rejects_short() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GLAB_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_token "ab" "GITLAB_TOKEN"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_token should reject token shorter than 4 chars"
}

# Test: _validate_token rejects token with control characters
test_validate_token_rejects_control_chars() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GLAB_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_token $'glpat-\nmalicious' "GITLAB_TOKEN"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_token should reject token with newlines"
}

# Test: _validate_hostname accepts valid hostname
test_validate_hostname_accepts_valid() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GLAB_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_hostname "gitlab.example.com" "GITLAB_HOST"
    ) 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "_validate_hostname should accept gitlab.example.com"
}

# Test: _validate_hostname rejects hostname with slashes
test_validate_hostname_rejects_slashes() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GLAB_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_hostname "https://gitlab.com/path" "GITLAB_HOST"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_hostname should reject hostname with slashes"
}

# Test: _validate_hostname rejects hostname with spaces
test_validate_hostname_rejects_spaces() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GLAB_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_hostname "gitlab .com" "GITLAB_HOST"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_hostname should reject hostname with spaces"
}

# Test: main calls _validate_token before auth
test_main_validates_token() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_validate_token "$token" "GITLAB_TOKEN"' \
        "main should validate token before authenticating"
}

# Test: main calls _validate_hostname
test_main_validates_hostname() {
    assert_file_contains "$SETUP_GLAB_SCRIPT" '_validate_hostname "$host" "GITLAB_HOST"' \
        "main should validate hostname"
}

run_test_with_setup test_warn_defined "_warn helper is defined"
run_test_with_setup test_validate_token_defined "_validate_token function is defined"
run_test_with_setup test_validate_hostname_defined "_validate_hostname function is defined"
run_test_with_setup test_validate_token_accepts_valid "_validate_token accepts valid token"
run_test_with_setup test_validate_token_rejects_short "_validate_token rejects short token"
run_test_with_setup test_validate_token_rejects_control_chars "_validate_token rejects control characters"
run_test_with_setup test_validate_hostname_accepts_valid "_validate_hostname accepts valid hostname"
run_test_with_setup test_validate_hostname_rejects_slashes "_validate_hostname rejects hostname with slashes"
run_test_with_setup test_validate_hostname_rejects_spaces "_validate_hostname rejects hostname with spaces"
run_test_with_setup test_main_validates_token "main validates token before auth"
run_test_with_setup test_main_validates_hostname "main validates hostname"

run_test_with_setup test_sources_wait_for_op_cache "Script sources _wait-for-op-cache helper"
run_test_with_setup test_no_inline_op_cache "No inline OP cache block (regression guard)"
run_test_with_setup test_auth_no_token_leak "Auth block does not leak token in xtrace"
run_test_with_setup test_verification_after_auth "Verification step after authentication"

# Generate test report
generate_report
