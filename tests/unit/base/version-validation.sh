#!/usr/bin/env bash
# Unit tests for lib/base/version-validation.sh
# Tests version string validation functions for security against injection attacks

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Version Validation Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/version-validation.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-version-validation-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run a subshell that sources the file and outputs result on last line
# Provides fallback log_error since logging.sh won't be at /tmp/build-scripts/
_run_validation_subshell() {
    bash -c "
        log_error() { echo \"[ERROR] \$*\" >&2; }
        export -f log_error
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_sources_logging_conditionally() {
    assert_file_contains "$SOURCE_FILE" "if.*-f.*/tmp/build-scripts/base/logging.sh" \
        "Script conditionally sources logging.sh"
}

test_defines_validate_semver() {
    assert_file_contains "$SOURCE_FILE" "validate_semver()" \
        "Script defines validate_semver function"
}

test_defines_validate_version_flexible() {
    assert_file_contains "$SOURCE_FILE" "validate_version_flexible()" \
        "Script defines validate_version_flexible function"
}

test_defines_validate_node_version() {
    assert_file_contains "$SOURCE_FILE" "validate_node_version()" \
        "Script defines validate_node_version function"
}

test_defines_validate_python_version() {
    assert_file_contains "$SOURCE_FILE" "validate_python_version()" \
        "Script defines validate_python_version function"
}

test_defines_validate_rust_version() {
    assert_file_contains "$SOURCE_FILE" "validate_rust_version()" \
        "Script defines validate_rust_version function"
}

test_defines_validate_ruby_version() {
    assert_file_contains "$SOURCE_FILE" "validate_ruby_version()" \
        "Script defines validate_ruby_version function"
}

test_defines_validate_android_api_level() {
    assert_file_contains "$SOURCE_FILE" "validate_android_api_level()" \
        "Script defines validate_android_api_level function"
}

# ============================================================================
# Functional Tests - validate_semver()
# ============================================================================

test_semver_valid_full_version() {
    local exit_code=0
    _run_validation_subshell "validate_semver '3.12.7' 'TEST_VERSION'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_semver accepts 3.12.7"
}

test_semver_rejects_partial_xy() {
    local exit_code=0
    _run_validation_subshell "validate_semver '3.12' 'TEST_VERSION'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_semver rejects 3.12 (needs X.Y.Z)"
}

test_semver_rejects_empty() {
    local exit_code=0
    _run_validation_subshell "validate_semver '' 'TEST_VERSION'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_semver rejects empty string"
}

test_semver_rejects_alpha() {
    local exit_code=0
    _run_validation_subshell "validate_semver 'abc' 'TEST_VERSION'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_semver rejects alphabetic string"
}

test_semver_rejects_single_number() {
    local exit_code=0
    _run_validation_subshell "validate_semver '3' 'TEST_VERSION'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_semver rejects single number"
}

# ============================================================================
# Functional Tests - validate_python_version()
# ============================================================================

test_python_version_major_only() {
    local exit_code=0
    _run_validation_subshell "validate_python_version '3'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_python_version accepts major only '3'"
}

test_python_version_major_minor() {
    local exit_code=0
    _run_validation_subshell "validate_python_version '3.12'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_python_version accepts '3.12'"
}

test_python_version_full() {
    local exit_code=0
    _run_validation_subshell "validate_python_version '3.12.7'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_python_version accepts '3.12.7'"
}

test_python_version_rejects_command_substitution() {
    local exit_code=0
    _run_validation_subshell "validate_python_version '\$(whoami)'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_python_version rejects \$(whoami) injection"
}

test_python_version_rejects_semicolon_injection() {
    local exit_code=0
    _run_validation_subshell "validate_python_version '3;ls'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_python_version rejects semicolon injection"
}

test_python_version_rejects_pipe_injection() {
    local exit_code=0
    _run_validation_subshell "validate_python_version '3|cat'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_python_version rejects pipe injection"
}

test_python_version_rejects_empty() {
    local exit_code=0
    _run_validation_subshell "validate_python_version ''" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_python_version rejects empty string"
}

# ============================================================================
# Functional Tests - validate_rust_version()
# ============================================================================

test_rust_version_stable() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version 'stable'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_rust_version accepts 'stable'"
}

test_rust_version_beta() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version 'beta'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_rust_version accepts 'beta'"
}

test_rust_version_nightly() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version 'nightly'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_rust_version accepts 'nightly'"
}

test_rust_version_partial() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version '1.84'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_rust_version accepts '1.84'"
}

test_rust_version_full() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version '1.82.0'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_rust_version accepts '1.82.0'"
}

test_rust_version_rejects_empty() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version ''" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_rust_version rejects empty string"
}

test_rust_version_rejects_unknown_channel() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version 'canary'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_rust_version rejects unknown channel name"
}

# ============================================================================
# Functional Tests - validate_node_version()
# ============================================================================

test_node_version_major_only() {
    local exit_code=0
    _run_validation_subshell "validate_node_version '22'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_node_version accepts '22'"
}

test_node_version_major_minor() {
    local exit_code=0
    _run_validation_subshell "validate_node_version '20.18'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_node_version accepts '20.18'"
}

test_node_version_full() {
    local exit_code=0
    _run_validation_subshell "validate_node_version '20.18.1'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_node_version accepts '20.18.1'"
}

test_node_version_rejects_alpha() {
    local exit_code=0
    _run_validation_subshell "validate_node_version 'latest'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_node_version rejects 'latest'"
}

# ============================================================================
# Functional Tests - validate_ruby_version()
# ============================================================================

test_ruby_version_partial() {
    local exit_code=0
    _run_validation_subshell "validate_ruby_version '3.4'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_ruby_version accepts '3.4'"
}

test_ruby_version_full() {
    local exit_code=0
    _run_validation_subshell "validate_ruby_version '3.3.6'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_ruby_version accepts '3.3.6'"
}

test_ruby_version_rejects_major_only() {
    local exit_code=0
    _run_validation_subshell "validate_ruby_version '3'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_ruby_version rejects major-only '3'"
}

test_ruby_version_rejects_empty() {
    local exit_code=0
    _run_validation_subshell "validate_ruby_version ''" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_ruby_version rejects empty string"
}

# ============================================================================
# Functional Tests - validate_go_version()
# ============================================================================

test_go_version_partial() {
    local exit_code=0
    _run_validation_subshell "validate_go_version '1.23'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_go_version accepts '1.23'"
}

test_go_version_full() {
    local exit_code=0
    _run_validation_subshell "validate_go_version '1.23.5'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_go_version accepts '1.23.5'"
}

test_go_version_rejects_major_only() {
    local exit_code=0
    _run_validation_subshell "validate_go_version '1'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_go_version rejects major-only '1'"
}

# ============================================================================
# Functional Tests - validate_java_version()
# ============================================================================

test_java_version_major_only() {
    local exit_code=0
    _run_validation_subshell "validate_java_version '21'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_java_version accepts '21'"
}

test_java_version_full() {
    local exit_code=0
    _run_validation_subshell "validate_java_version '11.0.21'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_java_version accepts '11.0.21'"
}

# ============================================================================
# Functional Tests - validate_android_api_level()
# ============================================================================

test_android_api_level_valid() {
    local exit_code=0
    _run_validation_subshell "validate_android_api_level '35'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_android_api_level accepts '35'"
}

test_android_api_level_rejects_alpha() {
    local exit_code=0
    _run_validation_subshell "validate_android_api_level 'abc'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_android_api_level rejects alphabetic string"
}

test_android_api_level_rejects_empty() {
    local exit_code=0
    _run_validation_subshell "validate_android_api_level ''" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_android_api_level rejects empty string"
}

# ============================================================================
# Functional Tests - validate_android_cmdline_tools_version()
# ============================================================================

test_android_cmdline_tools_valid() {
    local exit_code=0
    _run_validation_subshell "validate_android_cmdline_tools_version '11076708'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_android_cmdline_tools_version accepts integer"
}

test_android_cmdline_tools_rejects_dotted() {
    local exit_code=0
    _run_validation_subshell "validate_android_cmdline_tools_version '11.0'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_android_cmdline_tools_version rejects dotted version"
}

# ============================================================================
# Functional Tests - validate_android_ndk_version()
# ============================================================================

test_android_ndk_valid() {
    local exit_code=0
    _run_validation_subshell "validate_android_ndk_version '27.2.12479018'" || exit_code=$?
    assert_equals "0" "$exit_code" "validate_android_ndk_version accepts X.Y.Z format"
}

test_android_ndk_rejects_partial() {
    local exit_code=0
    _run_validation_subshell "validate_android_ndk_version '27.2'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_android_ndk_version rejects partial version"
}

# ============================================================================
# Functional Tests - Command Injection Security
# ============================================================================

test_injection_backticks_python() {
    local exit_code=0
    _run_validation_subshell "validate_python_version '\`whoami\`'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_python_version rejects backtick injection"
}

test_injection_backticks_node() {
    local exit_code=0
    _run_validation_subshell "validate_node_version '\`id\`'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_node_version rejects backtick injection"
}

test_injection_pipe_rust() {
    local exit_code=0
    _run_validation_subshell "validate_rust_version '1.84|cat /etc/passwd'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_rust_version rejects pipe injection"
}

test_injection_semicolon_ruby() {
    local exit_code=0
    _run_validation_subshell "validate_ruby_version '3.4;rm -rf /'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_ruby_version rejects semicolon injection"
}

test_injection_ampersand_go() {
    local exit_code=0
    _run_validation_subshell "validate_go_version '1.23&&cat /etc/passwd'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_go_version rejects ampersand injection"
}

test_injection_dollar_paren_android() {
    local exit_code=0
    _run_validation_subshell "validate_android_api_level '\$(id)'" || exit_code=$?
    assert_equals "1" "$exit_code" "validate_android_api_level rejects \$() injection"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test_with_setup test_sources_logging_conditionally "Conditionally sources logging.sh"
run_test_with_setup test_defines_validate_semver "Defines validate_semver function"
run_test_with_setup test_defines_validate_version_flexible "Defines validate_version_flexible function"
run_test_with_setup test_defines_validate_node_version "Defines validate_node_version function"
run_test_with_setup test_defines_validate_python_version "Defines validate_python_version function"
run_test_with_setup test_defines_validate_rust_version "Defines validate_rust_version function"
run_test_with_setup test_defines_validate_ruby_version "Defines validate_ruby_version function"
run_test_with_setup test_defines_validate_android_api_level "Defines validate_android_api_level function"

# validate_semver
run_test_with_setup test_semver_valid_full_version "validate_semver accepts X.Y.Z"
run_test_with_setup test_semver_rejects_partial_xy "validate_semver rejects X.Y"
run_test_with_setup test_semver_rejects_empty "validate_semver rejects empty"
run_test_with_setup test_semver_rejects_alpha "validate_semver rejects alphabetic"
run_test_with_setup test_semver_rejects_single_number "validate_semver rejects single number"

# validate_python_version
run_test_with_setup test_python_version_major_only "Python accepts major only"
run_test_with_setup test_python_version_major_minor "Python accepts major.minor"
run_test_with_setup test_python_version_full "Python accepts full X.Y.Z"
run_test_with_setup test_python_version_rejects_command_substitution "Python rejects \$(whoami)"
run_test_with_setup test_python_version_rejects_semicolon_injection "Python rejects semicolon injection"
run_test_with_setup test_python_version_rejects_pipe_injection "Python rejects pipe injection"
run_test_with_setup test_python_version_rejects_empty "Python rejects empty"

# validate_rust_version
run_test_with_setup test_rust_version_stable "Rust accepts 'stable'"
run_test_with_setup test_rust_version_beta "Rust accepts 'beta'"
run_test_with_setup test_rust_version_nightly "Rust accepts 'nightly'"
run_test_with_setup test_rust_version_partial "Rust accepts partial X.Y"
run_test_with_setup test_rust_version_full "Rust accepts full X.Y.Z"
run_test_with_setup test_rust_version_rejects_empty "Rust rejects empty"
run_test_with_setup test_rust_version_rejects_unknown_channel "Rust rejects unknown channel"

# validate_node_version
run_test_with_setup test_node_version_major_only "Node accepts major only"
run_test_with_setup test_node_version_major_minor "Node accepts major.minor"
run_test_with_setup test_node_version_full "Node accepts full X.Y.Z"
run_test_with_setup test_node_version_rejects_alpha "Node rejects alphabetic string"

# validate_ruby_version
run_test_with_setup test_ruby_version_partial "Ruby accepts partial X.Y"
run_test_with_setup test_ruby_version_full "Ruby accepts full X.Y.Z"
run_test_with_setup test_ruby_version_rejects_major_only "Ruby rejects major-only"
run_test_with_setup test_ruby_version_rejects_empty "Ruby rejects empty"

# validate_go_version
run_test_with_setup test_go_version_partial "Go accepts partial X.Y"
run_test_with_setup test_go_version_full "Go accepts full X.Y.Z"
run_test_with_setup test_go_version_rejects_major_only "Go rejects major-only"

# validate_java_version
run_test_with_setup test_java_version_major_only "Java accepts major only"
run_test_with_setup test_java_version_full "Java accepts full X.Y.Z"

# validate_android_api_level
run_test_with_setup test_android_api_level_valid "Android API level accepts integer"
run_test_with_setup test_android_api_level_rejects_alpha "Android API level rejects alphabetic"
run_test_with_setup test_android_api_level_rejects_empty "Android API level rejects empty"

# validate_android_cmdline_tools_version
run_test_with_setup test_android_cmdline_tools_valid "Android cmdline tools accepts integer"
run_test_with_setup test_android_cmdline_tools_rejects_dotted "Android cmdline tools rejects dotted version"

# validate_android_ndk_version
run_test_with_setup test_android_ndk_valid "Android NDK accepts X.Y.Z"
run_test_with_setup test_android_ndk_rejects_partial "Android NDK rejects partial"

# Command injection security
run_test_with_setup test_injection_backticks_python "Security: backtick injection rejected (Python)"
run_test_with_setup test_injection_backticks_node "Security: backtick injection rejected (Node)"
run_test_with_setup test_injection_pipe_rust "Security: pipe injection rejected (Rust)"
run_test_with_setup test_injection_semicolon_ruby "Security: semicolon injection rejected (Ruby)"
run_test_with_setup test_injection_ampersand_go "Security: ampersand injection rejected (Go)"
run_test_with_setup test_injection_dollar_paren_android "Security: \$() injection rejected (Android)"

# Generate test report
generate_report
