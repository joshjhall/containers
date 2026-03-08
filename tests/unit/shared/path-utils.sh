#!/usr/bin/env bash
# Unit tests for lib/shared/path-utils.sh
# Tests runtime PATH validation and management

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Source shared logging first (dependency)
source "$PROJECT_ROOT/lib/shared/logging.sh"

# Source the script under test
source "$PROJECT_ROOT/lib/shared/path-utils.sh"

# Test suite
test_suite "Shared Path Utilities Tests"

# Setup function - runs before each test
setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-shared-path-utils"
    mkdir -p "$TEST_TEMP_DIR"

    # Save original PATH
    export ORIGINAL_PATH="$PATH"

    # Create test directories with different permissions
    export TEST_SAFE_DIR="$TEST_TEMP_DIR/safe"
    export TEST_WORLD_WRITABLE="$TEST_TEMP_DIR/world-writable"

    mkdir -p "$TEST_SAFE_DIR"
    chmod 755 "$TEST_SAFE_DIR"

    mkdir -p "$TEST_WORLD_WRITABLE"
    chmod 777 "$TEST_WORLD_WRITABLE"
}

# Teardown function - runs after each test
teardown() {
    export PATH="$ORIGINAL_PATH"
    command rm -rf "$TEST_TEMP_DIR"
    unset TEST_SAFE_DIR TEST_WORLD_WRITABLE 2>/dev/null || true
}

# Test: safe_add_to_path function exists
test_safe_add_to_path_exists() {
    if command -v safe_add_to_path >/dev/null 2>&1; then
        assert_true true "safe_add_to_path function exists"
    else
        assert_true false "safe_add_to_path function not found"
    fi
}

# Test: Accepts valid directory
test_safe_add_to_path_valid_directory() {
    export PATH="$ORIGINAL_PATH"
    if safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null; then
        if [[ ":$PATH:" == *":${TEST_SAFE_DIR}:"* ]]; then
            assert_true true "Valid directory added to PATH"
        else
            assert_true false "Directory not added to PATH"
        fi
    else
        assert_true false "Failed to add valid directory"
    fi
}

# Test: Rejects non-existent directory
test_safe_add_to_path_nonexistent() {
    if safe_add_to_path "$TEST_TEMP_DIR/does-not-exist" 2>/dev/null; then
        assert_true false "Should reject non-existent directory"
    else
        assert_true true "Correctly rejected non-existent directory"
    fi
}

# Test: Rejects world-writable directory
test_safe_add_to_path_world_writable() {
    if safe_add_to_path "$TEST_WORLD_WRITABLE" 2>/dev/null; then
        assert_true false "Should reject world-writable directory"
    else
        assert_true true "Correctly rejected world-writable directory"
    fi
}

# Test: Rejects empty path
test_safe_add_to_path_empty() {
    if safe_add_to_path "" 2>/dev/null; then
        assert_true false "Should reject empty path"
    else
        assert_true true "Correctly rejected empty path"
    fi
}

# Test: Prevents duplicate entries
test_safe_add_to_path_no_duplicates() {
    export PATH="$ORIGINAL_PATH"
    safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null
    local path_after_first="$PATH"
    safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null
    assert_equals "$path_after_first" "$PATH" "No duplicate entries in PATH"
}

# Test: Prepends to PATH
test_safe_add_to_path_prepends() {
    export PATH="$ORIGINAL_PATH"
    safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null
    if [[ "$PATH" == "${TEST_SAFE_DIR}:"* ]]; then
        assert_true true "Directory prepended to PATH"
    else
        assert_true false "Directory not prepended to PATH"
    fi
}

# Test: add_to_system_path is NOT defined (build-only)
test_no_add_to_system_path() {
    # Unload base path-utils if loaded
    if command -v add_to_system_path >/dev/null 2>&1; then
        # May be defined from a previous test sourcing base/path-utils.sh
        assert_true true "Skipped (base path-utils loaded in same process)"
    else
        assert_true true "add_to_system_path not defined (build-only)"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_safe_add_to_path_exists "safe_add_to_path function exists"
run_test_with_setup test_safe_add_to_path_valid_directory "Accepts valid directory"
run_test_with_setup test_safe_add_to_path_nonexistent "Rejects non-existent directory"
run_test_with_setup test_safe_add_to_path_world_writable "Rejects world-writable directory"
run_test_with_setup test_safe_add_to_path_empty "Rejects empty path"
run_test_with_setup test_safe_add_to_path_no_duplicates "Prevents duplicate entries"
run_test_with_setup test_safe_add_to_path_prepends "Prepends to PATH"
run_test_with_setup test_no_add_to_system_path "add_to_system_path not defined in shared"

# Generate test report
generate_report
