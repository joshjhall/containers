#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/gcp-secret-manager.sh
# Tests GCP Secret Manager integration functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "GCP Secret Manager Integration Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/gcp-secret-manager.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-gcp-secrets-$unique_id"
    mkdir -p "$TEST_TEMP_DIR/bin"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset GCP_SECRETS_ENABLED GCP_PROJECT_ID GCP_SECRET_PREFIX GCP_SECRET_NAMES \
          GCP_SECRET_VERSION GCP_SERVICE_ACCOUNT_KEY CLOUDSDK_CORE_PROJECT \
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
_run_gcp_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# Helper: create mock gcloud CLI
_create_mock_gcloud() {
    local project_id="${1:-test-project}"
    local exit_code="${2:-0}"

    command cat > "$TEST_TEMP_DIR/bin/gcloud" << MOCK
#!/bin/bash
if [[ "\$*" == *"config get-value project"* ]]; then
    echo "$project_id"
    exit 0
fi
if [[ "\$*" == *"auth list"* ]]; then
    echo "test@example.com"
    exit 0
fi
if [[ "\$*" == *"auth activate-service-account"* ]]; then
    exit $exit_code
fi
if [[ "\$*" == *"secrets list"* ]]; then
    echo "secret-one"
    echo "secret-two"
    exit $exit_code
fi
if [[ "\$*" == *"secrets versions access"* ]]; then
    echo "mock-secret-value"
    exit $exit_code
fi
if [[ "\$*" == *"secrets describe"* ]]; then
    echo '{"name":"test-secret"}'
    exit $exit_code
fi
exit $exit_code
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gcloud"
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_defines_load_secrets_from_gcp() {
    assert_file_contains "$SOURCE_FILE" "load_secrets_from_gcp()" \
        "Script defines load_secrets_from_gcp function"
}

test_defines_gcp_authenticate() {
    assert_file_contains "$SOURCE_FILE" "gcp_authenticate()" \
        "Script defines gcp_authenticate function"
}

test_defines_gcp_get_project_id() {
    assert_file_contains "$SOURCE_FILE" "gcp_get_project_id()" \
        "Script defines gcp_get_project_id function"
}

test_defines_health_check() {
    assert_file_contains "$SOURCE_FILE" "gcp_secrets_health_check()" \
        "Script defines gcp_secrets_health_check function"
}

test_metadata_server_fallback() {
    assert_file_contains "$SOURCE_FILE" "metadata.google.internal" \
        "Script tries GCE/GKE metadata server for project ID"
}

# ============================================================================
# Functional Tests - load_secrets_from_gcp()
# ============================================================================

test_disabled_when_not_enabled() {
    local exit_code=0
    _run_gcp_subshell "
        export GCP_SECRETS_ENABLED='false'
        load_secrets_from_gcp >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when disabled"
}

test_disabled_by_default() {
    local exit_code=0
    _run_gcp_subshell "
        unset GCP_SECRETS_ENABLED 2>/dev/null || true
        load_secrets_from_gcp >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should return 0 when not configured (default false)"
}

test_returns_error_when_gcloud_missing() {
    local exit_code=0
    _run_gcp_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export GCP_SECRETS_ENABLED='true'
        load_secrets_from_gcp >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when gcloud CLI not found"
}

test_project_id_from_env() {
    _create_mock_gcloud "test-project"

    local result
    result=$(_run_gcp_subshell "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        export GCP_PROJECT_ID='my-project'
        gcp_get_project_id
    ")

    assert_equals "my-project" "$result" "Should use GCP_PROJECT_ID from env"
}

test_project_id_from_gcloud_config() {
    _create_mock_gcloud "config-project"

    local result
    result=$(_run_gcp_subshell "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        unset GCP_PROJECT_ID 2>/dev/null || true
        gcp_get_project_id
    ")

    assert_equals "config-project" "$result" "Should get project ID from gcloud config"
}

test_project_id_missing_returns_error() {
    # Create mock gcloud that returns empty for project
    command cat > "$TEST_TEMP_DIR/bin/gcloud" << 'MOCK'
#!/bin/bash
if [[ "$*" == *"config get-value project"* ]]; then
    echo ""
    exit 0
fi
exit 1
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gcloud"

    local exit_code=0
    _run_gcp_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        unset GCP_PROJECT_ID 2>/dev/null || true
        gcp_get_project_id >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when project ID not found"
}

# ============================================================================
# Functional Tests - Secret Name Normalization
# ============================================================================

test_hyphens_to_underscores_in_source() {
    assert_file_contains "$SOURCE_FILE" 'secret_name//-/_' \
        "Script converts hyphens to underscores in secret names"
}

test_uppercase_conversion_in_source() {
    assert_file_contains "$SOURCE_FILE" 'env_var_name=.*Convert to uppercase' \
        "Script converts names to uppercase"
}

# ============================================================================
# Functional Tests - Authentication
# ============================================================================

test_service_account_key_validation() {
    local exit_code=0
    _run_gcp_subshell "
        export GCP_SERVICE_ACCOUNT_KEY='$TEST_TEMP_DIR/nonexistent-key.json'
        gcp_authenticate >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "2" "$exit_code" "Should return 2 for missing service account key"
}

test_auth_with_active_account() {
    _create_mock_gcloud "test-project"

    local exit_code=0
    _run_gcp_subshell "
        export PATH='$TEST_TEMP_DIR/bin:/usr/bin'
        unset GCP_SERVICE_ACCOUNT_KEY 2>/dev/null || true
        gcp_authenticate >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Should succeed with active gcloud account"
}

# ============================================================================
# Functional Tests - Health Check
# ============================================================================

test_health_check_when_disabled() {
    local exit_code=0
    _run_gcp_subshell "
        export GCP_SECRETS_ENABLED='false'
        gcp_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Health check should pass when disabled"
}

test_health_check_without_gcloud() {
    local exit_code=0
    _run_gcp_subshell "
        export PATH='$TEST_TEMP_DIR/bin'
        export GCP_SECRETS_ENABLED='true'
        gcp_secrets_health_check >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Health check should fail without gcloud"
}

# ============================================================================
# Functional Tests - Metadata Functions
# ============================================================================

test_get_secret_metadata_requires_name() {
    local exit_code=0
    _run_gcp_subshell "
        export GCP_SECRETS_ENABLED='true'
        gcp_get_secret_metadata '' >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when secret name empty"
}

test_list_versions_requires_name() {
    local exit_code=0
    _run_gcp_subshell "
        export GCP_SECRETS_ENABLED='true'
        gcp_list_secret_versions '' >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when secret name empty"
}

test_get_metadata_when_disabled() {
    local exit_code=0
    _run_gcp_subshell "
        export GCP_SECRETS_ENABLED='false'
        gcp_get_secret_metadata 'test' >/dev/null 2>&1
    " || exit_code=$?

    assert_equals "1" "$exit_code" "Should return 1 when GCP secrets disabled"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_load_secrets_from_gcp "Defines load_secrets_from_gcp function"
run_test_with_setup test_defines_gcp_authenticate "Defines gcp_authenticate function"
run_test_with_setup test_defines_gcp_get_project_id "Defines gcp_get_project_id function"
run_test_with_setup test_defines_health_check "Defines health check function"
run_test_with_setup test_metadata_server_fallback "Metadata server fallback for project ID"

# Main function
run_test_with_setup test_disabled_when_not_enabled "Disabled when GCP_SECRETS_ENABLED=false"
run_test_with_setup test_disabled_by_default "Disabled by default"
run_test_with_setup test_returns_error_when_gcloud_missing "Error when gcloud CLI missing"

# Project ID resolution
run_test_with_setup test_project_id_from_env "Project ID from environment"
run_test_with_setup test_project_id_from_gcloud_config "Project ID from gcloud config"
run_test_with_setup test_project_id_missing_returns_error "Error when project ID not found"

# Name normalization
run_test_with_setup test_hyphens_to_underscores_in_source "Hyphens converted to underscores"
run_test_with_setup test_uppercase_conversion_in_source "Names converted to uppercase"

# Authentication
run_test_with_setup test_service_account_key_validation "Service account key validation"
run_test_with_setup test_auth_with_active_account "Auth with active gcloud account"

# Health check
run_test_with_setup test_health_check_when_disabled "Health check passes when disabled"
run_test_with_setup test_health_check_without_gcloud "Health check fails without gcloud"

# Metadata functions
run_test_with_setup test_get_secret_metadata_requires_name "Get metadata requires name"
run_test_with_setup test_list_versions_requires_name "List versions requires name"
run_test_with_setup test_get_metadata_when_disabled "Get metadata fails when disabled"

# Generate test report
generate_report
