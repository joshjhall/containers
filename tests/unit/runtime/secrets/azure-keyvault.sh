#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/azure-keyvault.sh
# Tests Azure Key Vault integration functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Azure Key Vault Integration Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/azure-keyvault.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-azure-keyvault-$unique_id"
    mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset AZURE_KEYVAULT_ENABLED AZURE_KEYVAULT_NAME AZURE_KEYVAULT_URL \
          AZURE_SECRET_PREFIX AZURE_SECRET_NAMES AZURE_TENANT_ID \
          AZURE_CLIENT_ID AZURE_CLIENT_SECRET TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run subshell with source file loaded
_run_azure_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# Helper: create mock az CLI
_create_mock_az() {
    local exit_code="${1:-0}"

    command cat > "$TEST_TEMP_DIR/bin/az" << MOCK
#!/bin/bash
if [[ "\$*" == *"account show"* ]]; then
    echo '{"name":"test-subscription"}'
    exit $exit_code
fi
if [[ "\$*" == *"login"* ]]; then
    exit $exit_code
fi
if [[ "\$*" == *"keyvault secret list"* ]]; then
    echo '["secret-one","secret-two"]'
    exit $exit_code
fi
if [[ "\$*" == *"keyvault secret show"* ]]; then
    echo "mock-secret-value"
    exit $exit_code
fi
if [[ "\$*" == *"keyvault show"* ]]; then
    exit $exit_code
fi
if [[ "\$*" == *"keyvault certificate"* ]]; then
    exit $exit_code
fi
exit $exit_code
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/az"
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_defines_load_secrets_from_azure() {
    assert_file_contains "$SOURCE_FILE" "load_secrets_from_azure()" \
        "Script defines load_secrets_from_azure function"
}

test_defines_azure_check_authentication() {
    assert_file_contains "$SOURCE_FILE" "azure_check_authentication()" \
        "Script defines azure_check_authentication function"
}

test_defines_azure_login_service_principal() {
    assert_file_contains "$SOURCE_FILE" "azure_login_service_principal()" \
        "Script defines azure_login_service_principal function"
}

test_defines_health_check() {
    assert_file_contains "$SOURCE_FILE" "azure_keyvault_health_check()" \
        "Script defines azure_keyvault_health_check function"
}

test_defines_certificate_loader() {
    assert_file_contains "$SOURCE_FILE" "load_certificate_from_azure()" \
        "Script defines load_certificate_from_azure function"
}

test_vault_url_construction() {
    assert_file_contains "$SOURCE_FILE" ".vault.azure.net" \
        "Script constructs vault URL from name"
}

# ============================================================================
# Functional Tests - load_secrets_from_azure()
# ============================================================================

test_disabled_when_not_enabled() {
    local exit_code=0
    _run_azure_subshell "
        export AZURE_KEYVAULT_ENABLED='false'
        load_secrets_from_azure >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when disabled"
}

test_disabled_by_default() {
    local exit_code=0
    _run_azure_subshell "
        unset AZURE_KEYVAULT_ENABLED 2>/dev/null || true
        load_secrets_from_azure >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when not configured"
}

test_returns_error_when_vault_name_missing() {
    local exit_code=0
    _run_azure_subshell "
        export AZURE_KEYVAULT_ENABLED='true'
        unset AZURE_KEYVAULT_NAME 2>/dev/null || true
        unset AZURE_KEYVAULT_URL 2>/dev/null || true
        load_secrets_from_azure >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when vault name and URL both missing"
}

test_returns_error_when_az_cli_missing() {
    local exit_code=0
    _run_azure_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export AZURE_KEYVAULT_ENABLED='true'
        export AZURE_KEYVAULT_NAME='my-vault'
        load_secrets_from_azure >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when az CLI not found"
}

test_returns_error_when_jq_missing() {
    _create_mock_az 0
    local exit_code=0
    _run_azure_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export AZURE_KEYVAULT_ENABLED='true'
        export AZURE_KEYVAULT_NAME='my-vault'
        load_secrets_from_azure >/dev/null 2>&1
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" "Should return error when jq not found"
}

# ============================================================================
# Functional Tests - Authentication
# ============================================================================

test_service_principal_requires_all_three() {
    _create_mock_az 0

    # Missing AZURE_CLIENT_SECRET - should return 1 (not provided)
    local exit_code=0
    _run_azure_subshell "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        export AZURE_TENANT_ID='tenant-123'
        export AZURE_CLIENT_ID='client-123'
        unset AZURE_CLIENT_SECRET 2>/dev/null || true
        azure_login_service_principal >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Service principal login should return 1 when client secret missing"
}

test_service_principal_with_all_creds() {
    _create_mock_az 0

    local exit_code=0
    _run_azure_subshell "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        export AZURE_TENANT_ID='tenant-123'
        export AZURE_CLIENT_ID='client-123'
        export AZURE_CLIENT_SECRET='secret-123'
        azure_login_service_principal >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Service principal should succeed with all creds"
}

# ============================================================================
# Functional Tests - Health Check
# ============================================================================

test_health_check_when_disabled() {
    local exit_code=0
    _run_azure_subshell "
        export AZURE_KEYVAULT_ENABLED='false'
        azure_keyvault_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Health check should pass when disabled"
}

test_health_check_vault_name_missing() {
    local exit_code=0
    _run_azure_subshell "
        export AZURE_KEYVAULT_ENABLED='true'
        unset AZURE_KEYVAULT_NAME 2>/dev/null || true
        unset AZURE_KEYVAULT_URL 2>/dev/null || true
        azure_keyvault_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should fail when vault name missing"
}

test_health_check_without_az_cli() {
    local exit_code=0
    _run_azure_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export AZURE_KEYVAULT_ENABLED='true'
        export AZURE_KEYVAULT_NAME='my-vault'
        azure_keyvault_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should fail without az CLI"
}

# ============================================================================
# Functional Tests - Certificate Support
# ============================================================================

test_certificate_requires_name_and_path() {
    local exit_code=0
    _run_azure_subshell "
        export AZURE_KEYVAULT_ENABLED='true'
        load_certificate_from_azure '' '' >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Certificate loader should require name and path"
}

test_certificate_when_disabled() {
    local exit_code=0
    _run_azure_subshell "
        export AZURE_KEYVAULT_ENABLED='false'
        load_certificate_from_azure 'cert' '/tmp/cert.pem' >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Certificate loader should fail when disabled"
}

# ============================================================================
# Static Analysis - Name Normalization
# ============================================================================

test_hyphen_to_underscore_conversion() {
    assert_file_contains "$SOURCE_FILE" 'secret_name//-/_' \
        "Script converts hyphens to underscores"
}

test_uppercase_conversion() {
    assert_file_contains "$SOURCE_FILE" 'env_var_name=.*Convert to uppercase' \
        "Script converts names to uppercase"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_load_secrets_from_azure "Defines load_secrets_from_azure function"
run_test_with_setup test_defines_azure_check_authentication "Defines check authentication function"
run_test_with_setup test_defines_azure_login_service_principal "Defines service principal login"
run_test_with_setup test_defines_health_check "Defines health check function"
run_test_with_setup test_defines_certificate_loader "Defines certificate loader function"
run_test_with_setup test_vault_url_construction "Vault URL construction pattern"

# Main function
run_test_with_setup test_disabled_when_not_enabled "Disabled when not enabled"
run_test_with_setup test_disabled_by_default "Disabled by default"
run_test_with_setup test_returns_error_when_vault_name_missing "Error when vault name missing"
run_test_with_setup test_returns_error_when_az_cli_missing "Error when az CLI missing"
run_test_with_setup test_returns_error_when_jq_missing "Error when jq missing"

# Authentication
run_test_with_setup test_service_principal_requires_all_three "Service principal requires all creds"
run_test_with_setup test_service_principal_with_all_creds "Service principal succeeds with creds"

# Health check
run_test_with_setup test_health_check_when_disabled "Health check passes when disabled"
run_test_with_setup test_health_check_vault_name_missing "Health check fails when vault name missing"
run_test_with_setup test_health_check_without_az_cli "Health check fails without az CLI"

# Certificate support
run_test_with_setup test_certificate_requires_name_and_path "Certificate requires name and path"
run_test_with_setup test_certificate_when_disabled "Certificate fails when disabled"

# Name normalization
run_test_with_setup test_hyphen_to_underscore_conversion "Hyphens to underscores"
run_test_with_setup test_uppercase_conversion "Names to uppercase"

# Generate test report
generate_report
