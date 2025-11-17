#!/bin/bash
# Unit tests for lib/base/path-utils.sh
# Tests PATH manipulation and security validation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Source the script under test
source "$PROJECT_ROOT/lib/base/logging.sh"
source "$PROJECT_ROOT/lib/base/path-utils.sh"

# Test suite
test_suite "Path Utilities Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-path-utils"
    mkdir -p "$TEST_TEMP_DIR"

    # Save original PATH
    export ORIGINAL_PATH="$PATH"

    # Create test directories with different permissions
    export TEST_SAFE_DIR="$TEST_TEMP_DIR/safe"
    export TEST_WORLD_WRITABLE="$TEST_TEMP_DIR/world-writable"
    export TEST_OTHER_OWNER="$TEST_TEMP_DIR/other-owner"

    mkdir -p "$TEST_SAFE_DIR"
    chmod 755 "$TEST_SAFE_DIR"

    mkdir -p "$TEST_WORLD_WRITABLE"
    chmod 777 "$TEST_WORLD_WRITABLE"
}

# Teardown function - runs after each test
teardown() {
    # Restore original PATH
    export PATH="$ORIGINAL_PATH"

    # Clean up test directory
    command rm -rf "$TEST_TEMP_DIR"

    # Unset test variables
    unset TEST_SAFE_DIR TEST_WORLD_WRITABLE TEST_OTHER_OWNER 2>/dev/null || true
}

# ============================================================================
# safe_add_to_path Tests
# ============================================================================

# Test: Function exists
test_safe_add_to_path_exists() {
    if command -v safe_add_to_path >/dev/null 2>&1; then
        assert_true true "safe_add_to_path function exists"
    else
        assert_true false "safe_add_to_path function not found"
    fi
}

# Test: Accepts valid directory
test_safe_add_to_path_valid_directory() {
    # Reset PATH
    export PATH="$ORIGINAL_PATH"

    # Add safe directory
    if safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null; then
        # Check if added to PATH
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
    local nonexistent="$TEST_TEMP_DIR/does-not-exist"

    if safe_add_to_path "$nonexistent" 2>/dev/null; then
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
        assert_true true "Correctly rejected world-writable directory (777)"
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
    # Reset PATH
    export PATH="$ORIGINAL_PATH"

    # Add directory twice
    safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null
    local path_after_first="$PATH"

    safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null
    local path_after_second="$PATH"

    # PATH should be unchanged after second add
    assert_equals "$path_after_first" "$path_after_second" "No duplicate entries in PATH"
}

# Test: Prepends to PATH (precedence)
test_safe_add_to_path_prepends() {
    # Reset PATH
    export PATH="$ORIGINAL_PATH"

    # Add directory
    safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null

    # Check if it's at the beginning
    if [[ "$PATH" == "${TEST_SAFE_DIR}:"* ]]; then
        assert_true true "Directory prepended to PATH for precedence"
    else
        assert_true false "Directory not prepended to PATH"
    fi
}

# Test: Validates ownership (root-owned directories should be allowed)
test_safe_add_to_path_root_owned() {
    # Test with /usr/bin which is root-owned
    if [ -d "/usr/bin" ]; then
        # Reset PATH to not include /usr/bin
        export PATH="/bin:/sbin"

        if safe_add_to_path "/usr/bin" 2>/dev/null; then
            assert_true true "Root-owned directory allowed"
        else
            assert_true false "Root-owned directory rejected"
        fi
    else
        assert_true true "Skipped (test directory not available)"
    fi
}

# Test: Validates current user ownership
test_safe_add_to_path_user_owned() {
    # Our test directory should be owned by current user
    if safe_add_to_path "$TEST_SAFE_DIR" 2>/dev/null; then
        assert_true true "User-owned directory allowed"
    else
        assert_true false "User-owned directory rejected"
    fi
}

# Test: Permission check works correctly
test_safe_add_to_path_permission_check() {
    # Create directory with different permission levels
    local test_dir="$TEST_TEMP_DIR/perm-test"

    # Test 755 (safe)
    mkdir -p "$test_dir"
    chmod 755 "$test_dir"

    if safe_add_to_path "$test_dir" 2>/dev/null; then
        assert_true true "Permission 755 allowed"
    else
        assert_true false "Permission 755 rejected incorrectly"
    fi

    # Change to 775 (group-writable, should be OK)
    chmod 775 "$test_dir"
    export PATH="$ORIGINAL_PATH"  # Reset

    if safe_add_to_path "$test_dir" 2>/dev/null; then
        assert_true true "Permission 775 allowed"
    else
        assert_true false "Permission 775 rejected incorrectly"
    fi

    # Change to 757 (world-writable, should fail)
    chmod 757 "$test_dir"
    export PATH="$ORIGINAL_PATH"  # Reset

    if safe_add_to_path "$test_dir" 2>/dev/null; then
        assert_true false "Permission 757 should be rejected (world-writable)"
    else
        assert_true true "Permission 757 correctly rejected"
    fi
}

# ============================================================================
# add_to_system_path Tests
# ============================================================================

# Test: Function exists
test_add_to_system_path_exists() {
    if command -v add_to_system_path >/dev/null 2>&1; then
        assert_true true "add_to_system_path function exists"
    else
        assert_true false "add_to_system_path function not found"
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
run_test_with_setup test_safe_add_to_path_prepends "Prepends to PATH for precedence"
run_test_with_setup test_safe_add_to_path_root_owned "Allows root-owned directories"
run_test_with_setup test_safe_add_to_path_user_owned "Allows user-owned directories"
run_test_with_setup test_safe_add_to_path_permission_check "Permission validation works"
run_test_with_setup test_add_to_system_path_exists "add_to_system_path function exists"

# Generate test report
generate_report
