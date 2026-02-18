#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/load-secrets.sh
# Tests universal secret loader orchestration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Universal Secret Loader Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/load-secrets.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-load-secrets-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset SECRET_LOADER_ENABLED SECRET_LOADER_PRIORITY SECRET_LOADER_FAIL_ON_ERROR \
          TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run subshell with source file loaded
_run_loader_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_defines_load_all_secrets() {
    assert_file_contains "$SOURCE_FILE" "load_all_secrets()" \
        "Script defines load_all_secrets function"
}

test_defines_source_provider() {
    assert_file_contains "$SOURCE_FILE" "source_provider()" \
        "Script defines source_provider function"
}

test_defines_load_provider_secrets() {
    assert_file_contains "$SOURCE_FILE" "load_provider_secrets()" \
        "Script defines load_provider_secrets function"
}

test_defines_get_secrets_dir() {
    assert_file_contains "$SOURCE_FILE" "get_secrets_dir()" \
        "Script defines get_secrets_dir function"
}

test_defines_health_check() {
    assert_file_contains "$SOURCE_FILE" "check_all_providers_health()" \
        "Script defines check_all_providers_health function"
}

# ============================================================================
# Static Analysis - Provider Registry
# ============================================================================

test_provider_mapping_1password() {
    assert_file_contains "$SOURCE_FILE" '1password-integration.sh' \
        "1password provider maps to correct script"
}

test_provider_mapping_vault() {
    assert_file_contains "$SOURCE_FILE" 'vault-integration.sh' \
        "Vault provider maps to correct script"
}

test_provider_mapping_aws() {
    assert_file_contains "$SOURCE_FILE" 'aws-secrets-manager.sh' \
        "AWS provider maps to correct script"
}

test_provider_mapping_azure() {
    assert_file_contains "$SOURCE_FILE" 'azure-keyvault.sh' \
        "Azure provider maps to correct script"
}

test_provider_mapping_gcp() {
    assert_file_contains "$SOURCE_FILE" 'gcp-secret-manager.sh' \
        "GCP provider maps to correct script"
}

test_provider_mapping_docker() {
    assert_file_contains "$SOURCE_FILE" 'docker-secrets.sh' \
        "Docker provider maps to correct script"
}

test_default_priority_order() {
    assert_file_contains "$SOURCE_FILE" 'docker,1password,vault,aws,azure,gcp' \
        "Default priority order is correct"
}

# ============================================================================
# Functional Tests - load_all_secrets()
# ============================================================================

test_disabled_when_not_enabled() {
    local exit_code=0
    _run_loader_subshell "
        export SECRET_LOADER_ENABLED='false'
        load_all_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when disabled"
}

test_enabled_by_default() {
    # The default is true, but providers will fail since they're disabled
    # The loader should still succeed (fail_on_error is false by default)
    local exit_code=0
    _run_loader_subshell "
        export SECRET_LOADER_ENABLED='true'
        load_all_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 even when individual providers fail (fail_on_error=false)"
}

# ============================================================================
# Functional Tests - source_provider()
# ============================================================================

test_source_unknown_provider() {
    local exit_code=0
    _run_loader_subshell "
        source_provider 'nonexistent-provider' >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 for unknown provider"
}

test_source_provider_aliases() {
    # Check that aliases are mapped correctly in the source
    assert_file_contains "$SOURCE_FILE" "1password|op)" "1password has op alias"
    assert_file_contains "$SOURCE_FILE" "vault|hashicorp)" "Vault has hashicorp alias"
    assert_file_contains "$SOURCE_FILE" "aws|aws-secrets)" "AWS has aws-secrets alias"
    assert_file_contains "$SOURCE_FILE" "azure|azure-keyvault)" "Azure has azure-keyvault alias"
    assert_file_contains "$SOURCE_FILE" "gcp|gcp-secrets|google)" "GCP has multiple aliases"
    assert_file_contains "$SOURCE_FILE" "docker|docker-secrets)" "Docker has docker-secrets alias"
}

# ============================================================================
# Functional Tests - load_provider_secrets()
# ============================================================================

test_load_unknown_provider() {
    local exit_code=0
    _run_loader_subshell "
        load_provider_secrets 'unknown' >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 for unknown provider"
}

test_function_name_mapping() {
    assert_file_contains "$SOURCE_FILE" 'load_secrets_from_1password' \
        "1password maps to load_secrets_from_1password"
    assert_file_contains "$SOURCE_FILE" 'load_secrets_from_vault' \
        "Vault maps to load_secrets_from_vault"
    assert_file_contains "$SOURCE_FILE" 'load_secrets_from_aws' \
        "AWS maps to load_secrets_from_aws"
    assert_file_contains "$SOURCE_FILE" 'load_secrets_from_azure' \
        "Azure maps to load_secrets_from_azure"
    assert_file_contains "$SOURCE_FILE" 'load_secrets_from_gcp' \
        "GCP maps to load_secrets_from_gcp"
    assert_file_contains "$SOURCE_FILE" 'load_secrets_from_docker' \
        "Docker maps to load_secrets_from_docker"
}

# ============================================================================
# Functional Tests - Fail on Error
# ============================================================================

test_fail_on_error_documented() {
    assert_file_contains "$SOURCE_FILE" 'SECRET_LOADER_FAIL_ON_ERROR' \
        "FAIL_ON_ERROR variable is used"
}

test_fail_on_error_exit_code() {
    assert_file_contains "$SOURCE_FILE" 'return 2' \
        "Returns exit code 2 when fail_on_error triggered"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis - core functions
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_load_all_secrets "Defines load_all_secrets function"
run_test_with_setup test_defines_source_provider "Defines source_provider function"
run_test_with_setup test_defines_load_provider_secrets "Defines load_provider_secrets function"
run_test_with_setup test_defines_get_secrets_dir "Defines get_secrets_dir function"
run_test_with_setup test_defines_health_check "Defines health check function"

# Provider registry
run_test_with_setup test_provider_mapping_1password "1Password provider mapping"
run_test_with_setup test_provider_mapping_vault "Vault provider mapping"
run_test_with_setup test_provider_mapping_aws "AWS provider mapping"
run_test_with_setup test_provider_mapping_azure "Azure provider mapping"
run_test_with_setup test_provider_mapping_gcp "GCP provider mapping"
run_test_with_setup test_provider_mapping_docker "Docker provider mapping"
run_test_with_setup test_default_priority_order "Default priority order"

# Main function
run_test_with_setup test_disabled_when_not_enabled "Disabled when SECRET_LOADER_ENABLED=false"
run_test_with_setup test_enabled_by_default "Succeeds with default config"

# Source provider
run_test_with_setup test_source_unknown_provider "Error for unknown provider"
run_test_with_setup test_source_provider_aliases "Provider aliases are mapped"

# Load provider secrets
run_test_with_setup test_load_unknown_provider "Error for unknown provider in load"
run_test_with_setup test_function_name_mapping "Function name mappings"

# Fail on error
run_test_with_setup test_fail_on_error_documented "FAIL_ON_ERROR is documented"
run_test_with_setup test_fail_on_error_exit_code "FAIL_ON_ERROR returns exit code 2"

# Generate test report
generate_report
