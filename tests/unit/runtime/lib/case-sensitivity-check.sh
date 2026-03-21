#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/case-sensitivity-check.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Case Sensitivity Check Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/lib/case-sensitivity-check.sh"

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "case-sensitivity-check.sh exists"
}

test_script_executable() {
    assert_executable "$SOURCE_FILE" "case-sensitivity-check.sh is executable"
}

test_multiple_source_guard() {
    assert_file_contains "$SOURCE_FILE" "_CASE_SENSITIVITY_CHECK_LOADED" \
        "Script has multiple-source guard"
}

test_defines_check_case_sensitivity() {
    assert_file_contains "$SOURCE_FILE" "check_case_sensitivity()" \
        "Script defines check_case_sensitivity function"
}

test_skip_case_check_opt_out() {
    assert_file_contains "$SOURCE_FILE" "SKIP_CASE_CHECK" \
        "Script checks SKIP_CASE_CHECK env var"
}

test_detection_script_path() {
    assert_file_contains "$SOURCE_FILE" "/usr/local/bin/detect-case-sensitivity.sh" \
        "Script references detection script"
}

test_workspace_existence_check() {
    assert_file_contains "$SOURCE_FILE" '[ -d "/workspace" ]' \
        "Script checks /workspace existence"
}

test_workspace_writable_check() {
    assert_file_contains "$SOURCE_FILE" '[ -w "/workspace" ]' \
        "Script checks /workspace writability"
}

test_warning_title() {
    assert_file_contains "$SOURCE_FILE" "Case-Insensitive Filesystem Detected" \
        "Script contains warning title"
}

test_recommendation_apfs() {
    assert_file_contains "$SOURCE_FILE" "case-sensitive APFS" \
        "Script recommends case-sensitive APFS volume"
}

test_recommendation_wsl2() {
    assert_file_contains "$SOURCE_FILE" "WSL2" \
        "Script recommends WSL2 filesystem"
}

test_recommendation_docker_volumes() {
    assert_file_contains "$SOURCE_FILE" "Docker volumes" \
        "Script recommends Docker volumes"
}

test_docs_reference() {
    assert_file_contains "$SOURCE_FILE" "docs/troubleshooting/case-sensitive-filesystems.md" \
        "Script references troubleshooting docs"
}

test_opt_out_reminder() {
    assert_file_contains "$SOURCE_FILE" "SKIP_CASE_CHECK=true" \
        "Script mentions opt-out via SKIP_CASE_CHECK=true"
}

# ============================================================================
# Functional Tests
# ============================================================================

test_sourcing_defines_function() {
    (
        unset _CASE_SENSITIVITY_CHECK_LOADED 2>/dev/null || true
        source "$SOURCE_FILE"
        declare -f check_case_sensitivity >/dev/null 2>&1 || exit 1
    )
    assert_equals "0" "$?" "Sourcing defines check_case_sensitivity function"
}

test_sourcing_sets_loaded_flag() {
    (
        unset _CASE_SENSITIVITY_CHECK_LOADED 2>/dev/null || true
        source "$SOURCE_FILE"
        [ "${_CASE_SENSITIVITY_CHECK_LOADED:-}" = "1" ] || exit 1
    )
    assert_equals "0" "$?" "Sourcing sets _CASE_SENSITIVITY_CHECK_LOADED=1"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_script_executable "Script is executable"
run_test test_multiple_source_guard "Has multiple-source guard"
run_test test_defines_check_case_sensitivity "Defines check_case_sensitivity"
run_test test_skip_case_check_opt_out "Checks SKIP_CASE_CHECK opt-out"
run_test test_detection_script_path "References detection script"
run_test test_workspace_existence_check "Checks /workspace existence"
run_test test_workspace_writable_check "Checks /workspace writability"
run_test test_warning_title "Contains warning title"
run_test test_recommendation_apfs "Recommends case-sensitive APFS"
run_test test_recommendation_wsl2 "Recommends WSL2"
run_test test_recommendation_docker_volumes "Recommends Docker volumes"
run_test test_docs_reference "References troubleshooting docs"
run_test test_opt_out_reminder "Mentions SKIP_CASE_CHECK=true opt-out"

# Functional tests
run_test test_sourcing_defines_function "Sourcing defines check_case_sensitivity"
run_test test_sourcing_sets_loaded_flag "Sourcing sets _CASE_SENSITIVITY_CHECK_LOADED"

# Generate test report
generate_report
