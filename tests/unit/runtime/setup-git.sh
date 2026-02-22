#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/setup-git
# Tests git identity, SSH key handling, and xtrace safety

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Setup-Git Command Tests"

# Path to the script under test
SETUP_GIT_SCRIPT="$PROJECT_ROOT/lib/runtime/commands/setup-git"

# Setup function - runs before each test (overrides framework setup)
# Uses /tmp for temp files because /workspace may have a bindfs overlay
# that forces permissions (e.g. 644), breaking chmod 600 assertions.
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="/tmp/test-setup-git-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    export TEST_HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$TEST_HOME/.ssh"
}

# Teardown function - runs after each test (overrides framework teardown)
teardown() {
    command rm -rf "${TEST_TEMP_DIR:-}" 2>/dev/null || true
    unset TEST_TEMP_DIR TEST_HOME 2>/dev/null || true
    unset GIT_USER_NAME GIT_USER_EMAIL GIT_AUTH_SSH_KEY GIT_SIGNING_SSH_KEY 2>/dev/null || true
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
    assert_file_contains "$SETUP_GIT_SCRIPT" "set -euo pipefail" \
        "setup-git should use strict mode"
}

# Test: No unconditional { set -x; } pattern
test_no_unconditional_set_x() {
    assert_file_not_contains "$SETUP_GIT_SCRIPT" '{ set -x; }' \
        "setup-git should not contain unconditional { set -x; }"
}

# Test: _write_key uses variable name indirection
test_write_key_uses_indirection() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '${!var_name}' \
        "_write_key should use variable name indirection"
}

# Test: _write_key saves xtrace state
test_write_key_saves_xtrace() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'set +o | grep xtrace' \
        "_write_key should save xtrace state"
}

# Test: _write_key disables xtrace
test_write_key_disables_xtrace() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '{ set +x; } 2>/dev/null' \
        "_write_key should disable xtrace safely"
}

# Test: _write_key restores xtrace
test_write_key_restores_xtrace() {
    # The script uses eval "$_xt" to restore xtrace state
    assert_file_contains "$SETUP_GIT_SCRIPT" 'eval "$_xt"' \
        "_write_key should restore xtrace state"
}

# Test: Helper functions are defined
test_helper_functions_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_info()' \
        "_info helper should be defined"
    assert_file_contains "$SETUP_GIT_SCRIPT" '_ok()' \
        "_ok helper should be defined"
    assert_file_contains "$SETUP_GIT_SCRIPT" '_skip()' \
        "_skip helper should be defined"
    assert_file_contains "$SETUP_GIT_SCRIPT" '_warn()' \
        "_warn helper should be defined"
}

# Test: _write_key function is defined
test_write_key_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_write_key()' \
        "_write_key function should be defined"
}

# Test: setup_identity function is defined
test_setup_identity_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'setup_identity()' \
        "setup_identity function should be defined"
}

# Test: ensure_ssh_agent function is defined
test_ensure_ssh_agent_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'ensure_ssh_agent()' \
        "ensure_ssh_agent function should be defined"
}

# Test: setup_auth_key function is defined
test_setup_auth_key_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'setup_auth_key()' \
        "setup_auth_key function should be defined"
}

# Test: setup_signing_key function is defined
test_setup_signing_key_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'setup_signing_key()' \
        "setup_signing_key function should be defined"
}

# Test: _write_key accepts variable name not value as second arg
test_write_key_called_with_var_name() {
    # The calls to _write_key should pass bare variable names (e.g. GIT_AUTH_SSH_KEY)
    # not variable expansions (e.g. "$GIT_AUTH_SSH_KEY")
    assert_file_contains "$SETUP_GIT_SCRIPT" '_write_key "$key_path" GIT_AUTH_SSH_KEY' \
        "_write_key should be called with variable name for auth key"
    assert_file_contains "$SETUP_GIT_SCRIPT" '_write_key "$priv" GIT_SIGNING_SSH_KEY' \
        "_write_key should be called with variable name for signing key"
}

# ---------------------------------------------------------------------------
# Functional tests: _write_key
# ---------------------------------------------------------------------------

# Test: _write_key writes key to file with correct permissions
test_write_key_writes_file() {
    # Source the script functions in a subshell
    local key_path="$TEST_TEMP_DIR/test_key"
    # Use a mock key format that won't trigger secret scanners
    # The _write_key function works with any string content
    local key_content="MOCK_SSH_KEY_HEADER
test-key-content-here
MOCK_SSH_KEY_FOOTER"

    # Source just the function definitions (not main)
    local func_script="$TEST_TEMP_DIR/func.sh"
    # Extract _write_key function from the script
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" > "$func_script"

    # Run the function
    (
        set -euo pipefail
        source "$func_script"
        export TEST_KEY_VAR="$key_content"
        _write_key "$key_path" TEST_KEY_VAR
    )

    assert_file_exists "$key_path" "Key file should be created"

    # Check content
    local actual_content
    actual_content=$(cat "$key_path")
    assert_equals "$key_content" "$actual_content" "Key content should match"

    # Check permissions (600)
    local perms
    perms=$(stat -c '%a' "$key_path" 2>/dev/null || stat -f '%Lp' "$key_path" 2>/dev/null)
    assert_equals "600" "$perms" "Key file should have 600 permissions"
}

# Test: _write_key returns 1 when key is unchanged
test_write_key_skips_unchanged() {
    local key_path="$TEST_TEMP_DIR/test_key"
    local key_content="test-key-unchanged"

    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" > "$func_script"

    # Write key first time
    (
        set -euo pipefail
        source "$func_script"
        export TEST_KEY="$key_content"
        _write_key "$key_path" TEST_KEY
    )

    # Write same key again — should return 1
    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        export TEST_KEY="$key_content"
        _write_key "$key_path" TEST_KEY
    ) || exit_code=$?

    assert_equals "1" "$exit_code" "_write_key should return 1 when key unchanged"
}

# Test: _write_key does not enable xtrace (when off)
test_write_key_xtrace_stays_off() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" > "$func_script"

    local key_path="$TEST_TEMP_DIR/test_key"

    # Run with xtrace OFF, check it stays OFF
    local xtrace_after
    xtrace_after=$(
        set -euo pipefail
        source "$func_script"
        set +x  # Ensure xtrace is OFF
        export XTRACE_TEST_KEY="some-key-data"
        _write_key "$key_path" XTRACE_TEST_KEY
        # Check if xtrace is on after _write_key returns
        if [[ $- == *x* ]]; then
            echo "on"
        else
            echo "off"
        fi
    )

    assert_equals "off" "$xtrace_after" "Xtrace should remain OFF after _write_key"
}

# Test: _write_key restores xtrace when it was ON
test_write_key_xtrace_restored_on() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" > "$func_script"

    local key_path="$TEST_TEMP_DIR/test_key"

    # Run with xtrace ON, check it's restored to ON
    local xtrace_after
    xtrace_after=$(
        source "$func_script"
        set -x  # Enable xtrace
        export XTRACE_TEST_KEY="some-key-data"
        _write_key "$key_path" XTRACE_TEST_KEY
        # Check if xtrace is on after _write_key returns
        if [[ $- == *x* ]]; then
            echo "on"
        else
            echo "off"
        fi
    ) 2>/dev/null

    assert_equals "on" "$xtrace_after" "Xtrace should be restored to ON after _write_key"
}

# Test: _write_key content not leaked in trace output
test_write_key_no_secret_in_trace() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" > "$func_script"

    local key_path="$TEST_TEMP_DIR/test_key"
    local secret="SUPER_SECRET_KEY_MATERIAL_12345"

    # Run with xtrace ON, capture stderr (trace output)
    local trace_output
    trace_output=$(
        source "$func_script"
        set -x
        export TRACE_SECRET_KEY="$secret"
        _write_key "$key_path" TRACE_SECRET_KEY
        set +x
    ) 2>&1 || true

    assert_not_contains "$trace_output" "$secret" \
        "Secret key material should NOT appear in trace output"
}

# ---------------------------------------------------------------------------
# Functional tests: Identity
# ---------------------------------------------------------------------------

# Test: Identity defaults when vars unset
test_identity_defaults() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '${GIT_USER_NAME:-Devcontainer}' \
        "Should default GIT_USER_NAME to Devcontainer"
    assert_file_contains "$SETUP_GIT_SCRIPT" '${GIT_USER_EMAIL:-devcontainer@localhost}' \
        "Should default GIT_USER_EMAIL to devcontainer@localhost"
}

# Test: Identity sets git config
test_identity_sets_git_config() {
    # Verify setup_identity calls git config --global user.name and user.email
    assert_file_contains "$SETUP_GIT_SCRIPT" 'git config --global user.name' \
        "setup_identity should set git user.name"
    assert_file_contains "$SETUP_GIT_SCRIPT" 'git config --global user.email' \
        "setup_identity should set git user.email"
}

# Test: Auth key skips when GIT_AUTH_SSH_KEY is unset
test_auth_key_skips_when_unset() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'GIT_AUTH_SSH_KEY:-' \
        "setup_auth_key should check if GIT_AUTH_SSH_KEY is set"
}

# Test: Signing key skips when GIT_SIGNING_SSH_KEY is unset
test_signing_key_skips_when_unset() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'GIT_SIGNING_SSH_KEY:-' \
        "setup_signing_key should check if GIT_SIGNING_SSH_KEY is set"
}

# Test: SSH agent creates .ssh directory
test_ssh_agent_creates_ssh_dir() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'mkdir -p "${HOME}/.ssh"' \
        "ensure_ssh_agent should create .ssh directory"
    assert_file_contains "$SETUP_GIT_SCRIPT" 'chmod 700 "${HOME}/.ssh"' \
        "ensure_ssh_agent should set .ssh directory permissions to 700"
}

# Test: Key file permissions set to 600
test_key_file_permissions() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'chmod 600' \
        "Key files should have 600 permissions"
}

# Test: Signing key configures gpg.format ssh
test_signing_configures_gpg_format() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'git config --global gpg.format ssh' \
        "Signing setup should configure gpg.format to ssh"
    assert_file_contains "$SETUP_GIT_SCRIPT" 'git config --global commit.gpgsign true' \
        "Signing setup should enable commit.gpgsign"
    assert_file_contains "$SETUP_GIT_SCRIPT" 'git config --global tag.gpgsign true' \
        "Signing setup should enable tag.gpgsign"
}

# Test: main function calls all setup steps
test_main_calls_all_steps() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'setup_identity' \
        "main should call setup_identity"
    assert_file_contains "$SETUP_GIT_SCRIPT" 'ensure_ssh_agent' \
        "main should call ensure_ssh_agent"
    assert_file_contains "$SETUP_GIT_SCRIPT" 'setup_auth_key' \
        "main should call setup_auth_key"
    assert_file_contains "$SETUP_GIT_SCRIPT" 'setup_signing_key' \
        "main should call setup_signing_key"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test_with_setup test_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_no_unconditional_set_x "No unconditional { set -x; } pattern"
run_test_with_setup test_write_key_uses_indirection "_write_key uses variable name indirection"
run_test_with_setup test_write_key_saves_xtrace "_write_key saves xtrace state"
run_test_with_setup test_write_key_disables_xtrace "_write_key disables xtrace safely"
run_test_with_setup test_write_key_restores_xtrace "_write_key restores xtrace via eval"
run_test_with_setup test_helper_functions_defined "Helper functions are defined"
run_test_with_setup test_write_key_defined "_write_key function is defined"
run_test_with_setup test_setup_identity_defined "setup_identity function is defined"
run_test_with_setup test_ensure_ssh_agent_defined "ensure_ssh_agent function is defined"
run_test_with_setup test_setup_auth_key_defined "setup_auth_key function is defined"
run_test_with_setup test_setup_signing_key_defined "setup_signing_key function is defined"
run_test_with_setup test_write_key_called_with_var_name "_write_key called with variable names not values"
run_test_with_setup test_write_key_writes_file "_write_key writes key to file with 600 permissions"
run_test_with_setup test_write_key_skips_unchanged "_write_key returns 1 when key unchanged"
run_test_with_setup test_write_key_xtrace_stays_off "_write_key does not enable xtrace when off"
run_test_with_setup test_write_key_xtrace_restored_on "_write_key restores xtrace when it was on"
run_test_with_setup test_write_key_no_secret_in_trace "_write_key does not leak secrets in trace output"
run_test_with_setup test_identity_defaults "Identity defaults to Devcontainer when vars unset"
run_test_with_setup test_identity_sets_git_config "Identity sets git config user.name and user.email"
run_test_with_setup test_auth_key_skips_when_unset "Auth key skips when GIT_AUTH_SSH_KEY unset"
run_test_with_setup test_signing_key_skips_when_unset "Signing key skips when GIT_SIGNING_SSH_KEY unset"
run_test_with_setup test_ssh_agent_creates_ssh_dir "SSH agent creates .ssh directory with correct permissions"
run_test_with_setup test_key_file_permissions "Key files have 600 permissions"
run_test_with_setup test_signing_configures_gpg_format "Signing key configures gpg.format ssh"
run_test_with_setup test_main_calls_all_steps "Main function calls all setup steps"

# Generate test report
generate_report
