#!/usr/bin/env bash
# Unit tests for lib/base/cache-utils.sh
# Tests cache directory creation utilities for container build system

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Cache Utilities Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/cache-utils.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-cache-utils-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR USER_UID USER_GID 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run a subshell that sources the file with mocked log_command and log_error
_run_cache_subshell() {
    bash -c "
        log_command() { shift; \"\$@\"; }
        log_error() { echo \"ERROR: \$*\" >&2; }
        export -f log_command log_error
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script uses strict mode"
}

test_defines_create_language_cache() {
    assert_file_contains "$SOURCE_FILE" "create_language_cache()" \
        "Script defines create_language_cache function"
}

test_defines_create_language_caches() {
    assert_file_contains "$SOURCE_FILE" "create_language_caches()" \
        "Script defines create_language_caches function"
}

test_defines_create_cache_directories() {
    assert_file_contains "$SOURCE_FILE" "create_cache_directories()" \
        "Script defines create_cache_directories function"
}

test_exports_create_language_cache() {
    assert_file_contains "$SOURCE_FILE" "export -f create_language_cache" \
        "create_language_cache is exported"
}

test_exports_create_language_caches() {
    assert_file_contains "$SOURCE_FILE" "export -f create_language_caches" \
        "create_language_caches is exported"
}

test_exports_create_cache_directories() {
    assert_file_contains "$SOURCE_FILE" "export -f create_cache_directories" \
        "create_cache_directories is exported"
}

test_uses_cache_base_path() {
    assert_file_contains "$SOURCE_FILE" "/cache" \
        "Script uses /cache as the base path"
}

test_uses_0755_permissions() {
    assert_file_contains "$SOURCE_FILE" "0755" \
        "Script uses 0755 permissions for cache directories"
}

# ============================================================================
# Functional Tests
# ============================================================================

test_create_language_cache_error_without_user_uid() {
    local exit_code=0
    _run_cache_subshell "
        unset USER_UID 2>/dev/null || true
        export USER_GID=1000
        create_language_cache 'pip' '$TEST_TEMP_DIR'
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "create_language_cache should return error when USER_UID unset"
}

test_create_language_cache_error_without_user_gid() {
    local exit_code=0
    _run_cache_subshell "
        export USER_UID=1000
        unset USER_GID 2>/dev/null || true
        create_language_cache 'pip' '$TEST_TEMP_DIR'
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "create_language_cache should return error when USER_GID unset"
}

test_create_language_caches_error_no_arguments() {
    local exit_code=0
    _run_cache_subshell "
        export USER_UID=1000
        export USER_GID=1000
        create_language_caches
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "create_language_caches should return error with no arguments"
}

test_create_cache_directories_error_no_arguments() {
    local exit_code=0
    _run_cache_subshell "
        export USER_UID=1000
        export USER_GID=1000
        create_cache_directories
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "create_cache_directories should return error with no arguments"
}

test_create_cache_directories_error_without_user_uid() {
    local exit_code=0
    _run_cache_subshell "
        unset USER_UID 2>/dev/null || true
        export USER_GID=1000
        create_cache_directories '$TEST_TEMP_DIR/cache1'
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" \
        "create_cache_directories should return error when USER_UID unset"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_create_language_cache "Defines create_language_cache function"
run_test_with_setup test_defines_create_language_caches "Defines create_language_caches function"
run_test_with_setup test_defines_create_cache_directories "Defines create_cache_directories function"
run_test_with_setup test_exports_create_language_cache "create_language_cache is exported"
run_test_with_setup test_exports_create_language_caches "create_language_caches is exported"
run_test_with_setup test_exports_create_cache_directories "create_cache_directories is exported"
run_test_with_setup test_uses_cache_base_path "Uses /cache as base path"
run_test_with_setup test_uses_0755_permissions "Uses 0755 permissions"

# Functional tests
run_test_with_setup test_create_language_cache_error_without_user_uid "create_language_cache errors when USER_UID unset"
run_test_with_setup test_create_language_cache_error_without_user_gid "create_language_cache errors when USER_GID unset"
run_test_with_setup test_create_language_caches_error_no_arguments "create_language_caches errors with no arguments"
run_test_with_setup test_create_cache_directories_error_no_arguments "create_cache_directories errors with no arguments"
run_test_with_setup test_create_cache_directories_error_without_user_uid "create_cache_directories errors when USER_UID unset"

# Generate test report
generate_report
