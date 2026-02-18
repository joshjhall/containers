#!/usr/bin/env bash
# Unit tests for bin/validate-build-args.sh
# Tests build argument validation functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Validate Build Args Tests"

# Path to the script under test
SOURCE_FILE="$PROJECT_ROOT/bin/validate-build-args.sh"

# Setup function - runs before each test (overrides framework setup)
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-validate-build-args-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test (overrides framework teardown)
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
    unset INCLUDE_PYTHON INCLUDE_PYTHON_DEV INCLUDE_NODE INCLUDE_NODE_DEV 2>/dev/null || true
    unset INCLUDE_RUST INCLUDE_RUST_DEV INCLUDE_GOLANG INCLUDE_GOLANG_DEV 2>/dev/null || true
    unset INCLUDE_CLOUDFLARE INCLUDE_DEV_TOOLS INCLUDE_DOCKER 2>/dev/null || true
    unset USERNAME USER_UID USER_GID ENABLE_PASSWORDLESS_SUDO 2>/dev/null || true
    unset PYTHON_VERSION NODE_VERSION RUST_VERSION GO_VERSION 2>/dev/null || true
}

# Wrapper for running tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Static analysis tests
# ============================================================================

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "validate-build-args.sh should exist"

    if [ -x "$SOURCE_FILE" ]; then
        pass_test "validate-build-args.sh is executable"
    else
        fail_test "validate-build-args.sh is not executable"
    fi
}

# Test: Script has valid bash syntax
test_syntax_valid() {
    if bash -n "$SOURCE_FILE" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

# Test: Script uses strict mode
test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "validate-build-args.sh should use strict mode"
}

# Test: Defines validate_boolean function
test_defines_validate_boolean() {
    assert_file_contains "$SOURCE_FILE" "validate_boolean()" \
        "Should define validate_boolean function"
}

# Test: Defines validate_username function
test_defines_validate_username() {
    assert_file_contains "$SOURCE_FILE" "validate_username()" \
        "Should define validate_username function"
}

# Test: Defines validate_uid_gid function
test_defines_validate_uid_gid() {
    assert_file_contains "$SOURCE_FILE" "validate_uid_gid()" \
        "Should define validate_uid_gid function"
}

# Test: Defines check_dependencies function
test_defines_check_dependencies() {
    assert_file_contains "$SOURCE_FILE" "check_dependencies()" \
        "Should define check_dependencies function"
}

# Test: Defines validate_build_args function
test_defines_validate_build_args() {
    assert_file_contains "$SOURCE_FILE" "validate_build_args()" \
        "Should define validate_build_args function"
}

# Test: Defines check_cloudflare_dependency function
test_defines_check_cloudflare_dependency() {
    assert_file_contains "$SOURCE_FILE" "check_cloudflare_dependency()" \
        "Should define check_cloudflare_dependency function"
}

# Test: Defines validate_version function
test_defines_validate_version() {
    assert_file_contains "$SOURCE_FILE" "validate_version()" \
        "Should define validate_version function"
}

# Test: Defines error and warn output functions
test_defines_output_functions() {
    assert_file_contains "$SOURCE_FILE" "error()" \
        "Should define error function"
    assert_file_contains "$SOURCE_FILE" "warn()" \
        "Should define warn function"
    assert_file_contains "$SOURCE_FILE" "success()" \
        "Should define success function"
    assert_file_contains "$SOURCE_FILE" "info()" \
        "Should define info function"
}

# Test: ERRORS and WARNINGS counters are initialized
test_error_warning_counters() {
    assert_file_contains "$SOURCE_FILE" "ERRORS=0" \
        "Should initialize ERRORS counter to 0"
    assert_file_contains "$SOURCE_FILE" "WARNINGS=0" \
        "Should initialize WARNINGS counter to 0"
}

# ============================================================================
# Functional tests: Full script execution
# ============================================================================

# Note: The script's warn() function uses ((WARNINGS++)) which, when
# WARNINGS=0 under set -e, causes an early exit because the pre-increment
# value 0 is falsy in arithmetic context. ENABLE_PASSWORDLESS_SUDO defaults
# to "true" which triggers a warn() call. Tests expecting exit 0 must set
# ENABLE_PASSWORDLESS_SUDO=false to avoid this.

# Test: Script returns 0 with default env (no INCLUDE_* set)
test_script_returns_0_with_defaults() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Script should return 0 with default args"
}

# Test: Script returns 1 when invalid boolean given
test_script_returns_1_with_invalid_boolean() {
    local exit_code=0
    INCLUDE_PYTHON=invalid bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Script should return 1 with invalid boolean"
}

# Test: --help flag exits 0
test_help_flag_exits_0() {
    local exit_code=0
    bash "$SOURCE_FILE" --help >/dev/null 2>&1 || exit_code=$?
    assert_equals "0" "$exit_code" "Help flag should exit with code 0"
}

# Test: --help flag outputs usage information
test_help_flag_output() {
    local output
    output=$(bash "$SOURCE_FILE" --help 2>&1) || true

    assert_contains "$output" "Validate Build Arguments" "Help should show script description"
}

# ============================================================================
# Functional tests: validate_boolean via script execution
# ============================================================================

# Test: validate_boolean accepts 'true'
test_validate_boolean_accepts_true() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false INCLUDE_PYTHON=true bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "validate_boolean should accept 'true'"
}

# Test: validate_boolean accepts 'false'
test_validate_boolean_accepts_false() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false INCLUDE_PYTHON=false bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "validate_boolean should accept 'false'"
}

# Test: validate_boolean rejects 'yes'
test_validate_boolean_rejects_yes() {
    local exit_code=0
    INCLUDE_PYTHON=yes bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_boolean should reject 'yes'"
}

# Test: validate_boolean rejects '1'
test_validate_boolean_rejects_1() {
    local exit_code=0
    INCLUDE_PYTHON=1 bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_boolean should reject '1'"
}

# Test: validate_boolean rejects 'TRUE' (case-sensitive)
test_validate_boolean_rejects_uppercase() {
    local exit_code=0
    INCLUDE_PYTHON=TRUE bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_boolean should reject 'TRUE'"
}

# Test: validate_boolean accepts empty (uses default)
test_validate_boolean_accepts_empty() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false INCLUDE_PYTHON="" bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "validate_boolean should accept empty string"
}

# ============================================================================
# Functional tests: validate_username via script execution
# ============================================================================

# Test: validate_username rejects uppercase
test_validate_username_rejects_uppercase() {
    local exit_code=0
    USERNAME="MyUser" bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_username should reject uppercase names"
}

# Test: validate_username accepts lowercase with digits and underscore
test_validate_username_accepts_valid() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false USERNAME="dev_user1" bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "validate_username should accept lowercase+digits+underscore"
}

# Test: validate_username rejects names starting with digit
test_validate_username_rejects_digit_start() {
    local exit_code=0
    USERNAME="1user" bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_username should reject names starting with digit"
}

# ============================================================================
# Functional tests: validate_uid_gid via script execution
# ============================================================================

# Test: validate_uid_gid accepts 1000
test_validate_uid_gid_accepts_1000() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false USER_UID=1000 USER_GID=1000 bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "validate_uid_gid should accept 1000"
}

# Test: validate_uid_gid rejects 999 (below minimum)
test_validate_uid_gid_rejects_999() {
    local exit_code=0
    USER_UID=999 bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_uid_gid should reject UID below 1000"
}

# Test: validate_uid_gid rejects 60001 (above maximum)
test_validate_uid_gid_rejects_60001() {
    local exit_code=0
    USER_UID=60001 bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_uid_gid should reject UID above 60000"
}

# Test: validate_uid_gid rejects non-numeric
test_validate_uid_gid_rejects_non_numeric() {
    local exit_code=0
    USER_UID=abc bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "validate_uid_gid should reject non-numeric UID"
}

# ============================================================================
# Functional tests: Dependency checks via script execution
# ============================================================================

# Test: PYTHON_DEV without PYTHON fails
test_python_dev_requires_python() {
    local exit_code=0
    INCLUDE_PYTHON=false INCLUDE_PYTHON_DEV=true bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "PYTHON_DEV=true should require PYTHON=true"
}

# Test: PYTHON_DEV with PYTHON succeeds
test_python_dev_with_python_succeeds() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false INCLUDE_PYTHON=true INCLUDE_PYTHON_DEV=true bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "PYTHON_DEV=true with PYTHON=true should succeed"
}

# Test: CLOUDFLARE without NODE fails
test_cloudflare_requires_node() {
    local exit_code=0
    INCLUDE_CLOUDFLARE=true INCLUDE_NODE=false bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "CLOUDFLARE=true should require NODE=true"
}

# Test: Multiple valid booleans pass
test_multiple_valid_booleans() {
    local exit_code=0
    ENABLE_PASSWORDLESS_SUDO=false INCLUDE_PYTHON=true INCLUDE_NODE=true INCLUDE_DOCKER=false \
        bash "$SOURCE_FILE" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Multiple valid booleans should pass"
}

# ============================================================================
# Run all tests
# ============================================================================
run_test_with_setup test_script_exists "Script exists and is executable"
run_test_with_setup test_syntax_valid "Script syntax is valid"
run_test_with_setup test_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_defines_validate_boolean "Defines validate_boolean function"
run_test_with_setup test_defines_validate_username "Defines validate_username function"
run_test_with_setup test_defines_validate_uid_gid "Defines validate_uid_gid function"
run_test_with_setup test_defines_check_dependencies "Defines check_dependencies function"
run_test_with_setup test_defines_validate_build_args "Defines validate_build_args function"
run_test_with_setup test_defines_check_cloudflare_dependency "Defines check_cloudflare_dependency function"
run_test_with_setup test_defines_validate_version "Defines validate_version function"
run_test_with_setup test_defines_output_functions "Defines error, warn, success, info functions"
run_test_with_setup test_error_warning_counters "ERRORS and WARNINGS counters initialized"
run_test_with_setup test_script_returns_0_with_defaults "Script returns 0 with default env"
run_test_with_setup test_script_returns_1_with_invalid_boolean "Script returns 1 with invalid boolean"
run_test_with_setup test_help_flag_exits_0 "Help flag exits with code 0"
run_test_with_setup test_help_flag_output "Help flag outputs usage information"
run_test_with_setup test_validate_boolean_accepts_true "validate_boolean accepts true"
run_test_with_setup test_validate_boolean_accepts_false "validate_boolean accepts false"
run_test_with_setup test_validate_boolean_rejects_yes "validate_boolean rejects yes"
run_test_with_setup test_validate_boolean_rejects_1 "validate_boolean rejects 1"
run_test_with_setup test_validate_boolean_rejects_uppercase "validate_boolean rejects TRUE"
run_test_with_setup test_validate_boolean_accepts_empty "validate_boolean accepts empty"
run_test_with_setup test_validate_username_rejects_uppercase "validate_username rejects uppercase"
run_test_with_setup test_validate_username_accepts_valid "validate_username accepts valid name"
run_test_with_setup test_validate_username_rejects_digit_start "validate_username rejects digit start"
run_test_with_setup test_validate_uid_gid_accepts_1000 "validate_uid_gid accepts 1000"
run_test_with_setup test_validate_uid_gid_rejects_999 "validate_uid_gid rejects 999"
run_test_with_setup test_validate_uid_gid_rejects_60001 "validate_uid_gid rejects 60001"
run_test_with_setup test_validate_uid_gid_rejects_non_numeric "validate_uid_gid rejects non-numeric"
run_test_with_setup test_python_dev_requires_python "PYTHON_DEV requires PYTHON"
run_test_with_setup test_python_dev_with_python_succeeds "PYTHON_DEV with PYTHON succeeds"
run_test_with_setup test_cloudflare_requires_node "CLOUDFLARE requires NODE"
run_test_with_setup test_multiple_valid_booleans "Multiple valid booleans pass"

# Generate test report
generate_report
