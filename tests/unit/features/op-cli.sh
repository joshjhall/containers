#!/usr/bin/env bash
# Unit tests for lib/features/op-cli.sh
# Content-based tests + functional tests for OP_*_REF patterns

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

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/op-cli.sh"

# ============================================================================
# Script Structure Tests (content-based, no setup needed)
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] \
        && assert_true 0 "op-cli.sh is executable" \
        || assert_true 1 "op-cli.sh should be executable"
}

test_uses_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "op-cli.sh uses strict mode"
}

test_sources_feature_header_bootstrap() {
    assert_file_contains "$SOURCE_FILE" "source.*feature-header-bootstrap.sh" \
        "op-cli.sh sources feature-header-bootstrap.sh"
}

test_log_feature_start() {
    assert_file_contains "$SOURCE_FILE" 'log_feature_start "1Password CLI"' \
        "op-cli.sh logs feature start with correct name"
}

test_sources_apt_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*apt-utils.sh" \
        "op-cli.sh sources apt-utils.sh"
}

test_sources_retry_utils() {
    assert_file_contains "$SOURCE_FILE" "source.*retry-utils.sh" \
        "op-cli.sh sources retry-utils.sh"
}

test_gpg_debsig_verification() {
    assert_file_contains "$SOURCE_FILE" "gpg" \
        "op-cli.sh handles GPG keys"
    assert_file_contains "$SOURCE_FILE" "debsig" \
        "op-cli.sh configures debsig verification"
}

test_architecture_detection() {
    assert_file_contains "$SOURCE_FILE" "amd64" \
        "op-cli.sh handles amd64 architecture"
    assert_file_contains "$SOURCE_FILE" "arm64" \
        "op-cli.sh handles arm64 architecture"
}

test_package_reference() {
    assert_file_contains "$SOURCE_FILE" "1password-cli" \
        "op-cli.sh references 1password-cli package"
}

test_bashrc_file_creation() {
    assert_file_contains "$SOURCE_FILE" "65-env-secrets.sh" \
        "op-cli.sh installs 65-env-secrets.sh"
    assert_file_contains "$SOURCE_FILE" "66-op-secrets-cache.sh" \
        "op-cli.sh installs 66-op-secrets-cache.sh"
    assert_file_contains "$SOURCE_FILE" "70-1password.sh" \
        "op-cli.sh installs 70-1password.sh"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_strict_mode "Uses set -euo pipefail"
run_test test_sources_feature_header_bootstrap "Sources feature-header-bootstrap.sh"
run_test test_log_feature_start "Logs feature start with correct name"
run_test test_sources_apt_utils "Sources apt-utils.sh"
run_test test_sources_retry_utils "Sources retry-utils.sh"
run_test test_gpg_debsig_verification "GPG/debsig verification patterns"
run_test test_architecture_detection "Architecture detection (amd64, arm64)"
run_test test_package_reference "Package reference (1password-cli)"
run_test test_bashrc_file_creation "Bashrc file creation (65/66/70)"

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
    matches=$(compgen -v | command grep '^OP_.\+_REF$' || true)

    echo "$matches" | command grep -q "OP_GITHUB_TOKEN_REF" \
        && assert_true 0 "OP_GITHUB_TOKEN_REF matches pattern" \
        || assert_true 1 "OP_GITHUB_TOKEN_REF should match pattern"

    echo "$matches" | command grep -q "OP_KAGI_API_KEY_REF" \
        && assert_true 0 "OP_KAGI_API_KEY_REF matches pattern" \
        || assert_true 1 "OP_KAGI_API_KEY_REF should match pattern"

    echo "$matches" | command grep -q "OP_MY_PROJECT_SECRET_REF" \
        && assert_true 0 "OP_MY_PROJECT_SECRET_REF matches pattern" \
        || assert_true 1 "OP_MY_PROJECT_SECRET_REF should match pattern"

    # Should NOT match
    echo "$matches" | command grep -q "OP_SERVICE_ACCOUNT_TOKEN" \
        && assert_true 1 "OP_SERVICE_ACCOUNT_TOKEN should not match" \
        || assert_true 0 "OP_SERVICE_ACCOUNT_TOKEN excluded from pattern"

    echo "$matches" | command grep -q '^OP_REF$' \
        && assert_true 1 "OP_REF should not match (no middle)" \
        || assert_true 0 "OP_REF excluded from pattern"

    echo "$matches" | command grep -q '^GITHUB_TOKEN_REF$' \
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

    command grep -q '_op_load_secrets' "$op_cli_bashrc" \
        && assert_true 0 "op-cli bashrc contains _op_load_secrets function" \
        || assert_true 1 "op-cli bashrc missing _op_load_secrets function"

    command grep -q 'compgen -v' "$op_cli_bashrc" \
        && assert_true 0 "op-cli bashrc uses compgen -v for generic scanning" \
        || assert_true 1 "op-cli bashrc missing compgen -v"

    command grep -q '45-op-secrets.sh' "$op_cli_script" \
        && assert_true 0 "op-cli.sh creates 45-op-secrets.sh startup script" \
        || assert_true 1 "op-cli.sh missing 45-op-secrets.sh reference"

    # Ensure old hardcoded references are removed
    command grep -q '_op_load_mcp_tokens' "$op_cli_script" \
        && assert_true 1 "Old _op_load_mcp_tokens should be removed" \
        || assert_true 0 "Old _op_load_mcp_tokens removed"

    command grep -q '45-op-mcp-tokens.sh' "$op_cli_script" \
        && assert_true 1 "Old 45-op-mcp-tokens.sh should be removed" \
        || assert_true 0 "Old 45-op-mcp-tokens.sh removed"
}

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
    matches=$(compgen -v | command grep '^OP_.\+_FILE_REF$' || true)

    echo "$matches" | command grep -q "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF" \
        && assert_true 0 "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF matches _FILE_REF pattern" \
        || assert_true 1 "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF should match _FILE_REF pattern"

    echo "$matches" | command grep -q "OP_MY_CERT_FILE_REF" \
        && assert_true 0 "OP_MY_CERT_FILE_REF matches _FILE_REF pattern" \
        || assert_true 1 "OP_MY_CERT_FILE_REF should match _FILE_REF pattern"

    # Should NOT match
    echo "$matches" | command grep -q "OP_GITHUB_TOKEN_REF" \
        && assert_true 1 "OP_GITHUB_TOKEN_REF should not match _FILE_REF pattern" \
        || assert_true 0 "OP_GITHUB_TOKEN_REF excluded from _FILE_REF pattern"

    echo "$matches" | command grep -q "OP_SERVICE_ACCOUNT_TOKEN" \
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
    ref_matches=$(compgen -v | command grep '^OP_.\+_REF$' | command grep -v '_FILE_REF$' || true)

    echo "$ref_matches" | command grep -q "OP_GITHUB_TOKEN_REF" \
        && assert_true 0 "OP_GITHUB_TOKEN_REF still matches _REF pattern" \
        || assert_true 1 "OP_GITHUB_TOKEN_REF should match _REF pattern"

    echo "$ref_matches" | command grep -q "OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF" \
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
    if command grep -A 20 'op-env-safe()' "$source_file" | command grep -q 'eval "\$export_commands"'; then
        fail_test "op-env-safe still uses eval on jq-generated export commands (injection risk)"
    else
        pass_test "op-env-safe does not eval jq-generated export commands"
    fi
}

# Test: op-env-safe uses safe @tsv or direct export pattern
test_op_env_safe_uses_safe_export() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    # Search the full function body (up to 30 lines after the function definition)
    if command grep -A 30 '^op-env-safe()' "$source_file" | command grep -qE '@tsv|export "\$'; then
        pass_test "op-env-safe uses safe @tsv / direct export pattern"
    else
        fail_test "op-env-safe should use @tsv or direct export pattern"
    fi
}

# Test: op-env function uses @sh for safe escaping of values
test_op_env_uses_safe_escaping() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    # Search the full function body (up to 10 lines after the function definition)
    if command grep -A 10 '^op-env()' "$source_file" | command grep -q '@sh'; then
        pass_test "op-env uses jq @sh for safe value escaping"
    else
        fail_test "op-env should use jq @sh for safe value escaping"
    fi
}

run_test test_op_env_safe_no_eval_of_field_values "op-env-safe: No eval of field values (injection prevention)"
run_test test_op_env_safe_uses_safe_export "op-env-safe: Uses safe @tsv / direct export pattern"
run_test test_op_env_uses_safe_escaping "op-env: Uses @sh for safe value escaping"

# ============================================================================
# .env.secrets Loader Tests
# ============================================================================

# Static: 65-env-secrets.sh is referenced in op-cli.sh
test_env_secrets_referenced_in_op_cli() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "65-env-secrets.sh" "op-cli.sh installs 65-env-secrets.sh"
}

# Static: env-secrets.sh contains ENV_SECRETS_FILE check
test_env_secrets_has_env_secrets_file_check() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/env-secrets.sh"
    assert_file_contains "$source_file" "ENV_SECRETS_FILE" "env-secrets.sh checks ENV_SECRETS_FILE"
}

# Static: env-secrets.sh checks $HOME/.env.secrets
test_env_secrets_checks_home() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/env-secrets.sh"
    assert_file_contains "$source_file" 'HOME.*\.env\.secrets' "env-secrets.sh checks \$HOME/.env.secrets"
}

# Static: env-secrets.sh checks $PWD/.env.secrets
test_env_secrets_checks_pwd() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/env-secrets.sh"
    assert_file_contains "$source_file" 'PWD.*\.env\.secrets' "env-secrets.sh checks \$PWD/.env.secrets"
}

# Static: env-secrets.sh contains _ENV_SECRETS_LOADED guard
test_env_secrets_has_idempotency_guard() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/env-secrets.sh"
    assert_file_contains "$source_file" "_ENV_SECRETS_LOADED" "env-secrets.sh has _ENV_SECRETS_LOADED idempotency guard"
}

# Static: env-secrets.sh disables xtrace
test_env_secrets_disables_xtrace() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/env-secrets.sh"
    assert_file_contains "$source_file" "set +x" "env-secrets.sh disables xtrace to prevent token exposure"
}

# Static: 45-op-secrets.sh sources .env.secrets before OP_SERVICE_ACCOUNT_TOKEN check
test_env_secrets_in_startup_before_op_check() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    # .env.secrets sourcing must appear before the OP_SERVICE_ACCOUNT_TOKEN guard
    # (skip comment lines — only match the actual code check)
    local secrets_line op_token_line
    secrets_line=$(command grep -n '\.env\.secrets' "$source_file" | command head -1 | command cut -d: -f1)
    op_token_line=$(command grep -n '^\[.*OP_SERVICE_ACCOUNT_TOKEN' "$source_file" | command head -1 | command cut -d: -f1)
    if [ -n "$secrets_line" ] && [ -n "$op_token_line" ] && [ "$secrets_line" -lt "$op_token_line" ]; then
        assert_true 0 "45-op-secrets.sh sources .env.secrets before OP_SERVICE_ACCOUNT_TOKEN check"
    else
        assert_true 1 "45-op-secrets.sh must source .env.secrets before OP_SERVICE_ACCOUNT_TOKEN check"
    fi
}

# Static: env-secrets.sh uses set -a / set +a for auto-export
test_env_secrets_uses_auto_export() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/env-secrets.sh"
    assert_file_contains "$source_file" "set -a" "env-secrets.sh uses set -a for auto-export"
    assert_file_contains "$source_file" "set +a" "env-secrets.sh uses set +a to restore"
}

# Functional: sourcing a test .env.secrets file exports variables correctly
test_env_secrets_functional_sourcing() {
    local test_dir="$TEST_TEMP_DIR/env-secrets-test"
    mkdir -p "$test_dir"

    # Create a test .env.secrets file
    echo 'TEST_SECRET_VAR=hello_from_secrets' > "$test_dir/.env.secrets"
    echo 'ANOTHER_SECRET=world' >> "$test_dir/.env.secrets"

    # Simulate what the loader does: set -a, source, set +a
    (
        set -a
        . "$test_dir/.env.secrets"
        set +a
        [ "$TEST_SECRET_VAR" = "hello_from_secrets" ] && exit 0 || exit 1
    )
    assert_true $? "Sourcing .env.secrets with set -a exports TEST_SECRET_VAR"

    (
        set -a
        . "$test_dir/.env.secrets"
        set +a
        [ "$ANOTHER_SECRET" = "world" ] && exit 0 || exit 1
    )
    assert_true $? "Sourcing .env.secrets with set -a exports ANOTHER_SECRET"
}

run_test test_env_secrets_referenced_in_op_cli "env-secrets: 65-env-secrets.sh referenced in op-cli.sh"
run_test test_env_secrets_has_env_secrets_file_check "env-secrets: ENV_SECRETS_FILE check present"
run_test test_env_secrets_checks_home "env-secrets: \$HOME/.env.secrets check present"
run_test test_env_secrets_checks_pwd "env-secrets: \$PWD/.env.secrets check present"
run_test test_env_secrets_has_idempotency_guard "env-secrets: _ENV_SECRETS_LOADED idempotency guard"
run_test test_env_secrets_disables_xtrace "env-secrets: xtrace disabled during sourcing"
run_test test_env_secrets_in_startup_before_op_check "env-secrets: startup script sources before OP token check"
run_test test_env_secrets_uses_auto_export "env-secrets: uses set -a / set +a for auto-export"
run_test_with_setup test_env_secrets_functional_sourcing "env-secrets: functional sourcing exports variables"

# Static: 45-op-secrets.sh has /workspace fallback search
test_env_secrets_startup_has_workspace_fallback() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" '/workspace/\*/' "45-op-secrets.sh has /workspace fallback search"
}

# Static: env-secrets.sh has /workspace fallback search
test_env_secrets_bashrc_has_workspace_fallback() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/env-secrets.sh"
    assert_file_contains "$source_file" '/workspace/\*/' "env-secrets.sh has /workspace fallback search"
}

run_test test_env_secrets_startup_has_workspace_fallback "env-secrets: startup script has /workspace fallback"
run_test test_env_secrets_bashrc_has_workspace_fallback "env-secrets: bashrc script has /workspace fallback"

# ============================================================================
# Secret Cache Tests
# ============================================================================

# Static: bashrc references op-secrets-cache
test_cache_bashrc_references_cache_file() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    assert_file_contains "$source_file" "op-secrets-cache" "bashrc op-cli.sh references op-secrets-cache"
}

# Static: 45-op-secrets.sh writes cache
test_cache_startup_writes_cache() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$source_file" "op-secrets-cache" "45-op-secrets.sh writes op-secrets-cache"
}

# Static: cache has chmod 600
test_cache_permissions_bashrc() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    # The _op_write_cache function must set 0600 on the cache file
    if command grep -A 30 '_op_write_cache()' "$source_file" | command grep -q 'chmod 600'; then
        pass_test "bashrc _op_write_cache sets chmod 600 on cache"
    else
        fail_test "bashrc _op_write_cache should set chmod 600 on cache"
    fi
}

test_cache_permissions_startup() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    # The cache write block must include chmod 600 on _cache_tmp
    if command grep -q 'chmod 600 "\$_cache_tmp"' "$source_file"; then
        pass_test "45-op-secrets.sh sets chmod 600 on cache"
    else
        fail_test "45-op-secrets.sh should set chmod 600 on cache"
    fi
}

# Static: cache read checks ownership (-O)
test_cache_ownership_check() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    if command grep -Fq '[ -O ' "$source_file"; then
        pass_test "bashrc checks cache file ownership with -O"
    else
        fail_test "bashrc should check cache file ownership with -O"
    fi
}

# Static: atomic write pattern (.tmp + mv)
test_cache_atomic_write_bashrc() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    if command grep -Fq '.tmp.$$' "$source_file"; then
        pass_test "bashrc uses .tmp.\$\$ for atomic cache write"
    else
        fail_test "bashrc should use .tmp.\$\$ for atomic cache write"
    fi
    if command grep -A 30 '_op_write_cache()' "$source_file" | command grep -q 'mv .*_cache_tmp.*_OP_SECRETS_CACHE'; then
        pass_test "bashrc _op_write_cache uses mv for atomic rename"
    else
        fail_test "bashrc _op_write_cache should use mv for atomic rename"
    fi
}

test_cache_atomic_write_startup() {
    local source_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    if command grep -Fq '.tmp.$$' "$source_file"; then
        pass_test "45-op-secrets.sh uses .tmp.\$\$ for atomic cache write"
    else
        fail_test "45-op-secrets.sh should use .tmp.\$\$ for atomic cache write"
    fi
    if command grep -q 'mv .*_cache_tmp.*_cache_file' "$source_file"; then
        pass_test "45-op-secrets.sh uses mv for atomic rename"
    else
        fail_test "45-op-secrets.sh should use mv for atomic rename"
    fi
}

# Functional: printf '%q' escapes values with special characters
test_cache_printf_q_escaping() {
    local val_with_spaces="hello world"
    local val_with_quotes='say "hi"'
    local val_with_dollar='cost=$100'
    local val_with_newline=$'line1\nline2'

    local escaped
    escaped=$(printf '%q' "$val_with_spaces")
    [ "$escaped" != "$val_with_spaces" ] \
        && assert_true 0 "printf %q escapes spaces" \
        || assert_true 1 "printf %q should escape spaces"

    escaped=$(printf '%q' "$val_with_quotes")
    [ "$escaped" != "$val_with_quotes" ] \
        && assert_true 0 "printf %q escapes quotes" \
        || assert_true 1 "printf %q should escape quotes"

    escaped=$(printf '%q' "$val_with_dollar")
    [ "$escaped" != "$val_with_dollar" ] \
        && assert_true 0 "printf %q escapes dollar signs" \
        || assert_true 1 "printf %q should escape dollar signs"

    escaped=$(printf '%q' "$val_with_newline")
    [ "$escaped" != "$val_with_newline" ] \
        && assert_true 0 "printf %q escapes newlines" \
        || assert_true 1 "printf %q should escape newlines"
}

# Functional: sourcing a mock cache file exports variables
test_cache_functional_sourcing() {
    local test_cache="$TEST_TEMP_DIR/mock-op-secrets-cache"

    # Build a mock cache using the same printf '%q' pattern
    {
        printf 'export %s=%q\n' "MOCK_TOKEN" "abc123"
        printf 'export %s=%q\n' "MOCK_SPECIAL" 'val with "quotes" and $dollar'
        printf 'export %s=%q\n' "GIT_USER_NAME" "Test User"
        printf 'export %s=%q\n' "GIT_USER_EMAIL" "test@example.com"
    } > "$test_cache"
    chmod 600 "$test_cache"

    # Source in a subshell and verify exports
    (
        . "$test_cache"
        [ "$MOCK_TOKEN" = "abc123" ] || exit 1
        [ "$MOCK_SPECIAL" = 'val with "quotes" and $dollar' ] || exit 2
        [ "$GIT_USER_NAME" = "Test User" ] || exit 3
        [ "$GIT_USER_EMAIL" = "test@example.com" ] || exit 4
        exit 0
    )
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        pass_test "Sourcing mock cache correctly exports all variables"
    else
        fail_test "Sourcing mock cache failed (exit code $rc)"
    fi
}

# Static: bashrc _op_resolve_git_identity has early return when both vars set
test_cache_git_identity_early_return() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    if command grep -A 10 '_op_resolve_git_identity()' "$source_file" | command grep -q 'GIT_USER_NAME.*GIT_USER_EMAIL'; then
        pass_test "bashrc _op_resolve_git_identity has early return for cached vars"
    else
        fail_test "bashrc _op_resolve_git_identity should check both GIT_USER_NAME and GIT_USER_EMAIL"
    fi
}

# Static: cache file path is in /dev/shm (tmpfs, cleared on restart)
test_cache_uses_dev_shm() {
    local bashrc_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-cli.sh"
    local startup_file="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"
    assert_file_contains "$bashrc_file" '/dev/shm/op-secrets-cache' "bashrc cache path is /dev/shm/op-secrets-cache"
    assert_file_contains "$startup_file" '/dev/shm/op-secrets-cache' "startup cache path is /dev/shm/op-secrets-cache"
}

run_test test_cache_bashrc_references_cache_file "Cache: bashrc references op-secrets-cache"
run_test test_cache_startup_writes_cache "Cache: 45-op-secrets.sh writes cache"
run_test test_cache_permissions_bashrc "Cache: bashrc sets chmod 600"
run_test test_cache_permissions_startup "Cache: startup sets chmod 600"
run_test test_cache_ownership_check "Cache: bashrc checks ownership with -O"
run_test test_cache_atomic_write_bashrc "Cache: bashrc atomic write (.tmp + mv)"
run_test test_cache_atomic_write_startup "Cache: startup atomic write (.tmp + mv)"
run_test_with_setup test_cache_printf_q_escaping "Cache: printf %q escapes special characters"
run_test_with_setup test_cache_functional_sourcing "Cache: sourcing mock cache exports variables"
run_test test_cache_git_identity_early_return "Cache: git identity early return when cached"
run_test test_cache_uses_dev_shm "Cache: uses /dev/shm (tmpfs)"

# ============================================================================
# OP Secrets Cache Loader (66-op-secrets-cache.sh) Tests
# ============================================================================

# Static: op-secrets-cache.sh source file exists
test_op_secrets_cache_file_exists() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-secrets-cache.sh"
    assert_file_exists "$source_file"
}

# Static: op-secrets-cache.sh does NOT have interactive-shell guard
test_op_secrets_cache_no_interactive_guard() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-secrets-cache.sh"
    if command grep -q '\$- != \*i\*' "$source_file" || command grep -q 'if \[\[ \$-' "$source_file"; then
        fail_test "op-secrets-cache.sh must NOT have interactive-shell guard"
    else
        pass_test "op-secrets-cache.sh has no interactive-shell guard (loads in all shells)"
    fi
}

# Static: op-secrets-cache.sh checks file ownership with -O
test_op_secrets_cache_ownership_check() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-secrets-cache.sh"
    if command grep -Fq '[ -O ' "$source_file" || command grep -Fq '[ -O "' "$source_file"; then
        pass_test "op-secrets-cache.sh checks file ownership with -O"
    else
        fail_test "op-secrets-cache.sh should check file ownership with -O"
    fi
}

# Static: op-secrets-cache.sh disables xtrace before sourcing
test_op_secrets_cache_disables_xtrace() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-secrets-cache.sh"
    assert_file_contains "$source_file" "set +x" "op-secrets-cache.sh disables xtrace before sourcing cache"
}

# Static: op-cli.sh installs 66-op-secrets-cache.sh
test_op_secrets_cache_installed_by_op_cli() {
    local source_file="$PROJECT_ROOT/lib/features/op-cli.sh"
    assert_file_contains "$source_file" "66-op-secrets-cache.sh" "op-cli.sh installs 66-op-secrets-cache.sh"
}

# Static: op-secrets-cache.sh references the correct cache path
test_op_secrets_cache_correct_path() {
    local source_file="$PROJECT_ROOT/lib/features/lib/bashrc/op-secrets-cache.sh"
    assert_file_contains "$source_file" "/dev/shm/op-secrets-cache" "op-secrets-cache.sh uses /dev/shm/op-secrets-cache path"
}

run_test test_op_secrets_cache_file_exists "OP secrets cache: source file exists"
run_test test_op_secrets_cache_no_interactive_guard "OP secrets cache: no interactive-shell guard"
run_test test_op_secrets_cache_ownership_check "OP secrets cache: checks file ownership with -O"
run_test test_op_secrets_cache_disables_xtrace "OP secrets cache: disables xtrace"
run_test test_op_secrets_cache_installed_by_op_cli "OP secrets cache: installed by op-cli.sh"
run_test test_op_secrets_cache_correct_path "OP secrets cache: correct cache path"

generate_report
