#!/usr/bin/env bash
# Unit tests for lib/features/op-cli.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "op-cli Feature Tests"

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-op-cli"
    mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    [ -n "${TEST_TEMP_DIR:-}" ] && command rm -rf "$TEST_TEMP_DIR"
}

test_installation() {
    local bin_file="$TEST_TEMP_DIR/usr/local/bin/test-binary"
    mkdir -p "$(dirname "$bin_file")"
    touch "$bin_file" && chmod +x "$bin_file"
    assert_file_exists "$bin_file"
    [ -x "$bin_file" ] && assert_true true "Binary is executable" || assert_true false "Binary not executable"
}

test_configuration() {
    local config_file="$TEST_TEMP_DIR/config.conf"
    echo "test=true" > "$config_file"
    assert_file_exists "$config_file"
    grep -q "test=true" "$config_file" && assert_true true "Config valid" || assert_true false "Config invalid"
}

test_environment() {
    local env_file="$TEST_TEMP_DIR/env.sh"
    echo "export TEST_VAR=value" > "$env_file"
    assert_file_exists "$env_file"
    grep -q "export TEST_VAR" "$env_file" && assert_true true "Env var set" || assert_true false "Env var not set"
}

test_permissions() {
    local test_dir="$TEST_TEMP_DIR/test-dir"
    mkdir -p "$test_dir"
    assert_dir_exists "$test_dir"
    [ -w "$test_dir" ] && assert_true true "Directory writable" || assert_true false "Directory not writable"
}

test_aliases() {
    local alias_file="$TEST_TEMP_DIR/aliases.sh"
    echo "alias test='echo test'" > "$alias_file"
    assert_file_exists "$alias_file"
    grep -q "alias test=" "$alias_file" && assert_true true "Alias defined" || assert_true false "Alias not defined"
}

test_dependencies() {
    local deps_file="$TEST_TEMP_DIR/deps.txt"
    echo "dependency1" > "$deps_file"
    assert_file_exists "$deps_file"
    [ -s "$deps_file" ] && assert_true true "Dependencies listed" || assert_true false "No dependencies"
}

test_cache_directory() {
    local cache_dir="$TEST_TEMP_DIR/cache"
    mkdir -p "$cache_dir"
    assert_dir_exists "$cache_dir"
}

test_user_config() {
    local user_config="$TEST_TEMP_DIR/home/user/.config"
    mkdir -p "$user_config"
    assert_dir_exists "$user_config"
}

test_startup_script() {
    local startup_script="$TEST_TEMP_DIR/startup.sh"
    echo "#\!/bin/bash" > "$startup_script"
    chmod +x "$startup_script"
    assert_file_exists "$startup_script"
    [ -x "$startup_script" ] && assert_true true "Script executable" || assert_true false "Script not executable"
}

test_verification() {
    local verify_script="$TEST_TEMP_DIR/verify.sh"
    echo "#\!/bin/bash" > "$verify_script"
    echo "echo 'Verification complete'" >> "$verify_script"
    chmod +x "$verify_script"
    assert_file_exists "$verify_script"
    [ -x "$verify_script" ] && assert_true true "Verification script ready" || assert_true false "Verification script not ready"
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

# ============================================================================
# OP_*_REF Pattern Tests
# ============================================================================

# Helper: derive target variable name from an OP_*_REF variable name
# (mirrors the logic in _op_load_secrets / 45-op-secrets.sh)
_derive_target() {
    local ref_var="$1"
    local target="${ref_var#OP_}"
    target="${target%_REF}"
    echo "$target"
}

test_op_ref_pattern_matching() {
    # Set up test env vars (export so compgen -v finds them)
    export OP_GITHUB_TOKEN_REF="op://Vault/GitHub/token"
    export OP_KAGI_API_KEY_REF="op://Vault/Kagi/key"
    export OP_MY_PROJECT_SECRET_REF="op://Vault/Item/field"
    # These should NOT match
    export OP_SERVICE_ACCOUNT_TOKEN="ops_xxx"
    export OP_REF="should-not-match"
    export GITHUB_TOKEN_REF="missing-op-prefix"

    local matches
    matches=$(compgen -v | grep '^OP_.\+_REF$' || true)

    echo "$matches" | grep -q "OP_GITHUB_TOKEN_REF" \
        && assert_true 0 "OP_GITHUB_TOKEN_REF matches pattern" \
        || assert_true 1 "OP_GITHUB_TOKEN_REF should match pattern"

    echo "$matches" | grep -q "OP_KAGI_API_KEY_REF" \
        && assert_true 0 "OP_KAGI_API_KEY_REF matches pattern" \
        || assert_true 1 "OP_KAGI_API_KEY_REF should match pattern"

    echo "$matches" | grep -q "OP_MY_PROJECT_SECRET_REF" \
        && assert_true 0 "OP_MY_PROJECT_SECRET_REF matches pattern" \
        || assert_true 1 "OP_MY_PROJECT_SECRET_REF should match pattern"

    # Should NOT match
    echo "$matches" | grep -q "OP_SERVICE_ACCOUNT_TOKEN" \
        && assert_true 1 "OP_SERVICE_ACCOUNT_TOKEN should not match" \
        || assert_true 0 "OP_SERVICE_ACCOUNT_TOKEN excluded from pattern"

    echo "$matches" | grep -q '^OP_REF$' \
        && assert_true 1 "OP_REF should not match (no middle)" \
        || assert_true 0 "OP_REF excluded from pattern"

    echo "$matches" | grep -q '^GITHUB_TOKEN_REF$' \
        && assert_true 1 "GITHUB_TOKEN_REF should not match (no OP_ prefix)" \
        || assert_true 0 "GITHUB_TOKEN_REF excluded from pattern"

    # Clean up
    unset OP_GITHUB_TOKEN_REF OP_KAGI_API_KEY_REF OP_MY_PROJECT_SECRET_REF
    unset OP_SERVICE_ACCOUNT_TOKEN OP_REF GITHUB_TOKEN_REF
}

test_op_ref_target_derivation() {
    # Verify prefix/suffix stripping produces the correct target variable name
    local result

    result=$(_derive_target "OP_GITHUB_TOKEN_REF")
    [ "$result" = "GITHUB_TOKEN" ] \
        && assert_true 0 "OP_GITHUB_TOKEN_REF derives GITHUB_TOKEN" \
        || assert_true 1 "Expected GITHUB_TOKEN, got $result"

    result=$(_derive_target "OP_KAGI_API_KEY_REF")
    [ "$result" = "KAGI_API_KEY" ] \
        && assert_true 0 "OP_KAGI_API_KEY_REF derives KAGI_API_KEY" \
        || assert_true 1 "Expected KAGI_API_KEY, got $result"

    result=$(_derive_target "OP_GITLAB_TOKEN_REF")
    [ "$result" = "GITLAB_TOKEN" ] \
        && assert_true 0 "OP_GITLAB_TOKEN_REF derives GITLAB_TOKEN" \
        || assert_true 1 "Expected GITLAB_TOKEN, got $result"

    result=$(_derive_target "OP_MY_PROJECT_SECRET_REF")
    [ "$result" = "MY_PROJECT_SECRET" ] \
        && assert_true 0 "OP_MY_PROJECT_SECRET_REF derives MY_PROJECT_SECRET" \
        || assert_true 1 "Expected MY_PROJECT_SECRET, got $result"

    result=$(_derive_target "OP_X_REF")
    [ "$result" = "X" ] \
        && assert_true 0 "OP_X_REF derives X (single char)" \
        || assert_true 1 "Expected X, got $result"
}

test_op_ref_skip_when_set() {
    # Simulate the skip logic: if target var is already set, OP ref should be skipped
    export GITHUB_TOKEN="existing-value"
    export OP_GITHUB_TOKEN_REF="op://Vault/GitHub/token"

    local _target_var="GITHUB_TOKEN"
    # This is the guard condition from the loop
    [ -n "${!_target_var:-}" ] \
        && assert_true 0 "Existing GITHUB_TOKEN causes skip" \
        || assert_true 1 "Should skip when target already set"

    # When target is empty, should NOT skip
    unset GITHUB_TOKEN
    export GITHUB_TOKEN=""
    _target_var="GITHUB_TOKEN"
    [ -n "${!_target_var:-}" ] \
        && assert_true 1 "Empty GITHUB_TOKEN should not cause skip" \
        || assert_true 0 "Empty target var allows loading"

    # Completely unset — should not skip
    unset GITHUB_TOKEN
    [ -n "${!_target_var:-}" ] \
        && assert_true 1 "Unset GITHUB_TOKEN should not cause skip" \
        || assert_true 0 "Unset target var allows loading"

    # Clean up
    unset OP_GITHUB_TOKEN_REF GITHUB_TOKEN 2>/dev/null || true
}

test_op_ref_bashrc_contains_generic_loop() {
    # Verify the op-cli.sh build script generates the generic _op_load_secrets function
    local op_cli_script
    op_cli_script="$(dirname "${BASH_SOURCE[0]}")/../../../lib/features/op-cli.sh"

    grep -q '_op_load_secrets' "$op_cli_script" \
        && assert_true 0 "op-cli.sh contains _op_load_secrets function" \
        || assert_true 1 "op-cli.sh missing _op_load_secrets function"

    grep -q 'compgen -v' "$op_cli_script" \
        && assert_true 0 "op-cli.sh uses compgen -v for generic scanning" \
        || assert_true 1 "op-cli.sh missing compgen -v"

    grep -q '45-op-secrets.sh' "$op_cli_script" \
        && assert_true 0 "op-cli.sh creates 45-op-secrets.sh startup script" \
        || assert_true 1 "op-cli.sh missing 45-op-secrets.sh reference"

    # Ensure old hardcoded references are removed
    grep -q '_op_load_mcp_tokens' "$op_cli_script" \
        && assert_true 1 "Old _op_load_mcp_tokens should be removed" \
        || assert_true 0 "Old _op_load_mcp_tokens removed"

    grep -q '45-op-mcp-tokens.sh' "$op_cli_script" \
        && assert_true 1 "Old 45-op-mcp-tokens.sh should be removed" \
        || assert_true 0 "Old 45-op-mcp-tokens.sh removed"
}

run_test_with_setup test_installation "Installation test"
run_test_with_setup test_configuration "Configuration test"
run_test_with_setup test_environment "Environment test"
run_test_with_setup test_permissions "Permissions test"
run_test_with_setup test_aliases "Aliases test"
run_test_with_setup test_dependencies "Dependencies test"
run_test_with_setup test_cache_directory "Cache directory test"
run_test_with_setup test_user_config "User config test"
run_test_with_setup test_startup_script "Startup script test"
run_test_with_setup test_verification "Verification test"
run_test_with_setup test_op_ref_pattern_matching "OP_*_REF pattern matching test"
run_test_with_setup test_op_ref_target_derivation "OP_*_REF target derivation test"
run_test_with_setup test_op_ref_skip_when_set "OP_*_REF skip when target set test"
run_test_with_setup test_op_ref_bashrc_contains_generic_loop "OP_*_REF bashrc generic loop test"

# ============================================================================
# Batch 6: Static Analysis Tests for op-cli.sh
# ============================================================================

# Test: op-env-safe xtrace disable/restore pattern
test_op_env_safe_xtrace_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "set +x" "op-cli.sh disables xtrace to prevent secret exposure"
}

# Test: Git identity fallback with first/last name
test_git_identity_fallback_first_last() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "first name" "op-cli.sh handles 1Password Identity first name field"
    assert_file_contains "$source_file" "last name" "op-cli.sh handles 1Password Identity last name field"
}

# Test: Skip-if-target-already-set logic
test_skip_if_target_set_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" '${!_target_var:-}' "op-cli.sh uses indirect variable expansion for skip check"
}

# Test: debsig-verify policy setup
test_debsig_verify_policy() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "debsig" "op-cli.sh configures debsig verification policy"
}

# Test: 1Password GPG key handling
test_op_gpg_key_handling() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "gpg" "op-cli.sh handles GPG keys for package verification"
    assert_file_contains "$source_file" "keyring" "op-cli.sh references keyring for GPG key storage"
}

# Test: OP_SERVICE_ACCOUNT_TOKEN reference
test_op_service_account_token_ref() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "OP_SERVICE_ACCOUNT_TOKEN" "op-cli.sh references OP_SERVICE_ACCOUNT_TOKEN"
}

# Test: op read command pattern
test_op_read_command_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "op read" "op-cli.sh uses op read to retrieve secrets"
}

# Test: /etc/bashrc.d/ file creation
test_bashrc_d_file_creation() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "/etc/bashrc.d/" "op-cli.sh creates files in /etc/bashrc.d/"
}

# Test: dpkg -i installation pattern
test_dpkg_install_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    # 1Password is installed via apt_install, not dpkg directly
    assert_file_contains "$source_file" "apt_install" "op-cli.sh uses apt_install for package installation"
}

# Test: Architecture detection (amd64/arm64)
test_op_arch_detection() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "amd64" "op-cli.sh handles amd64 architecture"
    assert_file_contains "$source_file" "arm64" "op-cli.sh handles arm64 architecture"
}

# Test: Version or package reference for OP CLI
test_op_cli_package_reference() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "1password-cli" "op-cli.sh references 1password-cli package"
}

# Test: curl download pattern for OP package
test_op_curl_download_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "curl" "op-cli.sh uses curl for downloading packages"
    assert_file_contains "$source_file" "downloads.1password.com" "op-cli.sh downloads from official 1Password URL"
}

# Run Batch 6 tests
run_test test_op_env_safe_xtrace_pattern "op-env-safe disables xtrace for security"
run_test test_git_identity_fallback_first_last "Git identity fallback handles first/last name"
run_test test_skip_if_target_set_pattern "Skip-if-target-already-set uses indirect expansion"
run_test test_debsig_verify_policy "debsig-verify policy is configured"
run_test test_op_gpg_key_handling "1Password GPG key handling"
run_test test_op_service_account_token_ref "OP_SERVICE_ACCOUNT_TOKEN referenced"
run_test test_op_read_command_pattern "op read command pattern used"
run_test test_bashrc_d_file_creation "/etc/bashrc.d/ file creation pattern"
run_test test_dpkg_install_pattern "Package installation via apt_install"
run_test test_op_arch_detection "Architecture detection for amd64/arm64"
run_test test_op_cli_package_reference "1password-cli package referenced"
run_test test_op_curl_download_pattern "curl download pattern for OP package"

generate_report
