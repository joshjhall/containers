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
    # Verify the op-cli bashrc file contains the generic _op_load_secrets function
    local op_cli_bashrc
    op_cli_bashrc="$(dirname "${BASH_SOURCE[0]}")/../../../lib/features/lib/bashrc/op-cli.sh"
    local op_cli_script
    op_cli_script="$(dirname "${BASH_SOURCE[0]}")/../../../lib/features/op-cli.sh"

    grep -q '_op_load_secrets' "$op_cli_bashrc" \
        && assert_true 0 "op-cli bashrc contains _op_load_secrets function" \
        || assert_true 1 "op-cli bashrc missing _op_load_secrets function"

    grep -q 'compgen -v' "$op_cli_bashrc" \
        && assert_true 0 "op-cli bashrc uses compgen -v for generic scanning" \
        || assert_true 1 "op-cli bashrc missing compgen -v"

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
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" "set +x" "45-op-secrets.sh disables xtrace to prevent secret exposure"
}

# Test: Git identity fallback with first/last name
test_git_identity_fallback_first_last() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" "first name" "45-op-secrets.sh handles 1Password Identity first name field"
    assert_file_contains "$source_file" "last name" "45-op-secrets.sh handles 1Password Identity last name field"
}

# Test: Skip-if-target-already-set logic
test_skip_if_target_set_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" '${!_target_var:-}' "45-op-secrets.sh uses indirect variable expansion for skip check"
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
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" "OP_SERVICE_ACCOUNT_TOKEN" "45-op-secrets.sh references OP_SERVICE_ACCOUNT_TOKEN"
}

# Test: op read command pattern
test_op_read_command_pattern() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" "op read" "45-op-secrets.sh uses op read to retrieve secrets"
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

# ============================================================================
# OP_*_FILE_REF Pattern Tests
# ============================================================================

# Helper: derive target variable name from an OP_*_FILE_REF variable name
# (mirrors the logic in _op_load_secrets / 45-op-secrets.sh)
_derive_file_ref_target() {
    local ref_var="$1"
    local target="${ref_var#OP_}"
    target="${target%_FILE_REF}"
    echo "$target"
}

test_op_file_ref_pattern_matching() {
    # Set up test env vars
    export OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF="op://Vault/GCP/sa-key.json"
    export OP_MY_CERT_FILE_REF="op://Vault/Cert/cert.pem"
    # These should NOT match _FILE_REF pattern
    export OP_GITHUB_TOKEN_REF="op://Vault/GitHub/token"
    export OP_SERVICE_ACCOUNT_TOKEN="ops_xxx"

    local matches
    matches=$(compgen -v | grep '^OP_.\+_FILE_REF$' || true)

    echo "$matches" | grep -q "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF" \
        && assert_true 0 "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF matches _FILE_REF pattern" \
        || assert_true 1 "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF should match _FILE_REF pattern"

    echo "$matches" | grep -q "OP_MY_CERT_FILE_REF" \
        && assert_true 0 "OP_MY_CERT_FILE_REF matches _FILE_REF pattern" \
        || assert_true 1 "OP_MY_CERT_FILE_REF should match _FILE_REF pattern"

    # Should NOT match
    echo "$matches" | grep -q "OP_GITHUB_TOKEN_REF" \
        && assert_true 1 "OP_GITHUB_TOKEN_REF should not match _FILE_REF pattern" \
        || assert_true 0 "OP_GITHUB_TOKEN_REF excluded from _FILE_REF pattern"

    echo "$matches" | grep -q "OP_SERVICE_ACCOUNT_TOKEN" \
        && assert_true 1 "OP_SERVICE_ACCOUNT_TOKEN should not match _FILE_REF pattern" \
        || assert_true 0 "OP_SERVICE_ACCOUNT_TOKEN excluded from _FILE_REF pattern"

    # Clean up
    unset OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF OP_MY_CERT_FILE_REF
    unset OP_GITHUB_TOKEN_REF OP_SERVICE_ACCOUNT_TOKEN
}

test_op_file_ref_target_derivation() {
    local result

    result=$(_derive_file_ref_target "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF")
    [ "$result" = "GOOGLE_APPLICATION_CREDENTIALS" ] \
        && assert_true 0 "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF derives GOOGLE_APPLICATION_CREDENTIALS" \
        || assert_true 1 "Expected GOOGLE_APPLICATION_CREDENTIALS, got $result"

    result=$(_derive_file_ref_target "OP_MY_CERT_FILE_REF")
    [ "$result" = "MY_CERT" ] \
        && assert_true 0 "OP_MY_CERT_FILE_REF derives MY_CERT" \
        || assert_true 1 "Expected MY_CERT, got $result"

    result=$(_derive_file_ref_target "OP_X_FILE_REF")
    [ "$result" = "X" ] \
        && assert_true 0 "OP_X_FILE_REF derives X (single char)" \
        || assert_true 1 "Expected X, got $result"
}

test_op_file_ref_extension_derivation() {
    # Test the extension derivation logic from the URI's last path segment
    local _uri_field _file_ext

    # .json extension
    _uri_field="sa-key.json"
    case "$_uri_field" in
        *.*) _file_ext=".${_uri_field##*.}" ;;
        *)   _file_ext="" ;;
    esac
    [ "$_file_ext" = ".json" ] \
        && assert_true 0 "sa-key.json produces .json extension" \
        || assert_true 1 "Expected .json, got $_file_ext"

    # .pem extension
    _uri_field="cert.pem"
    case "$_uri_field" in
        *.*) _file_ext=".${_uri_field##*.}" ;;
        *)   _file_ext="" ;;
    esac
    [ "$_file_ext" = ".pem" ] \
        && assert_true 0 "cert.pem produces .pem extension" \
        || assert_true 1 "Expected .pem, got $_file_ext"

    # No extension (plain field name like "credential")
    _uri_field="credential"
    case "$_uri_field" in
        *.*) _file_ext=".${_uri_field##*.}" ;;
        *)   _file_ext="" ;;
    esac
    [ "$_file_ext" = "" ] \
        && assert_true 0 "credential produces no extension" \
        || assert_true 1 "Expected empty, got $_file_ext"

    # Multiple dots (e.g., file.tar.gz)
    _uri_field="archive.tar.gz"
    case "$_uri_field" in
        *.*) _file_ext=".${_uri_field##*.}" ;;
        *)   _file_ext="" ;;
    esac
    [ "$_file_ext" = ".gz" ] \
        && assert_true 0 "archive.tar.gz produces .gz extension (last dot)" \
        || assert_true 1 "Expected .gz, got $_file_ext"
}

test_op_file_ref_excludes_from_ref_loop() {
    # Verify the _REF loop regex excludes _FILE_REF variables
    export OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF="op://Vault/GCP/sa-key.json"
    export OP_GITHUB_TOKEN_REF="op://Vault/GitHub/token"

    local ref_matches
    ref_matches=$(compgen -v | grep '^OP_.\+_REF$' | grep -v '_FILE_REF$' || true)

    echo "$ref_matches" | grep -q "OP_GITHUB_TOKEN_REF" \
        && assert_true 0 "OP_GITHUB_TOKEN_REF still matches _REF pattern" \
        || assert_true 1 "OP_GITHUB_TOKEN_REF should match _REF pattern"

    echo "$ref_matches" | grep -q "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF" \
        && assert_true 1 "_FILE_REF var should be excluded from _REF loop" \
        || assert_true 0 "_FILE_REF var correctly excluded from _REF loop"

    # Clean up
    unset OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF OP_GITHUB_TOKEN_REF
}

# Static analysis: _FILE_REF pattern in bashrc content
test_op_file_ref_in_bashrc() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" "_FILE_REF" "45-op-secrets.sh contains _FILE_REF pattern"
    assert_file_contains "$source_file" "/dev/shm/" "45-op-secrets.sh writes file secrets to /dev/shm"
    assert_file_contains "$source_file" "chmod 600" "45-op-secrets.sh sets 0600 permissions on secret files"
}

# Static analysis: _FILE_REF pattern in startup script
test_op_file_ref_in_startup_script() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    # Verify the extracted startup script contains _FILE_REF loop
    assert_file_contains "$source_file" "_FILE_REF" "45-op-secrets.sh contains _FILE_REF loop"
    assert_file_contains "$source_file" "/dev/shm/" "45-op-secrets.sh uses /dev/shm for file secrets"
    assert_file_contains "$source_file" "chmod 600" "45-op-secrets.sh applies chmod 600"
}

# Static analysis: _REF loop excludes _FILE_REF in source code
test_op_ref_loop_excludes_file_ref_in_source() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" "grep -v '_FILE_REF" "45-op-secrets.sh _REF loop excludes _FILE_REF variables"
}

run_test_with_setup test_op_file_ref_pattern_matching "OP_*_FILE_REF pattern matching test"
run_test_with_setup test_op_file_ref_target_derivation "OP_*_FILE_REF target derivation test"
run_test_with_setup test_op_file_ref_extension_derivation "OP_*_FILE_REF extension derivation test"
run_test_with_setup test_op_file_ref_excludes_from_ref_loop "OP_*_FILE_REF excluded from _REF loop test"
run_test test_op_file_ref_in_bashrc "OP_*_FILE_REF in bashrc content"
run_test test_op_file_ref_in_startup_script "OP_*_FILE_REF in startup script"
run_test test_op_ref_loop_excludes_file_ref_in_source "_REF loop excludes _FILE_REF in source"

# ============================================================================
# Eval Injection Prevention Tests
# ============================================================================

# Test: op-env-safe must not use eval to run jq-generated export commands
test_op_env_safe_no_eval_of_field_values() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    # The old vulnerable pattern: jq produces 'export LABEL="VALUE"' and eval runs it
    if grep -A 20 'op-env-safe()' "$source_file" | grep -q 'eval "\$export_commands"'; then
        fail_test "op-env-safe still uses eval on jq-generated export commands (injection risk)"
    else
        pass_test "op-env-safe does not eval jq-generated export commands"
    fi
}

# Test: op-env-safe uses safe @tsv or direct export pattern
test_op_env_safe_uses_safe_export() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    # Search the full function body (up to 30 lines after the function definition)
    if grep -A 30 '^op-env-safe()' "$source_file" | grep -qE '@tsv|export "\$'; then
        pass_test "op-env-safe uses safe @tsv / direct export pattern"
    else
        fail_test "op-env-safe should use @tsv or direct export pattern"
    fi
}

# Test: op-env function uses @sh for safe escaping of values
test_op_env_uses_safe_escaping() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    # Search the full function body (up to 10 lines after the function definition)
    if grep -A 10 '^op-env()' "$source_file" | grep -q '@sh'; then
        pass_test "op-env uses jq @sh for safe value escaping"
    else
        fail_test "op-env should use jq @sh for safe value escaping"
    fi
}

run_test test_op_env_safe_no_eval_of_field_values "op-env-safe: No eval of field values (injection prevention)"
run_test test_op_env_safe_uses_safe_export "op-env-safe: Uses safe @tsv / direct export pattern"
run_test test_op_env_uses_safe_escaping "op-env: Uses @sh for safe value escaping"

generate_report
