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
    assert_file_contains "$SETUP_GIT_SCRIPT" 'set +o | command grep xtrace' \
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
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" >"$func_script"

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
    actual_content=$(command cat "$key_path")
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
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" >"$func_script"

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
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" >"$func_script"

    local key_path="$TEST_TEMP_DIR/test_key"

    # Run with xtrace OFF, check it stays OFF
    local xtrace_after
    xtrace_after=$(
        set -euo pipefail
        source "$func_script"
        set +x # Ensure xtrace is OFF
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
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" >"$func_script"

    local key_path="$TEST_TEMP_DIR/test_key"

    # Run with xtrace ON, check it's restored to ON
    local xtrace_after
    xtrace_after=$(
        source "$func_script"
        set -x # Enable xtrace
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
    command sed -n '/^_write_key()/,/^}/p' "$SETUP_GIT_SCRIPT" >"$func_script"

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

# Test: Signing key checks if GIT_SIGNING_SSH_KEY is set
test_signing_key_checks_env_var() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'GIT_SIGNING_SSH_KEY:-' \
        "setup_signing_key should check if GIT_SIGNING_SSH_KEY is set"
}

# Test: Signing key falls back to SSH agent when env var unset
test_signing_key_agent_fallback() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'ssh-add -L' \
        "setup_signing_key should check SSH agent for keys when env var unset"
}

# Test: _clear_signing_config function is defined
test_clear_signing_config_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_clear_signing_config()' \
        "_clear_signing_config function should be defined"
}

# Test: Stale signing config is cleared when no key available
test_stale_signing_config_cleared() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'cleared stale signing configuration' \
        "Should clear stale signing config when no key available"
}

# Test: _configure_signing helper is defined
test_configure_signing_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_configure_signing()' \
        "_configure_signing function should be defined"
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
# SSH agent: container-local agent preference (VS Code forwarded agent fix)
# ---------------------------------------------------------------------------

# Test: ensure_ssh_agent does NOT have bare SSH_AUTH_SOCK check before agent.env
test_no_bare_ssh_auth_sock_check() {
    # The old pattern was: check SSH_AUTH_SOCK first, return if alive.
    # This caused VS Code's forwarded agent to be accepted, skipping agent.env.
    # The fix removes that first check so agent.env is always the first priority.
    assert_file_not_contains "$SETUP_GIT_SCRIPT" '# Already running?' \
        "ensure_ssh_agent should not have the old 'Already running?' check"
}

# Test: ensure_ssh_agent sources agent.env as the first priority
test_agent_env_is_first_priority() {
    # After mkdir/chmod, the very first conditional code should be the agent.env check,
    # not a bare SSH_AUTH_SOCK test. Compare only non-comment lines.
    local func_body
    func_body=$(command sed -n '/^ensure_ssh_agent()/,/^}/p' "$SETUP_GIT_SCRIPT" | command grep -v '^\s*#')

    # Find line numbers of key patterns within code-only lines
    local agent_env_line ssh_sock_line
    agent_env_line=$(echo "$func_body" | command grep -n 'if \[ -f "$agent_env" \]' | command head -1 | command cut -d: -f1)
    ssh_sock_line=$(echo "$func_body" | command grep -n 'SSH_AUTH_SOCK' | command head -1 | command cut -d: -f1)

    # agent.env check should appear at or before the first SSH_AUTH_SOCK reference in code
    assert_true "[ -n '$agent_env_line' ] && [ -n '$ssh_sock_line' ] && [ '$agent_env_line' -le '$ssh_sock_line' ]" \
        "agent.env check should appear before first SSH_AUTH_SOCK reference in code"
}

# Test: comment documents intent to ignore external agents
test_ignore_external_agent_comment() {
    assert_file_contains "$SETUP_GIT_SCRIPT" 'ignore externally-provided' \
        "ensure_ssh_agent should document intent to ignore external agents"
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
run_test_with_setup test_signing_key_checks_env_var "Signing key checks if GIT_SIGNING_SSH_KEY is set"
run_test_with_setup test_signing_key_agent_fallback "Signing key falls back to SSH agent"
run_test_with_setup test_clear_signing_config_defined "_clear_signing_config function is defined"
run_test_with_setup test_stale_signing_config_cleared "Stale signing config cleared when no key"
run_test_with_setup test_configure_signing_defined "_configure_signing helper is defined"
run_test_with_setup test_ssh_agent_creates_ssh_dir "SSH agent creates .ssh directory with correct permissions"
run_test_with_setup test_key_file_permissions "Key files have 600 permissions"
run_test_with_setup test_signing_configures_gpg_format "Signing key configures gpg.format ssh"
run_test_with_setup test_main_calls_all_steps "Main function calls all setup steps"
# ---------------------------------------------------------------------------
# OP secrets cache sourcing (via _wait-for-op-cache helper)
# ---------------------------------------------------------------------------

# Test: Script sources _wait-for-op-cache helper
test_sources_wait_for_op_cache() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_wait-for-op-cache' \
        "setup-git should source _wait-for-op-cache helper"
}

# Test: Script does NOT contain inline OP cache block (regression guard)
test_no_inline_op_cache() {
    assert_file_not_contains "$SETUP_GIT_SCRIPT" '/dev/shm/op-secrets-cache' \
        "setup-git should NOT contain inline /dev/shm/op-secrets-cache reference"
}

# ---------------------------------------------------------------------------
# Input validation tests
# ---------------------------------------------------------------------------

# Test: _validate_email function is defined
test_validate_email_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_validate_email()' \
        "_validate_email function should be defined"
}

# Test: _validate_ssh_key function is defined
test_validate_ssh_key_defined() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_validate_ssh_key()' \
        "_validate_ssh_key function should be defined"
}

# Test: _validate_email accepts valid email
test_validate_email_accepts_valid() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    # Extract helpers and validation functions
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GIT_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_email "user@example.com" "TEST_EMAIL"
    ) 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "_validate_email should accept user@example.com"
}

# Test: _validate_email rejects email without @
test_validate_email_rejects_no_at() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GIT_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_email "nope" "TEST_EMAIL"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_email should reject 'nope'"
}

# Test: _validate_email rejects bare @
test_validate_email_rejects_bare_at() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GIT_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_email "@domain" "TEST_EMAIL"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_email should reject '@domain' (empty local part)"
}

# Test: _validate_ssh_key accepts PEM key
test_validate_ssh_key_accepts_pem() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GIT_SCRIPT" | command head -n -1 >"$func_script"

    # Build the PEM header dynamically to avoid triggering secret scanners
    local pem_header="-----BEGIN "
    local mock_key="${pem_header}TEST KEY-----
mock-content
-----END TEST KEY-----"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_ssh_key "$mock_key" "TEST_KEY"
    ) 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" "_validate_ssh_key should accept PEM-formatted key"
}

# Test: _validate_ssh_key rejects non-PEM content
test_validate_ssh_key_rejects_non_pem() {
    local func_script="$TEST_TEMP_DIR/func.sh"
    command sed -n '1,/^# ---.*Source OP/p' "$SETUP_GIT_SCRIPT" | command head -n -1 >"$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        _validate_ssh_key "not-a-key" "TEST_KEY"
    ) 2>/dev/null || exit_code=$?

    assert_equals "1" "$exit_code" "_validate_ssh_key should reject non-PEM content"
}

# ---------------------------------------------------------------------------
# _warn_if_ref_unresolved — behavioral tests
#
# These run the function rather than grepping the source. The bug this guards
# (issue #785) was a runtime fail-open: setup_auth_key returned 0 silently when
# GIT_AUTH_SSH_KEY was empty, so a container booted with no SSH keys while the
# postStart && chain reported success. Static assertions cannot catch that —
# only invoking the function and inspecting stderr can.
# ---------------------------------------------------------------------------

# Extract _warn_if_ref_unresolved plus a stub _warn into a sourceable script.
_extract_warn_fn() {
    local func_script="$1"
    {
        echo '_warn() { printf "[setup-git] WARN: %s\n" "$*" >&2; }'
        command sed -n '/^_warn_if_ref_unresolved()/,/^}/p' "$SETUP_GIT_SCRIPT"
    } >"$func_script"
}

# Test: warns when OP_<NAME>_REF is set but <NAME> resolved empty
test_warn_when_ref_set_but_secret_empty() {
    local func_script="$TEST_TEMP_DIR/warn_fn.sh"
    _extract_warn_fn "$func_script"

    local output
    output=$(
        set -euo pipefail
        source "$func_script"
        unset GIT_AUTH_SSH_KEY
        export OP_GIT_AUTH_SSH_KEY_REF="op://vault/item/field"
        _warn_if_ref_unresolved GIT_AUTH_SSH_KEY 2>&1
    )

    assert_contains "$output" "OP_GIT_AUTH_SSH_KEY_REF is set but GIT_AUTH_SSH_KEY is empty" \
        "Should warn when the ref is configured but the secret did not resolve"
}

# Test: returns 0 even when warning (must not break the postStart && chain)
test_warn_returns_zero() {
    local func_script="$TEST_TEMP_DIR/warn_fn.sh"
    _extract_warn_fn "$func_script"

    local exit_code=0
    (
        set -euo pipefail
        source "$func_script"
        unset GIT_AUTH_SSH_KEY
        export OP_GIT_AUTH_SSH_KEY_REF="op://vault/item/field"
        _warn_if_ref_unresolved GIT_AUTH_SSH_KEY 2>/dev/null
    ) || exit_code=$?

    assert_equals "0" "$exit_code" \
        "Should return 0 so a transient race does not break the postStart chain"
}

# Test: silent when no ref is configured (must not cry wolf)
test_no_warn_when_no_ref_configured() {
    local func_script="$TEST_TEMP_DIR/warn_fn.sh"
    _extract_warn_fn "$func_script"

    local output
    output=$(
        set -euo pipefail
        source "$func_script"
        unset GIT_AUTH_SSH_KEY OP_GIT_AUTH_SSH_KEY_REF
        _warn_if_ref_unresolved GIT_AUTH_SSH_KEY 2>&1
    )

    assert_empty "$output" \
        "Should stay silent when no OP ref is configured (nothing was expected)"
}

# Test: silent when the secret resolved successfully
test_no_warn_when_secret_resolved() {
    local func_script="$TEST_TEMP_DIR/warn_fn.sh"
    _extract_warn_fn "$func_script"

    local output
    output=$(
        set -euo pipefail
        source "$func_script"
        export GIT_AUTH_SSH_KEY="mock-key-material"
        export OP_GIT_AUTH_SSH_KEY_REF="op://vault/item/field"
        _warn_if_ref_unresolved GIT_AUTH_SSH_KEY 2>&1
    )

    assert_empty "$output" "Should stay silent when the secret resolved"
}

# Test: the signing-key variable is warned about too, not just the auth key.
# Both call sites pass a different variable name into the same helper, so the
# name-substitution has to be exercised for each — a helper that hardcoded
# GIT_AUTH_SSH_KEY would still pass the auth-key test above.
test_warn_uses_correct_var_for_signing_key() {
    local func_script="$TEST_TEMP_DIR/warn_fn.sh"
    _extract_warn_fn "$func_script"

    local output
    output=$(
        set -euo pipefail
        source "$func_script"
        unset GIT_SIGNING_SSH_KEY
        export OP_GIT_SIGNING_SSH_KEY_REF="op://vault/item/field"
        _warn_if_ref_unresolved GIT_SIGNING_SSH_KEY 2>&1
    )

    assert_contains "$output" "OP_GIT_SIGNING_SSH_KEY_REF is set but GIT_SIGNING_SSH_KEY is empty" \
        "Should name the signing-key variables, not the auth-key ones"
}

# Test: setup_auth_key calls the warn helper before its skip guard
test_auth_key_calls_warn_helper() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_warn_if_ref_unresolved GIT_AUTH_SSH_KEY' \
        "setup_auth_key should warn before silently skipping"
}

# Test: setup_signing_key calls the warn helper
test_signing_key_calls_warn_helper() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_warn_if_ref_unresolved GIT_SIGNING_SSH_KEY' \
        "setup_signing_key should warn before silently skipping"
}

# Test: setup_identity calls _validate_email
test_identity_validates_email() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_validate_email "$email" "GIT_USER_EMAIL"' \
        "setup_identity should validate GIT_USER_EMAIL"
}

# Test: setup_auth_key calls _validate_ssh_key
test_auth_key_validates_key() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_validate_ssh_key "$GIT_AUTH_SSH_KEY" "GIT_AUTH_SSH_KEY"' \
        "setup_auth_key should validate GIT_AUTH_SSH_KEY"
}

# Test: setup_signing_key calls _validate_ssh_key
test_signing_key_validates_key() {
    assert_file_contains "$SETUP_GIT_SCRIPT" '_validate_ssh_key "$GIT_SIGNING_SSH_KEY" "GIT_SIGNING_SSH_KEY"' \
        "setup_signing_key should validate GIT_SIGNING_SSH_KEY"
}

run_test_with_setup test_validate_email_defined "_validate_email function is defined"
run_test_with_setup test_validate_ssh_key_defined "_validate_ssh_key function is defined"
run_test_with_setup test_validate_email_accepts_valid "_validate_email accepts valid email"
run_test_with_setup test_validate_email_rejects_no_at "_validate_email rejects email without @"
run_test_with_setup test_validate_email_rejects_bare_at "_validate_email rejects bare @"
run_test_with_setup test_validate_ssh_key_accepts_pem "_validate_ssh_key accepts PEM key"
run_test_with_setup test_validate_ssh_key_rejects_non_pem "_validate_ssh_key rejects non-PEM content"
run_test_with_setup test_identity_validates_email "setup_identity validates email"
run_test_with_setup test_auth_key_validates_key "setup_auth_key validates SSH key"
run_test_with_setup test_warn_when_ref_set_but_secret_empty "Warns when OP ref set but secret empty (#785)"
run_test_with_setup test_warn_returns_zero "Warn helper returns 0 (does not break && chain)"
run_test_with_setup test_no_warn_when_no_ref_configured "Silent when no OP ref configured"
run_test_with_setup test_no_warn_when_secret_resolved "Silent when secret resolved"
run_test_with_setup test_warn_uses_correct_var_for_signing_key "Warn names signing-key vars (not auth-key)"
run_test_with_setup test_auth_key_calls_warn_helper "setup_auth_key calls warn helper"
run_test_with_setup test_signing_key_calls_warn_helper "setup_signing_key calls warn helper"
run_test_with_setup test_signing_key_validates_key "setup_signing_key validates SSH key"

run_test_with_setup test_sources_wait_for_op_cache "Script sources _wait-for-op-cache helper"
run_test_with_setup test_no_inline_op_cache "No inline OP cache block (regression guard)"
run_test_with_setup test_no_bare_ssh_auth_sock_check "ensure_ssh_agent does not accept external SSH_AUTH_SOCK"
run_test_with_setup test_agent_env_is_first_priority "ensure_ssh_agent checks agent.env before SSH_AUTH_SOCK"
run_test_with_setup test_ignore_external_agent_comment "ensure_ssh_agent documents intent to ignore external agents"

# Generate test report
# ---------------------------------------------------------------------------
# #1711: externally provided ssh / signing is left alone
# ---------------------------------------------------------------------------
# Behavioural: run the real script in a scratch HOME (gitconfig lives there,
# GIT_CONFIG_GLOBAL pins it) with ssh-agent / ssh-add / ssh-keygen stubbed to
# record calls. BASH_ENV is unset so the stubs win on PATH.

# A real ed25519 key so the default (non-provider) path has something to sign
# with and so a regression would visibly write signing config.
_make_signing_key() {
    ssh-keygen -q -t ed25519 -N '' -C t -f "$TEST_TEMP_DIR/sigkey" >/dev/null 2>&1
}

_stub_ssh_tools() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/bin/bash\necho "ssh-agent $*" >>"%s/ssh.calls"\necho "SSH_AUTH_SOCK=/tmp/fake.sock; export SSH_AUTH_SOCK;"\necho "SSH_AGENT_PID=1; export SSH_AGENT_PID;"\n' \
        "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/ssh-agent"
    # Key adds succeed unless $TEST_TEMP_DIR/ssh-add.fail exists (#1723).
    printf '#!/bin/bash\necho "ssh-add $*" >>"%s/ssh.calls"\ncase "$1" in -l|-L) exit 1 ;; esac\n[ -e "%s/ssh-add.fail" ] && exit 1\nexit 0\n' \
        "$TEST_TEMP_DIR" "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/ssh-add"
    chmod +x "$TEST_TEMP_DIR/bin/ssh-agent" "$TEST_TEMP_DIR/bin/ssh-add"
    : >"$TEST_TEMP_DIR/ssh.calls"
}

# Run setup-git sandboxed; extra NAME=value args go into its env.
_run_setup_git() {
    _stub_ssh_tools
    command env -i BASH_ENV= HOME="$TEST_HOME" \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        WORKSPACE_ROOT="$TEST_TEMP_DIR/ws" \
        GIT_USER_NAME="Test User" GIT_USER_EMAIL="test@example.com" \
        "$@" bash "$SETUP_GIT_SCRIPT" 2>&1
}

_gitcfg() {
    command env -i BASH_ENV= HOME="$TEST_HOME" PATH="/usr/bin:/bin" \
        GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" git config --global --get "$1" 2>/dev/null || true
}

# Seed a provider-style signing config, as if a provider had written it.
_seed_signing() {
    command env -i BASH_ENV= HOME="$TEST_HOME" PATH="/usr/bin:/bin" \
        GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" sh -c '
        git config --global gpg.format ssh
        git config --global user.signingkey /provider/key.pub
        git config --global commit.gpgsign true'
}

test_baseline_starts_agent_and_writes_ssh_command() {
    # Guards the guards: without a provider, today's behaviour still happens,
    # so the provider tests below cannot pass merely because nothing ran.
    _make_signing_key
    local out
    out=$(_run_setup_git GIT_AUTH_SSH_KEY="$(command cat "$TEST_TEMP_DIR/sigkey")")
    assert_file_contains "$TEST_TEMP_DIR/ssh.calls" "ssh-agent -s" \
        "Baseline: setup-git starts its own ssh-agent"
    assert_contains "$(_gitcfg core.sshCommand)" "git_auth_key" \
        "Baseline: setup-git writes core.sshCommand"
    assert_not_contains "$out" "provided externally" "Baseline: no provider skip lines"
}

test_git_ssh_command_skips_agent_and_ssh_command() {
    _make_signing_key
    local out
    out=$(_run_setup_git GIT_SSH_COMMAND="provider-ssh" \
        GIT_AUTH_SSH_KEY="$(command cat "$TEST_TEMP_DIR/sigkey")")
    assert_file_not_contains "$TEST_TEMP_DIR/ssh.calls" "ssh-agent" \
        "GIT_SSH_COMMAND set: no second ssh-agent"
    assert_equals "" "$(_gitcfg core.sshCommand)" \
        "GIT_SSH_COMMAND set: core.sshCommand is not written"
    assert_contains "$out" "ssh agent + auth key: provided externally (GIT_SSH_COMMAND set)" \
        "One skip line names the reason"
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'provided externally (GIT_SSH')" \
        "Exactly one ssh skip line"
    assert_equals "Test User" "$(_gitcfg user.name)" "Identity still configured"
}

test_git_config_env_ssh_command_detected() {
    local out
    out=$(_run_setup_git GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.sshcommand GIT_CONFIG_VALUE_0=x)
    assert_file_not_contains "$TEST_TEMP_DIR/ssh.calls" "ssh-agent" \
        "core.sshCommand via GIT_CONFIG_* (any case): no second agent"
    assert_contains "$out" "GIT_CONFIG_* defines core.sshCommand" "Skip reason names the key"
}

test_external_signing_left_alone() {
    _seed_signing
    local out
    out=$(_run_setup_git GIT_CONFIG_COUNT=2 \
        GIT_CONFIG_KEY_0=gpg.format GIT_CONFIG_VALUE_0=ssh \
        GIT_CONFIG_KEY_1=gpg.ssh.program GIT_CONFIG_VALUE_1=/provider/sign)
    assert_equals "/provider/key.pub" "$(_gitcfg user.signingkey)" \
        "Provider signing: user.signingkey is not unset (no _clear_signing_config)"
    assert_equals "true" "$(_gitcfg commit.gpgsign)" "Provider signing: commit.gpgsign untouched"
    assert_contains "$out" "signing: provided externally (GIT_CONFIG_* defines gpg.format)" \
        "One skip line names the reason"
}

test_baseline_clears_stale_signing() {
    # Guards the guard: with no provider and no key, stale signing config IS
    # cleared — so the test above proves the skip, not a no-op.
    _seed_signing
    _run_setup_git >/dev/null
    assert_equals "" "$(_gitcfg user.signingkey)" "Baseline: stale signing config is cleared"
}

test_skip_flags() {
    _seed_signing
    local out
    out=$(_run_setup_git SKIP_GIT_SSH_SETUP=true SKIP_GIT_SIGNING_SETUP=true)
    assert_file_not_contains "$TEST_TEMP_DIR/ssh.calls" "ssh-agent" "SKIP_GIT_SSH_SETUP=true: no agent"
    assert_equals "/provider/key.pub" "$(_gitcfg user.signingkey)" "SKIP_GIT_SIGNING_SETUP=true: signing untouched"
    assert_contains "$out" "(SKIP_GIT_SSH_SETUP=true)" "ssh skip reason"
    assert_contains "$out" "(SKIP_GIT_SIGNING_SETUP=true)" "signing skip reason"
}

test_ssh_provider_does_not_skip_signing() {
    # Only the conflicting part is skipped: an ssh provider alone must not
    # suppress signing setup (signing stays independent).
    _seed_signing
    local out
    out=$(_run_setup_git GIT_SSH_COMMAND="provider-ssh")
    assert_not_contains "$out" "signing: provided externally" "ssh provider alone does not skip signing"
}

# ---------------------------------------------------------------------------
# #1723: a failing ssh-add key add is a WARN, not an abort
# ---------------------------------------------------------------------------
test_auth_key_add_failure_continues() {
    _make_signing_key
    : >"$TEST_TEMP_DIR/ssh-add.fail"
    local out rc=0
    out=$(_run_setup_git GIT_AUTH_SSH_KEY="$(command cat "$TEST_TEMP_DIR/sigkey")") || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 when the auth-key agent add fails"
    assert_file_contains "$TEST_TEMP_DIR/ssh.calls" "ssh-add $TEST_HOME/.ssh/git_auth_key" \
        "The auth-key add was attempted (stub reached)"
    assert_contains "$out" "WARN: could not add auth key to ssh-agent" "Failed add logs a WARN"
    assert_not_contains "$out" "OK: auth key added to ssh-agent" "No false OK for the add"
    assert_contains "$(_gitcfg core.sshCommand)" "git_auth_key" \
        "core.sshCommand still written after a failed add"
    assert_contains "$out" "[setup-git] OK: done" "setup-git runs to completion"
}

test_signing_key_add_failure_continues() {
    _make_signing_key
    : >"$TEST_TEMP_DIR/ssh-add.fail"
    local out rc=0
    out=$(_run_setup_git GIT_SIGNING_SSH_KEY="$(command cat "$TEST_TEMP_DIR/sigkey")") || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 when the signing-key agent add fails"
    assert_file_contains "$TEST_TEMP_DIR/ssh.calls" "ssh-add $TEST_HOME/.ssh/git_signing_key" \
        "The signing-key add was attempted (stub reached)"
    assert_contains "$out" "WARN: could not add signing key to ssh-agent" "Failed add logs a WARN"
    assert_not_contains "$out" "OK: signing key added to ssh-agent" "No false OK for the add"
    assert_equals "$TEST_HOME/.ssh/git_signing_key.pub" "$(_gitcfg user.signingkey)" \
        "Signing config still written after a failed add"
    assert_equals "ssh" "$(_gitcfg gpg.format)" "gpg.format=ssh still written"
    assert_contains "$out" "[setup-git] OK: done" "setup-git runs to completion"
}

run_test_with_setup test_baseline_starts_agent_and_writes_ssh_command "#1711 baseline: no provider → own agent + core.sshCommand"
run_test_with_setup test_git_ssh_command_skips_agent_and_ssh_command "#1711: GIT_SSH_COMMAND → no agent, no core.sshCommand, one skip line"
run_test_with_setup test_git_config_env_ssh_command_detected "#1711: core.sshCommand via GIT_CONFIG_* detected"
run_test_with_setup test_external_signing_left_alone "#1711: GIT_CONFIG_* signing → no signing writes or unsets"
run_test_with_setup test_baseline_clears_stale_signing "#1711 baseline: no provider → stale signing cleared"
run_test_with_setup test_skip_flags "#1711: SKIP_GIT_SSH_SETUP / SKIP_GIT_SIGNING_SETUP"
run_test_with_setup test_ssh_provider_does_not_skip_signing "#1711: ssh provider alone does not skip signing"
run_test_with_setup test_auth_key_add_failure_continues "#1723: failed auth-key ssh-add warns, still writes core.sshCommand"
run_test_with_setup test_signing_key_add_failure_continues "#1723: failed signing-key ssh-add warns, still configures signing"

# ---------------------------------------------------------------------------
# #1533: repo-local identity shadowing the global one (warn only)
# ---------------------------------------------------------------------------
# Scratch workspace under $TEST_TEMP_DIR/ws (the WORKSPACE_ROOT _run_setup_git
# passes); the global identity is a real address so only the local one varies.
REAL_EMAIL="josh@yaplabs.com"

# _ws_repo NAME [EMAIL] — init a workspace repo, optionally with a local email.
_ws_repo() {
    local repo="$TEST_TEMP_DIR/ws/$1"
    command mkdir -p "$repo"
    git -C "$repo" init -q
    if [ -n "${2:-}" ]; then
        git -C "$repo" config --local user.name "t"
        git -C "$repo" config --local user.email "$2"
    fi
}

# Run setup-git with ssh/signing out of the way and a real global identity.
# Extra NAME=value args override (env takes the last assignment).
_run_identity() {
    _run_setup_git SKIP_GIT_SSH_SETUP=true SKIP_GIT_SIGNING_SETUP=true \
        GIT_USER_EMAIL="$REAL_EMAIL" "$@"
}

test_local_placeholder_warns() {
    _ws_repo proj "t@t.t"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 (warn-only)"
    assert_contains "$out" "WARN: $TEST_TEMP_DIR/ws/proj: local user.email <t@t.t> is a placeholder" \
        "Placeholder local email is named as a placeholder"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/proj/.git/config" \
        "Warning names the overriding .git/config"
    local qproj
    printf -v qproj '%q' "$TEST_TEMP_DIR/ws/proj"
    assert_contains "$out" "git -C $qproj config --local --unset user.name; git -C $qproj config --local --unset user.email" \
        "Warning prints the unset remedy"
    assert_equals "t@t.t" "$(git -C "$TEST_TEMP_DIR/ws/proj" config --local user.email)" \
        "Local identity is left in place (never auto-unset)"
}

test_local_real_differing_warns_not_placeholder() {
    _ws_repo work "me@work-corp.io"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 (warn-only)"
    assert_contains "$out" "local user.email <me@work-corp.io> differs from global <$REAL_EMAIL>" \
        "Differing real local email warns"
    assert_not_contains "$out" "placeholder" "A real address is not called a placeholder"
    assert_contains "$out" "--unset user.email" "Remedy still printed"
}

test_no_local_identity_is_silent() {
    _ws_repo clean
    _ws_repo same "$REAL_EMAIL"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0"
    assert_not_contains "$out" "WARN" "No local identity (or same as global) → no new output"
}

test_worktree_config_reported_once() {
    _ws_repo proj "t@t.t"
    git -C "$TEST_TEMP_DIR/ws/proj" -c user.name=a -c user.email=a@b.co \
        commit -q --allow-empty -m init
    git -C "$TEST_TEMP_DIR/ws/proj" worktree add -q .worktrees/issue-1
    # Without the worktree the count below is trivially 1 — prove it exists
    # and that git sees the shared local identity from inside it.
    assert_dir_exists "$TEST_TEMP_DIR/ws/proj/.worktrees/issue-1" "Worktree was created"
    assert_equals "t@t.t" \
        "$(git -C "$TEST_TEMP_DIR/ws/proj/.worktrees/issue-1" config --local user.email)" \
        "Worktree resolves the parent's local identity"
    local out
    out=$(_run_identity)
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "A .worktrees/* checkout sharing the repo config is reported once"
}

test_worktree_local_identity_detected() {
    # The only repo with a local identity sits under .worktrees/ of a parent
    # whose own config is clean — proves .worktrees/* is actually scanned.
    _ws_repo parent
    _ws_repo parent/.worktrees/nested "t@t.t"
    local out
    out=$(_run_identity)
    assert_contains "$out" "ws/parent/.worktrees/nested: local user.email <t@t.t>" \
        ".worktrees/* repos are scanned"
}

test_devcontainer_fallback_warns() {
    local out rc=0
    out=$(_run_setup_git SKIP_GIT_SSH_SETUP=true SKIP_GIT_SIGNING_SETUP=true \
        GIT_USER_EMAIL=) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 with the fallback identity"
    assert_equals "devcontainer@localhost" "$(_gitcfg user.email)" "Fallback identity applied"
    assert_contains "$out" "WARN: global git email <devcontainer@localhost> is a placeholder" \
        "Fallback global email warns"
    assert_contains "$out" "refused by the pre-commit author-identity check" \
        "Warning mentions the pre-commit refusal"
}

test_control_chars_stripped_and_dir_quoted() {
    _ws_repo "it's" "$(printf 'x\033[2Jy@t.t')"
    local out
    out=$(_run_identity)
    assert_not_contains "$out" "$(printf '\033')" "ESC from a repo-local email never reaches the terminal"
    assert_contains "$out" "local user.email <x[2Jy@t.t>" "Email shown with control chars stripped"
    assert_contains "$out" "git -C $(printf '%q' "$TEST_TEMP_DIR/ws/it's") config --local --unset user.email" \
        "Remedy %q-quotes a dir containing a single quote"
}

test_missing_helper_falls_back() {
    # setup-git copied alone (no _git-email-placeholder beside it): it must
    # still exit 0 and still run the differs-from-global check.
    command mkdir -p "$TEST_TEMP_DIR/lone"
    command cp "$SETUP_GIT_SCRIPT" "$TEST_TEMP_DIR/lone/setup-git"
    _ws_repo work "t@t.t"
    local out rc=0
    out=$(SETUP_GIT_SCRIPT="$TEST_TEMP_DIR/lone/setup-git" _run_setup_git \
        SKIP_GIT_SSH_SETUP=true SKIP_GIT_SIGNING_SETUP=true GIT_USER_EMAIL=) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 without the helper"
    assert_contains "$out" "local user.email <t@t.t> differs from global <devcontainer@localhost>" \
        "Differs check still runs without the helper"
    assert_not_contains "$out" "placeholder" "Without the helper nothing is called a placeholder"
}

test_root_worktrees_and_non_repos() {
    # WORKSPACE_ROOT is itself a repo; its own .worktrees/* holds the only
    # local identity, and a plain non-git dir sits beside it.
    git -C "$TEST_TEMP_DIR" init -q ws
    command mkdir -p "$TEST_TEMP_DIR/ws/not-a-repo"
    _ws_repo .worktrees/wt "t@t.t"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 with a non-repo dir in the workspace"
    assert_contains "$out" "ws/.worktrees/wt: local user.email <t@t.t>" \
        "WORKSPACE_ROOT/.worktrees/* repos are scanned"
    assert_not_contains "$out" "not-a-repo" "Non-repo dirs are skipped silently"
}

test_missing_workspace_root_is_silent() {
    local out rc=0
    out=$(_run_identity WORKSPACE_ROOT="$TEST_TEMP_DIR/does-not-exist") || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 when WORKSPACE_ROOT is absent"
    assert_not_contains "$out" "WARN" "Absent WORKSPACE_ROOT → no new output"
}

test_empty_global_email() {
    # setup_identity always writes a fallback, so drive check_identity_shadowing
    # directly: source a scratch copy without its trailing `main "$@"` call.
    assert_equals 'main "$@"' "$(command tail -n 1 "$SETUP_GIT_SCRIPT")" \
        "setup-git still ends with the main call this test strips"
    command sed '$d' "$SETUP_GIT_SCRIPT" >"$TEST_TEMP_DIR/setup-git-fns"
    command cp "$PROJECT_ROOT/lib/runtime/commands/_git-email-placeholder" "$TEST_TEMP_DIR/"
    _ws_repo work "me@work-corp.io"
    : >"$TEST_HOME/.gitconfig"
    local out rc=0
    out=$(command env -i BASH_ENV= HOME="$TEST_HOME" PATH="/usr/bin:/bin" \
        GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" WORKSPACE_ROOT="$TEST_TEMP_DIR/ws" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        bash -c '. "$1"; check_identity_shadowing' _ "$TEST_TEMP_DIR/setup-git-fns" 2>&1) || rc=$?
    assert_equals "0" "$rc" "check_identity_shadowing returns 0 with no global email"
    assert_not_contains "$out" "global git email <>" "Empty global email is not called a placeholder"
    assert_not_contains "$out" "differs from global <>" "No 'differs from global <>' message"
    assert_contains "$out" "local user.email <me@work-corp.io> is set but no global user.email is" \
        "Local email with no global says so plainly"
}

test_worktree_scope_identity_detected() {
    # extensions.worktreeConfig + `git config --worktree` writes config.worktree,
    # which `git config --local` never reads — but git commit does.
    _ws_repo wtcfg
    git -C "$TEST_TEMP_DIR/ws/wtcfg" config extensions.worktreeConfig true
    git -C "$TEST_TEMP_DIR/ws/wtcfg" config --worktree user.email "t@t.t"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/wtcfg"
    assert_contains "$out" "ws/wtcfg: worktree user.email <t@t.t> is a placeholder" \
        "A config.worktree identity is detected"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/wtcfg/.git/config.worktree" \
        "Warning names config.worktree"
    assert_contains "$out" "git -C $q config --worktree --unset user.email" \
        "Remedy uses --worktree for a worktree-scoped identity"
}

test_included_identity_detected() {
    # An identity pulled in via include.path still shadows the global one.
    _ws_repo inc
    printf '[user]\n\temail = t@t.t\n' >"$TEST_TEMP_DIR/ws/inc/.git/identity.inc"
    git -C "$TEST_TEMP_DIR/ws/inc" config include.path identity.inc
    local out
    out=$(_run_identity)
    assert_contains "$out" "ws/inc: local user.email <t@t.t> is a placeholder" \
        "An included identity is detected"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/inc/.git/identity.inc" \
        "Warning names the included file, not .git/config"
    assert_contains "$out" "remove the [user] entries from $TEST_TEMP_DIR/ws/inc/.git/identity.inc" \
        "Remedy points at the included file (--unset cannot reach it)"
}

test_symlinked_root_dedupes() {
    # WORKSPACE_ROOT reached via a symlink: the parent reports a relative
    # .git/config (prefixed with the symlinked dir) while its worktree reports
    # git's resolved absolute path. Only symlink-resolving normalization makes
    # them the same file, so the repo must still be reported once.
    _ws_repo proj "t@t.t"
    git -C "$TEST_TEMP_DIR/ws/proj" -c user.name=a -c user.email=a@b.co \
        commit -q --allow-empty -m init
    git -C "$TEST_TEMP_DIR/ws/proj" worktree add -q .worktrees/w
    command ln -s "$TEST_TEMP_DIR/ws" "$TEST_TEMP_DIR/ws-link"
    local out
    out=$(_run_identity WORKSPACE_ROOT="$TEST_TEMP_DIR/ws-link")
    assert_contains "$out" "local user.email <t@t.t>" "Repo found through the symlinked root"
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Symlinked root + worktree still reported once"
}

test_reason_control_chars_stripped() {
    # The invalid-hostname reason quotes the raw domain; an ESC there must
    # not reach the terminal any more than one in the email itself.
    _ws_repo esc "$(printf 'a@b\033[2Jc.io')"
    local out
    out=$(_run_identity)
    assert_contains "$out" "is a placeholder (domain 'b[2jc.io' is not a valid hostname)" \
        "Invalid-hostname reason is shown with control chars stripped"
    assert_not_contains "$out" "$(printf '\033')" "No ESC from the reason reaches the terminal"
}

test_non_ascii_path_dedupes_with_local_remedy() {
    # git C-quotes non-ASCII --show-origin paths unless -z is used; a quoted
    # path would defeat dedupe and route a plain local identity to the
    # include.path remedy.
    _ws_repo "pé" "t@t.t"
    git -C "$TEST_TEMP_DIR/ws/pé" -c user.name=a -c user.email=a@b.co \
        commit -q --allow-empty -m init
    git -C "$TEST_TEMP_DIR/ws/pé" worktree add -q .worktrees/w
    local out
    out=$(_run_identity)
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Non-ASCII repo + worktree reported once"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/pé/.git/config " "Unquoted, real config path shown"
    # %q's rendering of é depends on the locale (setup-git runs under env -i),
    # so assert the remedy form rather than the exact quoting.
    assert_contains "$out" "config --local --unset user.email" \
        "Plain local identity gets the --local --unset remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_root_repo_subdirs_not_scanned() {
    # WORKSPACE_ROOT is a repo with a local placeholder and plain subdirs:
    # the subdirs are not repos of their own and must not each re-report it
    # (with a nonexistent "<subdir>/.git/config" path and the include remedy).
    git -C "$TEST_TEMP_DIR" init -q ws
    git -C "$TEST_TEMP_DIR/ws" config user.email "t@t.t"
    command mkdir -p "$TEST_TEMP_DIR/ws/src" "$TEST_TEMP_DIR/ws/docs"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws"
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Root repo reported once, not once per subdirectory"
    assert_not_contains "$out" "ws/src" "Plain subdir src/ is not scanned as a repo"
    assert_not_contains "$out" "ws/docs" "Plain subdir docs/ is not scanned as a repo"
    assert_contains "$out" "git -C $q config --local --unset user.email" \
        "Root repo gets the --local remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_shared_include_reports_each_repo() {
    # Two unrelated repos include the same identity file: dedupe must not
    # collapse them, since each has its global identity shadowed.
    printf '[user]\n\temail = t@t.t\n' >"$TEST_TEMP_DIR/shared-identity.inc"
    _ws_repo one
    _ws_repo two
    git -C "$TEST_TEMP_DIR/ws/one" config include.path "$TEST_TEMP_DIR/shared-identity.inc"
    git -C "$TEST_TEMP_DIR/ws/two" config include.path "$TEST_TEMP_DIR/shared-identity.inc"
    local out
    out=$(_run_identity)
    assert_contains "$out" "ws/one: local user.email <t@t.t>" "First repo sharing the include is reported"
    assert_contains "$out" "ws/two: local user.email <t@t.t>" "Second repo sharing the include is reported"
}

test_bare_repo_reported_with_local_remedy() {
    git init -q --bare "$TEST_TEMP_DIR/ws/bare.git"
    git -C "$TEST_TEMP_DIR/ws/bare.git" config user.email "t@t.t"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/bare.git"
    assert_equals "1" "$(printf '%s\n' "$out" | command grep -c 'local user.email <t@t.t>')" \
        "Bare repo reported once"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/bare.git/config " "Bare repo's config named"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Bare repo gets --local remedy"
}

test_submodule_gets_local_remedy() {
    # A submodule's config lives in <super>/.git/modules/<m>/config; it is
    # still that repo's own local config, not an include.
    git -C "$TEST_TEMP_DIR" init -q subsrc
    git -C "$TEST_TEMP_DIR/subsrc" -c user.name=a -c user.email=a@b.co commit -q --allow-empty -m i
    _ws_repo super
    git -C "$TEST_TEMP_DIR/ws/super" -c user.name=a -c user.email=a@b.co commit -q --allow-empty -m i
    git -C "$TEST_TEMP_DIR/ws/super" -c protocol.file.allow=always \
        submodule add -q "$TEST_TEMP_DIR/subsrc" mod 2>/dev/null
    assert_dir_exists "$TEST_TEMP_DIR/ws/super/.git/modules/mod" "Submodule was created"
    git -C "$TEST_TEMP_DIR/ws/super/mod" config user.email "t@t.t"
    local out q
    # The submodule is a grandchild of WORKSPACE_ROOT; point the root at the
    # superproject so the submodule is a direct child candidate.
    out=$(_run_identity WORKSPACE_ROOT="$TEST_TEMP_DIR/ws/super")
    printf -v q '%q' "$TEST_TEMP_DIR/ws/super/mod"
    assert_contains "$out" "set in $TEST_TEMP_DIR/ws/super/.git/modules/mod/config " \
        "Submodule's real config path named"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Submodule gets --local remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_broken_worktree_skipped() {
    _ws_repo proj
    command mkdir -p "$TEST_TEMP_DIR/ws/proj/.worktrees/gone"
    printf 'gitdir: %s\n' "$TEST_TEMP_DIR/nonexistent" >"$TEST_TEMP_DIR/ws/proj/.worktrees/gone/.git"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 with a broken worktree in the workspace"
    assert_not_contains "$out" ".worktrees/gone" "Broken worktree produces no output"
}

test_ownership_rejected_repo_says_so() {
    # A host-owned bind mount without safe.directory: git refuses the repo.
    # Say so once instead of skipping silently (and never override the check).
    # Simulated with a git wrapper that refuses only this repo, exactly as
    # git does — portable, unlike git's internal GIT_TEST_ASSUME_DIFFERENT_OWNER
    # (honored only by some git builds; CI's ignores it).
    _ws_repo hostowned "t@t.t"
    local real_git hostowned="$TEST_TEMP_DIR/ws/hostowned"
    real_git=$(command -v git)
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/git" <<STUB
#!/bin/bash
if [ "\$1" = "-C" ] && [ "\$2" = "$hostowned" ]; then
    printf "fatal: detected dubious ownership in repository at '%s'\\n" "\$2" >&2
    exit 128
fi
exec "$real_git" "\$@"
STUB
    command chmod +x "$TEST_TEMP_DIR/bin/git"
    local out rc=0
    out=$(_run_identity) || rc=$?
    assert_equals "0" "$rc" "setup-git exits 0 when a repo is ownership-rejected"
    assert_contains "$out" "ws/hostowned: cannot check repo-local identity" \
        "Ownership-rejected repo is reported, not skipped silently"
    assert_not_contains "$out" "user.email <t@t.t>" "safe.directory is not overridden to read it"
}

test_symlinked_dot_git_gets_local_remedy() {
    # .git is a symlink to the real git dir. git reports both the origin file
    # and the common dir relative (".git/..."), so both sides resolve the same
    # way; this pins that a symlinked .git keeps the --local remedy.
    git init -q --separate-git-dir="$TEST_TEMP_DIR/real-gitdir" "$TEST_TEMP_DIR/ws/linked"
    command rm -f "$TEST_TEMP_DIR/ws/linked/.git"
    command ln -s "$TEST_TEMP_DIR/real-gitdir" "$TEST_TEMP_DIR/ws/linked/.git"
    git -C "$TEST_TEMP_DIR/ws/linked" config user.email "t@t.t"
    local out q
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/linked"
    assert_contains "$out" "ws/linked: local user.email <t@t.t>" "Repo with a symlinked .git is reported"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Symlinked .git gets --local remedy"
    assert_not_contains "$out" "remove the [user] entries" "Not misrouted to the include remedy"
}

test_old_git_without_path_format() {
    # git < 2.31 rejects --path-format; the scan must not depend on it.
    _ws_repo proj "t@t.t"
    local real_git q
    real_git=$(command -v git)
    command mkdir -p "$TEST_TEMP_DIR/bin"
    command cat >"$TEST_TEMP_DIR/bin/git" <<STUB
#!/bin/bash
for a in "\$@"; do
    case "\$a" in --path-format*) echo "fatal: unknown option" >&2; exit 128 ;; esac
done
exec "$real_git" "\$@"
STUB
    command chmod +x "$TEST_TEMP_DIR/bin/git"
    local out
    out=$(_run_identity)
    printf -v q '%q' "$TEST_TEMP_DIR/ws/proj"
    assert_contains "$out" "ws/proj: local user.email <t@t.t>" "Detected without --path-format"
    assert_contains "$out" "git -C $q config --local --unset user.email" "Still the --local remedy"
}

test_real_global_no_global_warning() {
    local out
    out=$(_run_identity)
    assert_not_contains "$out" "global git email" "A real global email does not warn"
}

test_placeholder_rules_shared_not_duplicated() {
    local helper="$PROJECT_ROOT/lib/runtime/commands/_git-email-placeholder"
    assert_file_contains "$helper" 'placeholder_reason()' "Shared helper defines placeholder_reason"
    assert_file_not_contains "$PROJECT_ROOT/bin/check-author-identity.sh" 'placeholder_reason()' \
        "Pre-commit hook does not redefine the rules"
    assert_file_contains "$PROJECT_ROOT/bin/check-author-identity.sh" '_git-email-placeholder' \
        "Pre-commit hook sources the shared helper"
    assert_file_contains "$SETUP_GIT_SCRIPT" '_git-email-placeholder' \
        "setup-git sources the shared helper"
    assert_file_contains "$PROJECT_ROOT/Dockerfile" \
        'COPY lib/runtime/commands/_git-email-placeholder /usr/local/bin/_git-email-placeholder' \
        "Dockerfile installs the helper next to setup-git"
}

run_test_with_setup test_local_placeholder_warns "#1533: local t@t.t → WARN names .git/config + unset remedy"
run_test_with_setup test_local_real_differing_warns_not_placeholder "#1533: differing real local email warns, not a placeholder"
run_test_with_setup test_no_local_identity_is_silent "#1533: no local identity → no new output"
run_test_with_setup test_worktree_config_reported_once "#1533: worktree sharing repo config reported once"
run_test_with_setup test_worktree_local_identity_detected "#1533: .worktrees/* repos are scanned"
run_test_with_setup test_devcontainer_fallback_warns "#1533: devcontainer@localhost fallback warns of pre-commit refusal"
run_test_with_setup test_control_chars_stripped_and_dir_quoted "#1533: repo-controlled strings sanitized; remedy %q-quoted"
run_test_with_setup test_missing_helper_falls_back "#1533: missing helper → still exits 0, differs check runs"
run_test_with_setup test_root_worktrees_and_non_repos "#1533: WORKSPACE_ROOT/.worktrees scanned; non-repo dirs skipped"
run_test_with_setup test_missing_workspace_root_is_silent "#1533: absent WORKSPACE_ROOT → silent, exit 0"
run_test_with_setup test_empty_global_email "#1533: no global email → no '<>' placeholder/differs message"
run_test_with_setup test_worktree_scope_identity_detected "#1533: config.worktree identity detected; --worktree remedy"
run_test_with_setup test_included_identity_detected "#1533: include.path identity detected; names the included file"
run_test_with_setup test_symlinked_root_dedupes "#1533: symlinked WORKSPACE_ROOT + worktree reported once"
run_test_with_setup test_reason_control_chars_stripped "#1533: placeholder reason sanitized (no ESC from domain)"
run_test_with_setup test_non_ascii_path_dedupes_with_local_remedy "#1533: non-ASCII path — -z parse dedupes, --local remedy"
run_test_with_setup test_root_repo_subdirs_not_scanned "#1533: root repo's plain subdirs not re-reported"
run_test_with_setup test_shared_include_reports_each_repo "#1533: unrelated repos sharing an include are each reported"
run_test_with_setup test_bare_repo_reported_with_local_remedy "#1533: bare repo reported once with --local remedy"
run_test_with_setup test_submodule_gets_local_remedy "#1533: submodule config path + --local remedy"
run_test_with_setup test_broken_worktree_skipped "#1533: broken worktree skipped, exit 0"
run_test_with_setup test_ownership_rejected_repo_says_so "#1533: ownership-rejected repo → one skip line, exit 0"
run_test_with_setup test_symlinked_dot_git_gets_local_remedy "#1533: symlinked .git → --local remedy"
run_test_with_setup test_old_git_without_path_format "#1533: works on git without --path-format (< 2.31)"
run_test_with_setup test_real_global_no_global_warning "#1533: real global email → no global warning"
run_test_with_setup test_placeholder_rules_shared_not_duplicated "#1533: placeholder rules shared, not duplicated"

generate_report
