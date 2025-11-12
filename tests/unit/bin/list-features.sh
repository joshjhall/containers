#!/usr/bin/env bash
# Unit tests for bin/list-features.sh
# Tests feature listing functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "List Features Tests"

# Path to script under test
LIST_FEATURES="$(dirname "${BASH_SOURCE[0]}")/../../../bin/list-features.sh"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$LIST_FEATURES" "list-features.sh should exist"

    # Check if script is executable
    if [ -x "$LIST_FEATURES" ]; then
        pass_test "list-features.sh is executable"
    else
        fail_test "list-features.sh is not executable"
    fi
}

# ============================================================================
# Test: Help output
# ============================================================================
test_help_output() {
    local output
    output=$("$LIST_FEATURES" --help 2>&1)

    assert_contains "$output" "Usage:" "Help should contain usage information"
    assert_contains "$output" "Options:" "Help should contain options section"
    assert_contains "$output" "--json" "Help should mention --json option"
    assert_contains "$output" "--filter" "Help should mention --filter option"
}

# ============================================================================
# Test: Table output (default)
# ============================================================================
test_table_output() {
    local output exit_code
    output=$("$LIST_FEATURES" 2>&1) && exit_code=$? || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit successfully"
    assert_contains "$output" "Available Container Features" "Should show header"
    assert_contains "$output" "LANGUAGES" "Should show languages category"
    assert_contains "$output" "DEVELOPMENT TOOLS" "Should show dev tools category"
    assert_contains "$output" "INCLUDE_PYTHON" "Should list Python feature"
}

# ============================================================================
# Test: JSON output
# ============================================================================
test_json_output() {
    local output exit_code
    output=$("$LIST_FEATURES" --json 2>&1) && exit_code=$? || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit successfully"
    assert_contains "$output" '"features"' "JSON should have features array"
    assert_contains "$output" '"name"' "JSON should have name field"
    assert_contains "$output" '"build_arg"' "JSON should have build_arg field"
    assert_contains "$output" '"category"' "JSON should have category field"
    assert_contains "$output" '"description"' "JSON should have description field"

    # Validate JSON format
    if command -v jq >/dev/null 2>&1; then
        assert_exit_code_success bash -c "echo '$output' | jq ." "JSON should be valid"
    fi
}

# ============================================================================
# Test: Filter by category
# ============================================================================
test_filter_language() {
    local output exit_code
    output=$("$LIST_FEATURES" --filter language 2>&1) && exit_code=$? || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit successfully"
    assert_contains "$output" "python" "Should include Python in language filter"
    assert_contains "$output" "node" "Should include Node in language filter"
    assert_not_contains "$output" "DEVELOPMENT TOOLS" "Should not show dev tools category"
}

test_filter_cloud() {
    local output exit_code
    output=$("$LIST_FEATURES" --filter cloud 2>&1) && exit_code=$? || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit successfully"
    assert_contains "$output" "kubernetes" "Should include Kubernetes in cloud filter"
    assert_not_contains "$output" "python" "Should not include Python in cloud filter"
}

# ============================================================================
# Test: JSON filter combination
# ============================================================================
test_json_with_filter() {
    local output exit_code
    output=$("$LIST_FEATURES" --json --filter dev-tools 2>&1) && exit_code=$? || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit successfully"
    assert_contains "$output" '"features"' "Filtered JSON should have features array"
    assert_contains "$output" '"category": "dev-tools"' "Should only contain dev-tools"

    # Validate JSON format
    if command -v jq >/dev/null 2>&1; then
        assert_exit_code_success bash -c "echo '$output' | jq ." "JSON should be valid"
    fi
}

# ============================================================================
# Test: Invalid filter
# ============================================================================
test_invalid_category_filter() {
    local output exit_code
    # Invalid category should just return empty results (not error)
    output=$("$LIST_FEATURES" --filter nonexistent 2>&1) && exit_code=$? || exit_code=$?

    assert_equals 0 "$exit_code" "Should exit successfully even with invalid filter"
}

# ============================================================================
# Test: Unknown option
# ============================================================================
test_unknown_option() {
    local output exit_code
    output=$("$LIST_FEATURES" --invalid-option 2>&1) || exit_code=$?

    assert_not_equals 0 "$exit_code" "Should exit with error for unknown option"
    assert_contains "$output" "Unknown option" "Should show unknown option error"
}

# ============================================================================
# Test: Specific features are detected
# ============================================================================
test_detects_python_feature() {
    local output
    output=$("$LIST_FEATURES" 2>&1)

    assert_contains "$output" "python" "Should detect Python feature"
    assert_contains "$output" "INCLUDE_PYTHON" "Should show INCLUDE_PYTHON build arg"
}

test_detects_docker_feature() {
    local output
    output=$("$LIST_FEATURES" 2>&1)

    assert_contains "$output" "docker" "Should detect Docker feature"
    assert_contains "$output" "INCLUDE_DOCKER" "Should show INCLUDE_DOCKER build arg"
}

# ============================================================================
# Test: Categories are properly assigned
# ============================================================================
test_category_assignment() {
    local output
    output=$("$LIST_FEATURES" --json 2>&1)

    # Check that common features have correct categories
    assert_contains "$output" '"name": "python"' "Should include Python"
    assert_contains "$output" '"category": "language"' "Should categorize Python as language"
}

# ============================================================================
# Test execution
# ============================================================================

# Setup function
setup() {
    :  # No setup needed
}

# Teardown function
teardown() {
    :  # No teardown needed
}

# Run test with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_script_exists "Script exists and is executable"
run_test_with_setup test_help_output "Help output is correct"
run_test_with_setup test_table_output "Table output works"
run_test_with_setup test_json_output "JSON output works"
run_test_with_setup test_filter_language "Filter by language category"
run_test_with_setup test_filter_cloud "Filter by cloud category"
run_test_with_setup test_json_with_filter "JSON with filter combination"
run_test_with_setup test_invalid_category_filter "Invalid category filter handled"
run_test_with_setup test_unknown_option "Unknown option shows error"
run_test_with_setup test_detects_python_feature "Python feature is detected"
run_test_with_setup test_detects_docker_feature "Docker feature is detected"
run_test_with_setup test_category_assignment "Categories are properly assigned"

# Generate test report
generate_report
