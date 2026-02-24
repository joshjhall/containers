#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/common.sh
# Tests shared logging bootstrap and normalize_env_var_name helper

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Secrets Common Helpers Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/common.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-secrets-common-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run subshell with source file loaded
_run_common_subshell() {
    bash -c "
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_defines_inclusion_guard() {
    assert_file_contains "$SOURCE_FILE" '_SECRETS_COMMON_LOADED' \
        "Script has an inclusion guard variable"
}

test_defines_normalize_env_var_name() {
    assert_file_contains "$SOURCE_FILE" 'normalize_env_var_name()' \
        "Script defines normalize_env_var_name function"
}

test_defines_fallback_logging() {
    assert_file_contains "$SOURCE_FILE" 'log_info()' \
        "Script defines fallback log_info"
    assert_file_contains "$SOURCE_FILE" 'log_error()' \
        "Script defines fallback log_error"
    assert_file_contains "$SOURCE_FILE" 'log_warning()' \
        "Script defines fallback log_warning"
}

test_sources_logging_sh() {
    assert_file_contains "$SOURCE_FILE" 'logging.sh' \
        "Script sources logging.sh"
}

# ============================================================================
# Functional Tests - Fallback Logging
# ============================================================================

test_log_info_available_after_source() {
    local result
    result=$(_run_common_subshell "
        type -t log_info
    ")

    assert_equals "function" "$result" "log_info should be a function after sourcing"
}

test_log_error_available_after_source() {
    local result
    result=$(_run_common_subshell "
        type -t log_error
    ")

    assert_equals "function" "$result" "log_error should be a function after sourcing"
}

test_log_warning_available_after_source() {
    local result
    result=$(_run_common_subshell "
        type -t log_warning
    ")

    assert_equals "function" "$result" "log_warning should be a function after sourcing"
}

# ============================================================================
# Functional Tests - normalize_env_var_name()
# ============================================================================

test_normalize_simple_label() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name '' 'username'
    ")

    assert_equals "USERNAME" "$result" "Simple label should be uppercased"
}

test_normalize_with_prefix() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name 'APP_' 'token'
    ")

    assert_equals "APP_TOKEN" "$result" "Prefix should be prepended"
}

test_normalize_spaces_to_underscores() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name '' 'my secret key'
    ")

    assert_equals "MY_SECRET_KEY" "$result" "Spaces should become underscores"
}

test_normalize_strips_special_chars() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name '' 'api-key.v2!@#'
    ")

    assert_equals "API_KEYV2" "$result" "Hyphens become underscores, other special chars are stripped"
}

test_normalize_hyphens_to_underscores() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name '' 'api-key'
    ")

    assert_equals "API_KEY" "$result" "Hyphens should become underscores"
}

test_normalize_mixed_case_to_upper() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name 'OP_' 'myField'
    ")

    assert_equals "OP_MYFIELD" "$result" "Result should be fully uppercased"
}

test_normalize_preserves_underscores() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name '' 'my_var_name'
    ")

    assert_equals "MY_VAR_NAME" "$result" "Existing underscores should be preserved"
}

test_normalize_prefix_with_spaces_in_label() {
    local result
    result=$(_run_common_subshell "
        normalize_env_var_name 'DB_' 'connection string'
    ")

    assert_equals "DB_CONNECTION_STRING" "$result" "Prefix + spaces in label should work"
}

# ============================================================================
# Functional Tests - Inclusion Guard
# ============================================================================

test_inclusion_guard_prevents_double_load() {
    local result
    result=$(_run_common_subshell "
        # Source twice - should not error
        source '$SOURCE_FILE' >/dev/null 2>&1
        source '$SOURCE_FILE' >/dev/null 2>&1
        echo 'OK'
    ")

    assert_equals "OK" "$result" "Double-sourcing should not cause errors"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_defines_inclusion_guard "Defines inclusion guard"
run_test_with_setup test_defines_normalize_env_var_name "Defines normalize_env_var_name function"
run_test_with_setup test_defines_fallback_logging "Defines fallback logging functions"
run_test_with_setup test_sources_logging_sh "Sources logging.sh"

# Fallback logging
run_test_with_setup test_log_info_available_after_source "log_info available after sourcing"
run_test_with_setup test_log_error_available_after_source "log_error available after sourcing"
run_test_with_setup test_log_warning_available_after_source "log_warning available after sourcing"

# normalize_env_var_name
run_test_with_setup test_normalize_simple_label "Simple label normalization"
run_test_with_setup test_normalize_with_prefix "Prefix prepended to label"
run_test_with_setup test_normalize_spaces_to_underscores "Spaces converted to underscores"
run_test_with_setup test_normalize_strips_special_chars "Special characters stripped"
run_test_with_setup test_normalize_hyphens_to_underscores "Hyphens converted to underscores"
run_test_with_setup test_normalize_mixed_case_to_upper "Mixed case converted to upper"
run_test_with_setup test_normalize_preserves_underscores "Existing underscores preserved"
run_test_with_setup test_normalize_prefix_with_spaces_in_label "Prefix with spaces in label"

# Inclusion guard
run_test_with_setup test_inclusion_guard_prevents_double_load "Double-sourcing is safe"

# Generate test report
generate_report
