#!/usr/bin/env bash
# Unit tests for configuration validation framework
#
# Tests the validation functions in lib/runtime/validate-config.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Configuration Validation Framework"

# Source the validation framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/runtime/validate-config.sh"

# Disable validation auto-run for testing
export VALIDATE_CONFIG=false

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    # Reset counters (these are global in validate-config.sh)
    CV_ERROR_COUNT=0
    CV_WARNING_COUNT=0

    # Truncate error/warning files
    if [ -n "${CV_ERRORS_FILE:-}" ] && [ -f "$CV_ERRORS_FILE" ]; then
        : > "$CV_ERRORS_FILE"
    fi
    if [ -n "${CV_WARNINGS_FILE:-}" ] && [ -f "$CV_WARNINGS_FILE" ]; then
        : > "$CV_WARNINGS_FILE"
    fi

    # Clear test environment variables
    unset TEST_VAR 2>/dev/null || true
    unset TEST_URL 2>/dev/null || true
    unset TEST_PATH 2>/dev/null || true
    unset TEST_PORT 2>/dev/null || true
    unset TEST_EMAIL 2>/dev/null || true
    unset TEST_BOOL 2>/dev/null || true
    unset TEST_SECRET 2>/dev/null || true
    unset API_KEY 2>/dev/null || true
    unset NORMAL_VAR 2>/dev/null || true
}

teardown() {
    # Clean up test variables
    setup
}

# ============================================================================
# Required Variable Tests
# ============================================================================

test_require_var_set() {
    export TEST_VAR="value"

    if cv_require_var TEST_VAR "Test variable" "Set TEST_VAR" >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_require_var should succeed when variable is set"
    fi
}

test_require_var_empty() {

    export TEST_VAR=""

    if cv_require_var TEST_VAR "Test variable" "Set TEST_VAR" >/dev/null 2>&1; then
        fail "cv_require_var should fail when variable is empty"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

test_require_var_unset() {

    unset TEST_VAR

    if cv_require_var TEST_VAR "Test variable" "Set TEST_VAR" >/dev/null 2>&1; then
        fail "cv_require_var should fail when variable is unset"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

# ============================================================================
# URL Validation Tests
# ============================================================================

test_validate_url_valid_http() {

    export TEST_URL="http://example.com"

    if cv_validate_url TEST_URL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_url should succeed for valid HTTP URL"
    fi
}

test_validate_url_valid_https() {

    export TEST_URL="https://example.com:443/path"

    if cv_validate_url TEST_URL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_url should succeed for valid HTTPS URL"
    fi
}

test_validate_url_valid_postgresql() {

    export TEST_URL="postgresql://user:pass@localhost:5432/db"

    if cv_validate_url TEST_URL "postgresql" >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_url should succeed for valid PostgreSQL URL"
    fi
}

test_validate_url_valid_redis() {

    export TEST_URL="redis://localhost:6379/0"

    if cv_validate_url TEST_URL "redis" >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_url should succeed for valid Redis URL"
    fi
}

test_validate_url_invalid_no_scheme() {

    export TEST_URL="example.com"

    if cv_validate_url TEST_URL >/dev/null 2>&1; then
        fail "cv_validate_url should fail for URL without scheme"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

test_validate_url_wrong_scheme() {

    export TEST_URL="http://localhost:5432/db"

    if cv_validate_url TEST_URL "postgresql" >/dev/null 2>&1; then
        fail "cv_validate_url should fail for wrong scheme"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

test_validate_url_empty() {

    export TEST_URL=""

    cv_validate_url TEST_URL >/dev/null 2>&1
    assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors for empty URL"
    assert_equals 1 "$CV_WARNING_COUNT" "Should have 1 warning line"
}

# ============================================================================
# Port Validation Tests
# ============================================================================

test_validate_port_valid() {

    export TEST_PORT="8080"

    if cv_validate_port TEST_PORT >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_port should succeed for valid port"
    fi
}

test_validate_port_min() {

    export TEST_PORT="1"

    if cv_validate_port TEST_PORT >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_port should succeed for port 1"
    fi
}

test_validate_port_max() {

    export TEST_PORT="65535"

    if cv_validate_port TEST_PORT >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_port should succeed for port 65535"
    fi
}

test_validate_port_zero() {

    export TEST_PORT="0"

    if cv_validate_port TEST_PORT >/dev/null 2>&1; then
        fail "cv_validate_port should fail for port 0"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

test_validate_port_too_high() {

    export TEST_PORT="65536"

    if cv_validate_port TEST_PORT >/dev/null 2>&1; then
        fail "cv_validate_port should fail for port > 65535"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

test_validate_port_non_numeric() {

    export TEST_PORT="abc"

    cv_validate_port TEST_PORT >/dev/null 2>&1
    assert_equals 2 "$CV_ERROR_COUNT" "Should have 2 error lines"
}

# ============================================================================
# Email Validation Tests
# ============================================================================

test_validate_email_valid() {

    export TEST_EMAIL="user@example.com"

    if cv_validate_email TEST_EMAIL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_email should succeed for valid email"
    fi
}

test_validate_email_valid_subdomain() {

    export TEST_EMAIL="user@mail.example.com"

    if cv_validate_email TEST_EMAIL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_email should succeed for email with subdomain"
    fi
}

test_validate_email_invalid_no_at() {

    export TEST_EMAIL="user.example.com"

    cv_validate_email TEST_EMAIL >/dev/null 2>&1
    assert_equals 2 "$CV_ERROR_COUNT" "Should have 2 error lines"
}

test_validate_email_invalid_no_domain() {

    export TEST_EMAIL="user@"

    cv_validate_email TEST_EMAIL >/dev/null 2>&1
    assert_equals 2 "$CV_ERROR_COUNT" "Should have 2 error lines"
}

# ============================================================================
# Boolean Validation Tests
# ============================================================================

test_validate_boolean_true() {

    export TEST_BOOL="true"

    if cv_validate_boolean TEST_BOOL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_boolean should succeed for 'true'"
    fi
}

test_validate_boolean_false() {

    export TEST_BOOL="false"

    if cv_validate_boolean TEST_BOOL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_boolean should succeed for 'false'"
    fi
}

test_validate_boolean_yes() {

    export TEST_BOOL="yes"

    if cv_validate_boolean TEST_BOOL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_boolean should succeed for 'yes'"
    fi
}

test_validate_boolean_numeric() {

    export TEST_BOOL="1"

    if cv_validate_boolean TEST_BOOL >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_boolean should succeed for '1'"
    fi
}

test_validate_boolean_invalid() {

    export TEST_BOOL="maybe"

    if cv_validate_boolean TEST_BOOL >/dev/null 2>&1; then
        fail "cv_validate_boolean should fail for invalid value"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

# ============================================================================
# Path Validation Tests
# ============================================================================

test_validate_path_absolute() {

    export TEST_PATH="/tmp"

    if cv_validate_path TEST_PATH >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_path should succeed for absolute path"
    fi
}

test_validate_path_relative() {

    export TEST_PATH="relative/path"

    cv_validate_path TEST_PATH >/dev/null 2>&1
    assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
    assert_equals 1 "$CV_WARNING_COUNT" "Should have 1 warning line"
}

test_validate_path_exists() {

    export TEST_PATH="/tmp"

    if cv_validate_path TEST_PATH true >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_path should succeed for existing path"
    fi
}

test_validate_path_not_exists() {

    export TEST_PATH="/nonexistent/path"

    if cv_validate_path TEST_PATH true >/dev/null 2>&1; then
        fail "cv_validate_path should fail for non-existent required path"
    else
        assert_equals 3 "$CV_ERROR_COUNT" "Should have 3 error lines"
        return 0
    fi
}

test_validate_path_is_directory() {

    export TEST_PATH="/tmp"

    if cv_validate_path TEST_PATH true true >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        return 0
    else
        fail "cv_validate_path should succeed for directory"
    fi
}

# ============================================================================
# Secret Detection Tests
# ============================================================================

test_detect_secrets_api_key_short() {

    export API_KEY="short"

    cv_detect_secrets API_KEY >/dev/null 2>&1
    assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
    assert_equals 3 "$CV_WARNING_COUNT" "Should warn about short placeholder (2 lines)"
}

test_detect_secrets_api_key_long() {

    export API_KEY="this-is-a-very-long-api-key-value"

    if cv_detect_secrets API_KEY >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        assert_equals 4 "$CV_WARNING_COUNT" "Should warn about plaintext secret (4 lines)"
        return 0
    else
        fail "cv_detect_secrets should succeed"
    fi
}

test_detect_secrets_reference() {

    export API_KEY='${SECRET_FROM_ENV}'

    if cv_detect_secrets API_KEY >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        assert_equals 0 "$CV_WARNING_COUNT" "Should not warn for reference"
        return 0
    else
        fail "cv_detect_secrets should succeed for reference"
    fi
}

test_detect_secrets_file_path() {

    export API_KEY="/run/secrets/api-key"

    if cv_detect_secrets API_KEY >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        assert_equals 0 "$CV_WARNING_COUNT" "Should not warn for file path"
        return 0
    else
        fail "cv_detect_secrets should succeed for file path"
    fi
}

test_detect_secrets_non_secret_var() {

    export NORMAL_VAR="some-value-here"

    if cv_detect_secrets NORMAL_VAR >/dev/null 2>&1; then
        assert_equals 0 "$CV_ERROR_COUNT" "Should have no errors"
        assert_equals 0 "$CV_WARNING_COUNT" "Should not warn for non-secret variable"
        return 0
    else
        fail "cv_detect_secrets should succeed without warning"
    fi
}

# ============================================================================
# Run Tests
# ============================================================================

# Run all tests
run_test test_require_var_set "Required var: set"
run_test test_require_var_empty "Required var: empty"
run_test test_require_var_unset "Required var: unset"
run_test test_validate_url_valid_http "URL validation: HTTP"
run_test test_validate_url_valid_https "URL validation: HTTPS"
run_test test_validate_url_valid_postgresql "URL validation: PostgreSQL"
run_test test_validate_url_valid_redis "URL validation: Redis"
run_test test_validate_url_invalid_no_scheme "URL validation: no scheme"
run_test test_validate_url_wrong_scheme "URL validation: wrong scheme"
run_test test_validate_url_empty "URL validation: empty"
run_test test_validate_port_valid "Port validation: valid port"
run_test test_validate_port_min "Port validation: minimum (1)"
run_test test_validate_port_max "Port validation: maximum (65535)"
run_test test_validate_port_zero "Port validation: zero (invalid)"
run_test test_validate_port_too_high "Port validation: too high"
run_test test_validate_port_non_numeric "Port validation: non-numeric"
run_test test_validate_email_valid "Email validation: valid"
run_test test_validate_email_valid_subdomain "Email validation: subdomain"
run_test test_validate_email_invalid_no_at "Email validation: missing @"
run_test test_validate_email_invalid_no_domain "Email validation: missing domain"
run_test test_validate_boolean_true "Boolean validation: true"
run_test test_validate_boolean_false "Boolean validation: false"
run_test test_validate_boolean_yes "Boolean validation: yes"
run_test test_validate_boolean_numeric "Boolean validation: 1"
run_test test_validate_boolean_invalid "Boolean validation: invalid"
run_test test_validate_path_absolute "Path validation: absolute path"
run_test test_validate_path_relative "Path validation: relative path"
run_test test_validate_path_exists "Path validation: existing path"
run_test test_validate_path_not_exists "Path validation: non-existent"
run_test test_validate_path_is_directory "Path validation: directory"
run_test test_detect_secrets_api_key_short "Secret detection: short placeholder"
run_test test_detect_secrets_api_key_long "Secret detection: plaintext"
run_test test_detect_secrets_reference "Secret detection: reference"
run_test test_detect_secrets_file_path "Secret detection: file path"
run_test test_detect_secrets_non_secret_var "Secret detection: non-secret var"

# Generate test report
generate_report
