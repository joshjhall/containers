#!/usr/bin/env bash
# Unit tests for detect-case-sensitivity.sh
#
# Tests the case-sensitivity detection utility that checks if filesystems
# are case-sensitive or case-insensitive

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Case-Sensitivity Detection Utility"

# Source the script under test
DETECT_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../../bin/detect-case-sensitivity.sh"

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    # Create temporary test directory
    TEST_DIR=$(mktemp -d)
}

teardown() {
    # Clean up test directory
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        command rm -rf "$TEST_DIR"
    fi
}

# ============================================================================
# Basic Functionality Tests
# ============================================================================

test_detect_script_exists() {
    if [ -f "$DETECT_SCRIPT" ]; then
        return 0
    else
        fail "detect-case-sensitivity.sh not found at $DETECT_SCRIPT"
    fi
}

test_detect_script_executable() {
    if [ -x "$DETECT_SCRIPT" ]; then
        return 0
    else
        fail "detect-case-sensitivity.sh is not executable"
    fi
}

test_detect_with_valid_directory() {
    # Test with a valid writable directory
    if QUIET=true "$DETECT_SCRIPT" "$TEST_DIR" >/dev/null 2>&1; then
        # Exit code 0 = case-sensitive (expected on Linux)
        # or exit code 1 = case-insensitive (if testing on macOS/Windows)
        return 0
    else
        local exit_code=$?
        if [ "$exit_code" -eq 1 ]; then
            # Case-insensitive filesystem (valid result)
            return 0
        else
            fail "Unexpected exit code: $exit_code"
        fi
    fi
}

test_detect_with_nonexistent_directory() {
    # Test with non-existent directory
    if QUIET=true "$DETECT_SCRIPT" "/nonexistent/path" >/dev/null 2>&1; then
        fail "Should fail with non-existent directory"
    else
        local exit_code=$?
        assert_equals 2 "$exit_code" "Should exit with code 2 for non-existent path"
    fi
}

test_detect_with_readonly_directory() {
    # Create a read-only directory
    local readonly_dir="$TEST_DIR/readonly"
    mkdir -p "$readonly_dir"
    chmod 555 "$readonly_dir"

    # Test with read-only directory
    if QUIET=true "$DETECT_SCRIPT" "$readonly_dir" >/dev/null 2>&1; then
        fail "Should fail with read-only directory"
    else
        local exit_code=$?
        assert_equals 2 "$exit_code" "Should exit with code 2 for read-only directory"
    fi

    # Restore permissions for cleanup
    chmod 755 "$readonly_dir"
}

# ============================================================================
# Output Format Tests
# ============================================================================

test_quiet_mode_suppresses_output() {
    # Quiet mode should suppress all output
    local output
    output=$(QUIET=true "$DETECT_SCRIPT" "$TEST_DIR" 2>&1 || true)

    if [ -z "$output" ]; then
        return 0
    else
        fail "Quiet mode should suppress output, but got: $output"
    fi
}

test_verbose_mode_shows_output() {
    # Non-quiet mode should show output
    local output
    output=$(QUIET=false "$DETECT_SCRIPT" "$TEST_DIR" 2>&1 || true)

    if [ -n "$output" ]; then
        return 0
    else
        fail "Verbose mode should show output"
    fi
}

test_output_includes_path_info() {
    # Output should mention the path being tested
    local output
    output=$(QUIET=false "$DETECT_SCRIPT" "$TEST_DIR" 2>&1 || true)

    if echo "$output" | command grep -q "$TEST_DIR"; then
        return 0
    else
        fail "Output should include the tested path"
    fi
}

# ============================================================================
# Cleanup Tests
# ============================================================================

test_cleanup_removes_test_files() {
    # Run detection
    QUIET=true "$DETECT_SCRIPT" "$TEST_DIR" >/dev/null 2>&1 || true

    # Check that no .case-test files remain (using command find to avoid aliases)
    local test_files
    test_files=$(command find "$TEST_DIR" -maxdepth 1 -name ".case-test-*" 2>/dev/null | command wc -l)

    assert_equals 0 "$test_files" "Test files should be cleaned up"
}

test_cleanup_on_error() {
    # Even if script fails, test files should be cleaned up
    # Force an error by using a read-only directory
    local readonly_dir="$TEST_DIR/readonly"
    mkdir -p "$readonly_dir"
    chmod 555 "$readonly_dir"

    # Run and expect failure
    QUIET=true "$DETECT_SCRIPT" "$readonly_dir" >/dev/null 2>&1 || true

    # Restore permissions to check cleanup
    chmod 755 "$readonly_dir"

    # Check that no .case-test files remain (using command find to avoid aliases)
    local test_files
    test_files=$(command find "$readonly_dir" -maxdepth 1 -name ".case-test-*" 2>/dev/null | command wc -l)

    assert_equals 0 "$test_files" "Test files should be cleaned up even on error"
}

# ============================================================================
# Edge Cases
# ============================================================================

test_default_path_is_workspace() {
    # When run without arguments, should default to /workspace
    # This test only works if /workspace exists and is writable
    if [ -d "/workspace" ] && [ -w "/workspace" ]; then
        # Run without arguments
        local output
        output=$(QUIET=false "$DETECT_SCRIPT" 2>&1 || true)

        if echo "$output" | command grep -q "/workspace"; then
            return 0
        else
            fail "Default should be /workspace"
        fi
    else
        # Skip test if /workspace doesn't exist or isn't writable
        skip "Test requires writable /workspace directory"
    fi
}

test_handles_path_with_spaces() {
    # Create directory with spaces in name
    local space_dir="$TEST_DIR/dir with spaces"
    mkdir -p "$space_dir"

    # Test detection
    if QUIET=true "$DETECT_SCRIPT" "$space_dir" >/dev/null 2>&1; then
        return 0
    else
        local exit_code=$?
        if [ "$exit_code" -eq 1 ]; then
            # Case-insensitive (valid result)
            return 0
        else
            fail "Should handle paths with spaces"
        fi
    fi
}

test_handles_deep_nested_path() {
    # Create deeply nested directory
    local deep_dir="$TEST_DIR/a/b/c/d/e/f/g"
    mkdir -p "$deep_dir"

    # Test detection
    if QUIET=true "$DETECT_SCRIPT" "$deep_dir" >/dev/null 2>&1; then
        return 0
    else
        local exit_code=$?
        if [ "$exit_code" -eq 1 ]; then
            # Case-insensitive (valid result)
            return 0
        else
            fail "Should handle deeply nested paths"
        fi
    fi
}

# ============================================================================
# Exit Code Tests
# ============================================================================

test_exit_code_0_for_case_sensitive() {
    # On Linux, should return 0 (case-sensitive)
    # On macOS/Windows, might return 1 (case-insensitive)
    QUIET=true "$DETECT_SCRIPT" "$TEST_DIR" >/dev/null 2>&1
    local exit_code=$?

    # Accept both 0 (case-sensitive) and 1 (case-insensitive) as valid
    if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 1 ]; then
        return 0
    else
        fail "Exit code should be 0 or 1, got: $exit_code"
    fi
}

test_exit_code_2_for_errors() {
    # Non-existent path should return 2
    QUIET=true "$DETECT_SCRIPT" "/nonexistent/path" >/dev/null 2>&1
    local exit_code=$?

    assert_equals 2 "$exit_code" "Error cases should exit with code 2"
}

# ============================================================================
# Run Tests
# ============================================================================

# Basic functionality
run_test test_detect_script_exists "Script exists"
run_test test_detect_script_executable "Script is executable"
run_test test_detect_with_valid_directory "Detects valid directory"
run_test test_detect_with_nonexistent_directory "Fails on non-existent directory"
run_test test_detect_with_readonly_directory "Fails on read-only directory"

# Output format
run_test test_quiet_mode_suppresses_output "Quiet mode suppresses output"
run_test test_verbose_mode_shows_output "Verbose mode shows output"
run_test test_output_includes_path_info "Output includes path info"

# Cleanup
run_test test_cleanup_removes_test_files "Cleanup removes test files"
run_test test_cleanup_on_error "Cleanup on error"

# Edge cases
run_test test_default_path_is_workspace "Default path is /workspace"
run_test test_handles_path_with_spaces "Handles paths with spaces"
run_test test_handles_deep_nested_path "Handles deeply nested paths"

# Exit codes
run_test test_exit_code_0_for_case_sensitive "Exit code 0 or 1 for success"
run_test test_exit_code_2_for_errors "Exit code 2 for errors"

# Generate test report
generate_report
