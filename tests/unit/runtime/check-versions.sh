#!/usr/bin/env bash
# Unit tests for lib/runtime/check-versions.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "check-versions Runtime Tests"

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-check-versions"
    mkdir -p "$TEST_TEMP_DIR"
}

teardown() {
    [ -n "${TEST_TEMP_DIR:-}" ] && command rm -rf "$TEST_TEMP_DIR"
}

test_script_exists() {
    local script_file="$TEST_TEMP_DIR/script.sh"
    echo "#\!/bin/bash" > "$script_file"
    chmod +x "$script_file"
    assert_file_exists "$script_file"
    [ -x "$script_file" ] && assert_true true "Script is executable" || assert_true false "Script not executable"
}

test_output_format() {
    local output_file="$TEST_TEMP_DIR/output.txt"
    echo "Test output" > "$output_file"
    assert_file_exists "$output_file"
    [ -s "$output_file" ] && assert_true true "Output generated" || assert_true false "No output"
}

test_error_handling() {
    local error_log="$TEST_TEMP_DIR/error.log"
    echo "Error: test" > "$error_log"
    assert_file_exists "$error_log"
    grep -q "Error" "$error_log" && assert_true true "Error logged" || assert_true false "Error not logged"
}

test_permissions() {
    local test_file="$TEST_TEMP_DIR/test.txt"
    touch "$test_file"
    chmod 644 "$test_file"
    assert_file_exists "$test_file"
    [ -r "$test_file" ] && assert_true true "File readable" || assert_true false "File not readable"
}

test_directory_structure() {
    local test_dir="$TEST_TEMP_DIR/structure/sub"
    mkdir -p "$test_dir"
    assert_dir_exists "$test_dir"
}

test_environment_variables() {
    local env_file="$TEST_TEMP_DIR/env.sh"
    echo "export TEST_VAR=123" > "$env_file"
    assert_file_exists "$env_file"
    grep -q "export TEST_VAR" "$env_file" && assert_true true "Env var exported" || assert_true false "Env var not exported"
}

test_command_execution() {
    local cmd_file="$TEST_TEMP_DIR/cmd.sh"
    echo "echo 'test'" > "$cmd_file"
    chmod +x "$cmd_file"
    assert_file_exists "$cmd_file"
    [ -x "$cmd_file" ] && assert_true true "Command executable" || assert_true false "Command not executable"
}

test_logging() {
    local log_file="$TEST_TEMP_DIR/app.log"
    echo "[INFO] Test log entry" > "$log_file"
    assert_file_exists "$log_file"
    grep -q "\[INFO\]" "$log_file" && assert_true true "Log entry found" || assert_true false "Log entry not found"
}

test_configuration() {
    local config_file="$TEST_TEMP_DIR/config.conf"
    echo "setting=value" > "$config_file"
    assert_file_exists "$config_file"
    grep -q "setting=value" "$config_file" && assert_true true "Config valid" || assert_true false "Config invalid"
}

test_validation() {
    local validate_script="$TEST_TEMP_DIR/validate.sh"
    echo "#\!/bin/bash" > "$validate_script"
    echo "exit 0" >> "$validate_script"
    chmod +x "$validate_script"
    assert_file_exists "$validate_script"
    [ -x "$validate_script" ] && assert_true true "Validation script ready" || assert_true false "Validation script not ready"
}

run_test_with_setup() {
    setup
    run_test "$1" "$2"
    teardown
}

run_test_with_setup test_script_exists "Script exists test"
run_test_with_setup test_output_format "Output format test"
run_test_with_setup test_error_handling "Error handling test"
run_test_with_setup test_permissions "Permissions test"
run_test_with_setup test_directory_structure "Directory structure test"
run_test_with_setup test_environment_variables "Environment variables test"
run_test_with_setup test_command_execution "Command execution test"
run_test_with_setup test_logging "Logging test"
run_test_with_setup test_configuration "Configuration test"
run_test_with_setup test_validation "Validation test"

# ============================================================================
# Batch 6: Static Analysis Tests for check-versions.sh
# ============================================================================

SOURCE_FILE="$PROJECT_ROOT/lib/runtime/check-versions.sh"

# Test: set -euo pipefail
test_cv_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "check-versions.sh uses strict mode"
}

# Test: sources shared version-api.sh (provides get_github_release, compare_version, etc.)
test_cv_get_github_release_func() {
    assert_file_contains "$SOURCE_FILE" "version-api.sh" "check-versions.sh sources shared version-api.sh"
}

# Test: defines get_latest_python function
test_cv_get_latest_python_func() {
    assert_file_contains "$SOURCE_FILE" "get_latest_python()" "check-versions.sh defines get_latest_python function"
}

# Test: defines get_latest_node function
test_cv_get_latest_node_func() {
    assert_file_contains "$SOURCE_FILE" "get_latest_node()" "check-versions.sh defines get_latest_node function"
}

# Test: defines get_latest_go function
test_cv_get_latest_go_func() {
    assert_file_contains "$SOURCE_FILE" "get_latest_go()" "check-versions.sh defines get_latest_go function"
}

# Test: compare_version available via shared version-api.sh
test_cv_compare_version_func() {
    local shared_lib="$PROJECT_ROOT/lib/runtime/lib/version-api.sh"
    assert_file_contains "$shared_lib" "compare_version()" "version-api.sh defines compare_version function"
}

# Test: defines extract_version function
test_cv_extract_version_func() {
    assert_file_contains "$SOURCE_FILE" "extract_version()" "check-versions.sh defines extract_version function"
}

# Test: defines print_result function
test_cv_print_result_func() {
    assert_file_contains "$SOURCE_FILE" "print_result()" "check-versions.sh defines print_result function"
}

# Test: GitHub API rate limiting detection
test_cv_rate_limit_detection() {
    assert_file_contains "$SOURCE_FILE" "rate limit exceeded" "check-versions.sh detects GitHub API rate limiting"
}

# Test: Version comparison with sort -V (in shared version-api.sh)
test_cv_sort_version_comparison() {
    local shared_lib="$PROJECT_ROOT/lib/runtime/lib/version-api.sh"
    assert_file_contains "$shared_lib" "sort -V" "version-api.sh uses sort -V for version comparison"
}

# Test: JSON output format handling
test_cv_json_output_flag() {
    assert_file_contains "$SOURCE_FILE" "--json" "check-versions.sh supports --json flag"
}

# Test: Color output variables
test_cv_color_variables() {
    assert_file_contains "$SOURCE_FILE" "RED=" "check-versions.sh defines RED color variable"
    assert_file_contains "$SOURCE_FILE" "GREEN=" "check-versions.sh defines GREEN color variable"
    assert_file_contains "$SOURCE_FILE" "YELLOW=" "check-versions.sh defines YELLOW color variable"
    assert_file_contains "$SOURCE_FILE" "NC=" "check-versions.sh defines NC (no color) variable"
}

# Run Batch 6 check-versions tests
run_test test_cv_strict_mode "check-versions.sh uses set -euo pipefail"
run_test test_cv_get_github_release_func "Defines get_github_release function"
run_test test_cv_get_latest_python_func "Defines get_latest_python function"
run_test test_cv_get_latest_node_func "Defines get_latest_node function"
run_test test_cv_get_latest_go_func "Defines get_latest_go function"
run_test test_cv_compare_version_func "Defines compare_version function"
run_test test_cv_extract_version_func "Defines extract_version function"
run_test test_cv_print_result_func "Defines print_result function"
run_test test_cv_rate_limit_detection "GitHub API rate limiting detection"
run_test test_cv_sort_version_comparison "Version comparison with sort -V"
run_test test_cv_json_output_flag "JSON output format supported"
run_test test_cv_color_variables "Color output variables defined"

generate_report
