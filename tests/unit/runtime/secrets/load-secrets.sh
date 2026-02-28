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
# Functional Tests - validate_provider_name()
# ============================================================================

test_defines_validate_provider_name() {
    assert_file_contains "$SOURCE_FILE" "validate_provider_name()" \
        "Script defines validate_provider_name function"
}

test_validate_valid_provider_names() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name 'docker' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "0" "$exit_code" "docker is a valid provider name"

    exit_code=0
    _run_loader_subshell "
        validate_provider_name '1password' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "0" "$exit_code" "1password is a valid provider name"

    exit_code=0
    _run_loader_subshell "
        validate_provider_name 'aws-secrets' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "0" "$exit_code" "aws-secrets is a valid provider name"
}

test_validate_rejects_empty_name() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name '' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "1" "$exit_code" "Empty provider name is rejected"
}

test_validate_rejects_whitespace_only() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name '   ' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "1" "$exit_code" "Whitespace-only provider name is rejected"
}

test_validate_rejects_leading_trailing_whitespace() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name '  docker  ' >/dev/null 2>&1
    " || exit_code=$?
    # After trimming, 'docker' is valid — but the raw name contains spaces,
    # and trimming happens before the regex check. 'docker' passes [a-z0-9-].
    # The function trims first, then validates the trimmed result.
    assert_equals "0" "$exit_code" "Trimmed provider name passes validation"
}

test_validate_rejects_semicolon() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name 'docker;rm -rf /' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "1" "$exit_code" "Provider name with semicolon is rejected"
}

test_validate_rejects_dollar_sign() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name '\$(whoami)' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "1" "$exit_code" "Provider name with \$ is rejected"
}

test_validate_rejects_backtick() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name '\`id\`' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "1" "$exit_code" "Provider name with backtick is rejected"
}

test_validate_rejects_pipe() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name 'docker|command cat /etc/passwd' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "1" "$exit_code" "Provider name with pipe is rejected"
}

test_validate_rejects_uppercase() {
    local exit_code=0
    _run_loader_subshell "
        validate_provider_name 'Docker' >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "1" "$exit_code" "Provider name with uppercase is rejected"
}

test_invalid_provider_fails_load_all_secrets() {
    local exit_code=0
    _run_loader_subshell "
        export SECRET_LOADER_ENABLED='true'
        export SECRET_LOADER_FAIL_ON_ERROR='true'
        export SECRET_LOADER_PRIORITY='docker;\$(whoami)'

        load_all_secrets >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "2" "$exit_code" \
        "load_all_secrets returns 2 for invalid provider name with fail_on_error=true"
}

test_invalid_provider_skipped_without_fail_on_error() {
    local exit_code=0
    _run_loader_subshell "
        source_provider() { return 0; }
        load_secrets_from_docker() { return 0; }

        export SECRET_LOADER_ENABLED='true'
        export SECRET_LOADER_FAIL_ON_ERROR='false'
        export SECRET_LOADER_PRIORITY='docker;\$(whoami),docker'

        load_all_secrets >/dev/null 2>&1
    " || exit_code=$?
    assert_equals "0" "$exit_code" \
        "load_all_secrets skips invalid provider and continues when fail_on_error=false"
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

# Functional test: load_all_secrets returns exit code 2 when FAIL_ON_ERROR=true
# and a provider fails. Uses a mock provider function to simulate failure.
test_fail_on_error_returns_exit_code_2() {
    local exit_code=0
    _run_loader_subshell "
        # Override source_provider to prevent real provider scripts from
        # clobbering our mock function during load_all_secrets
        source_provider() { return 0; }

        # Define a mock docker provider that always fails
        load_secrets_from_docker() { return 1; }

        export SECRET_LOADER_ENABLED='true'
        export SECRET_LOADER_FAIL_ON_ERROR='true'
        export SECRET_LOADER_PRIORITY='docker'

        load_all_secrets >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" \
        "load_all_secrets returns exit code 2 when FAIL_ON_ERROR=true and provider fails"
}

# ============================================================================
# Functional Tests - check_all_providers_health()
# ============================================================================

test_check_all_providers_health_no_providers() {
    local exit_code=0
    _run_loader_subshell "
        # Mock source_provider to always fail (no providers available)
        source_provider() { return 1; }
        check_all_providers_health >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "check_all_providers_health returns 0 even with no providers"
}

test_check_all_providers_health_with_healthy_provider() {
    local exit_code=0
    _run_loader_subshell "
        # Mock source_provider: succeed only for docker
        source_provider() {
            [ \"\$1\" = 'docker' ] && return 0 || return 1
        }
        # Define a healthy docker provider
        docker_secrets_health_check() { return 0; }
        check_all_providers_health >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "check_all_providers_health returns 0 with healthy provider"
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

# Provider name validation
run_test_with_setup test_defines_validate_provider_name "Defines validate_provider_name function"
run_test_with_setup test_validate_valid_provider_names "Valid provider names pass validation"
run_test_with_setup test_validate_rejects_empty_name "Empty provider name rejected"
run_test_with_setup test_validate_rejects_whitespace_only "Whitespace-only provider name rejected"
run_test_with_setup test_validate_rejects_leading_trailing_whitespace "Trimmed provider name passes"
run_test_with_setup test_validate_rejects_semicolon "Semicolon in provider name rejected"
run_test_with_setup test_validate_rejects_dollar_sign "Dollar sign in provider name rejected"
run_test_with_setup test_validate_rejects_backtick "Backtick in provider name rejected"
run_test_with_setup test_validate_rejects_pipe "Pipe in provider name rejected"
run_test_with_setup test_validate_rejects_uppercase "Uppercase in provider name rejected"
run_test_with_setup test_invalid_provider_fails_load_all_secrets "Invalid provider fails load_all_secrets with fail_on_error"
run_test_with_setup test_invalid_provider_skipped_without_fail_on_error "Invalid provider skipped without fail_on_error"

# Fail on error
run_test_with_setup test_fail_on_error_documented "FAIL_ON_ERROR is documented"
run_test_with_setup test_fail_on_error_exit_code "FAIL_ON_ERROR returns exit code 2"
run_test_with_setup test_fail_on_error_returns_exit_code_2 "FAIL_ON_ERROR actually returns exit code 2"

# Health checks
run_test_with_setup test_check_all_providers_health_no_providers "check_all_providers_health with no providers"
run_test_with_setup test_check_all_providers_health_with_healthy_provider "check_all_providers_health with healthy provider"

# Generate test report
generate_report
