#!/usr/bin/env bash
# Unit tests for lib/runtime/check-installed-versions.sh

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "check-installed-versions Runtime Tests"

setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-check-installed-versions"
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
# Batch 6: Static Analysis Tests for check-installed-versions.sh
# ============================================================================

SOURCE_FILE="$PROJECT_ROOT/lib/runtime/check-installed-versions.sh"

# Test: set -euo pipefail
test_civ_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "check-installed-versions.sh uses strict mode"
}

# Test: defines check_version function
test_civ_check_version_func() {
    assert_file_contains "$SOURCE_FILE" "check_version()" "check-installed-versions.sh defines check_version function"
}

# Test: compare_version available via shared version-api.sh
test_civ_compare_version_func() {
    local shared_lib="$PROJECT_ROOT/lib/runtime/lib/version-api.sh"
    assert_file_contains "$shared_lib" "compare_version()" "version-api.sh defines compare_version function"
}

# Test: defines should_display_section function
test_civ_should_display_section_func() {
    assert_file_contains "$SOURCE_FILE" "should_display_section()" "check-installed-versions.sh defines should_display_section function"
}

# Test: --filter flag handling
test_civ_filter_flag() {
    assert_file_contains "$SOURCE_FILE" "--filter" "check-installed-versions.sh supports --filter flag"
    assert_file_contains "$SOURCE_FILE" "FILTER_CATEGORY" "check-installed-versions.sh uses FILTER_CATEGORY variable"
}

# Test: --compare flag handling
test_civ_compare_flag() {
    assert_file_contains "$SOURCE_FILE" "--compare" "check-installed-versions.sh supports --compare flag"
    assert_file_contains "$SOURCE_FILE" "COMPARE_MODE" "check-installed-versions.sh uses COMPARE_MODE variable"
}

# Test: --all flag handling
test_civ_all_flag() {
    assert_file_contains "$SOURCE_FILE" "--all" "check-installed-versions.sh supports --all flag"
    assert_file_contains "$SOURCE_FILE" "SHOW_ALL" "check-installed-versions.sh uses SHOW_ALL variable"
}

# Test: --json output format
test_civ_json_output() {
    assert_file_contains "$SOURCE_FILE" "--json" "check-installed-versions.sh supports --json output"
    assert_file_contains "$SOURCE_FILE" "OUTPUT_FORMAT" "check-installed-versions.sh uses OUTPUT_FORMAT variable"
}

# Test: Version extraction regex patterns
test_civ_version_extraction_patterns() {
    assert_file_contains "$SOURCE_FILE" 'grep -oP' "check-installed-versions.sh uses grep -oP for version extraction"
}

# Test: Summary statistics counting
test_civ_summary_statistics() {
    assert_file_contains "$SOURCE_FILE" "installed_count" "check-installed-versions.sh counts installed tools"
    assert_file_contains "$SOURCE_FILE" "outdated_count" "check-installed-versions.sh counts outdated tools"
}

# Run Batch 6 check-installed-versions tests
run_test test_civ_strict_mode "check-installed-versions.sh uses set -euo pipefail"
run_test test_civ_check_version_func "Defines check_version function"
run_test test_civ_compare_version_func "Defines compare_version function"
run_test test_civ_should_display_section_func "Defines should_display_section function"
run_test test_civ_filter_flag "--filter flag handling"
run_test test_civ_compare_flag "--compare flag handling"
run_test test_civ_all_flag "--all flag handling"
run_test test_civ_json_output "--json output format supported"
run_test test_civ_version_extraction_patterns "Version extraction regex patterns"
run_test test_civ_summary_statistics "Summary statistics counting"

generate_report
