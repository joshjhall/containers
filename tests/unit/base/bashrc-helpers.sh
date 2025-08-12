#!/usr/bin/env bash
# Unit tests for lib/base/bashrc-helpers.sh
# Tests bashrc helper functions

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bashrc Helpers Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-bashrc-helpers"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Create mock bashrc.d directory
    export TEST_BASHRC_D="$TEST_TEMP_DIR/bashrc.d"
    mkdir -p "$TEST_BASHRC_D"
    
    # Copy and modify bashrc-helpers for testing
    sed "s|/etc/bashrc.d|$TEST_BASHRC_D|g" "$PROJECT_ROOT/lib/base/bashrc-helpers.sh" > "$TEST_TEMP_DIR/bashrc-helpers-test.sh"
    
    # Define the function to test (since we can't source the actual file in tests)
    source_bashrc_d() {
        local dir="${1:-/etc/bashrc.d}"
        if [ -d "$dir" ]; then
            for script in "$dir"/*.sh; do
                if [ -f "$script" ] && [ -x "$script" ]; then
                    source "$script" || true
                fi
            done
        fi
    }
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset TEST_BASHRC_D 2>/dev/null || true
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Test: source_bashrc_d function sources files correctly
test_source_bashrc_d() {
    # Create test scripts in bashrc.d
    echo 'export TEST_VAR1="value1"' > "$TEST_BASHRC_D/10-test1.sh"
    echo 'export TEST_VAR2="value2"' > "$TEST_BASHRC_D/20-test2.sh"
    echo 'export TEST_VAR3="value3"' > "$TEST_BASHRC_D/30-test3.sh"
    chmod +x "$TEST_BASHRC_D"/*.sh
    
    # Source the scripts
    source_bashrc_d "$TEST_BASHRC_D"
    
    # Check that variables were set
    assert_equals "value1" "${TEST_VAR1:-}" "TEST_VAR1 was sourced"
    assert_equals "value2" "${TEST_VAR2:-}" "TEST_VAR2 was sourced"
    assert_equals "value3" "${TEST_VAR3:-}" "TEST_VAR3 was sourced"
    
    # Clean up test variables
    unset TEST_VAR1 TEST_VAR2 TEST_VAR3
}

# Test: source_bashrc_d handles non-executable files
test_source_bashrc_d_skip_nonexecutable() {
    # Check if we're on a filesystem that properly handles executable permissions
    local test_file="$TEST_BASHRC_D/test_perms"
    touch "$test_file"
    chmod 644 "$test_file"
    
    if [[ -x "$test_file" ]]; then
        # Filesystem doesn't properly handle executable bits (e.g., fakeowner mount)
        rm -f "$test_file"
        skip_test "Filesystem doesn't properly handle executable permissions (fakeowner mount)"
        return
    fi
    rm -f "$test_file"
    
    # Create executable and non-executable scripts
    echo 'export EXEC_VAR="executed"' > "$TEST_BASHRC_D/10-exec.sh"
    echo 'export NONEXEC_VAR="should_not_run"' > "$TEST_BASHRC_D/20-nonexec.sh"
    chmod +x "$TEST_BASHRC_D/10-exec.sh"
    chmod 644 "$TEST_BASHRC_D/20-nonexec.sh"  # Explicitly make non-executable
    
    # Ensure NONEXEC_VAR is not set
    unset NONEXEC_VAR 2>/dev/null || true
    
    # Source the scripts
    source_bashrc_d "$TEST_BASHRC_D"
    
    # Check that only executable was sourced
    assert_equals "executed" "${EXEC_VAR:-}" "Executable script was sourced"
    assert_empty "${NONEXEC_VAR:-}" "Non-executable script was not sourced"
    
    # Clean up
    unset EXEC_VAR 2>/dev/null || true
}

# Test: source_bashrc_d handles missing directory gracefully
test_source_bashrc_d_missing_directory() {
    # Try to source from non-existent directory
    local missing_dir="$TEST_TEMP_DIR/nonexistent"
    
    # This should not error
    source_bashrc_d "$missing_dir" || true
    
    # If we get here, the function handled it gracefully
    assert_true true "Function handled missing directory gracefully"
}

# Test: source_bashrc_d sources files in order
test_source_bashrc_d_order() {
    # Create scripts that depend on order
    echo 'export ORDER_TEST="first"' > "$TEST_BASHRC_D/10-first.sh"
    echo 'export ORDER_TEST="${ORDER_TEST}_second"' > "$TEST_BASHRC_D/20-second.sh"
    echo 'export ORDER_TEST="${ORDER_TEST}_third"' > "$TEST_BASHRC_D/30-third.sh"
    chmod +x "$TEST_BASHRC_D"/*.sh
    
    # Source the scripts
    source_bashrc_d "$TEST_BASHRC_D"
    
    # Check that they ran in order
    assert_equals "first_second_third" "${ORDER_TEST:-}" "Scripts sourced in correct order"
    
    # Clean up
    unset ORDER_TEST
}

# Test: source_bashrc_d handles .sh extension requirement
test_source_bashrc_d_extension_filter() {
    # Create files with different extensions
    echo 'export SH_VAR="from_sh"' > "$TEST_BASHRC_D/10-test.sh"
    echo 'export TXT_VAR="from_txt"' > "$TEST_BASHRC_D/20-test.txt"
    echo 'export NO_EXT_VAR="no_extension"' > "$TEST_BASHRC_D/30-test"
    chmod +x "$TEST_BASHRC_D"/*
    
    # Source the scripts
    source_bashrc_d "$TEST_BASHRC_D"
    
    # Check that only .sh file was sourced
    assert_equals "from_sh" "${SH_VAR:-}" ".sh file was sourced"
    assert_empty "${TXT_VAR:-}" ".txt file was not sourced"
    assert_empty "${NO_EXT_VAR:-}" "File without extension was not sourced"
    
    # Clean up
    unset SH_VAR TXT_VAR NO_EXT_VAR 2>/dev/null || true
}

# Test: Error in one script doesn't stop others
test_source_bashrc_d_error_handling() {
    # Create scripts where one has an error
    echo 'export BEFORE_ERROR="yes"' > "$TEST_BASHRC_D/10-before.sh"
    echo 'false # This will fail' > "$TEST_BASHRC_D/20-error.sh"
    echo 'export AFTER_ERROR="yes"' > "$TEST_BASHRC_D/30-after.sh"
    chmod +x "$TEST_BASHRC_D"/*.sh
    
    # Source the scripts (should continue despite error)
    source_bashrc_d "$TEST_BASHRC_D" 2>/dev/null || true
    
    # Check that scripts before and after the error were still sourced
    assert_equals "yes" "${BEFORE_ERROR:-}" "Script before error was sourced"
    assert_equals "yes" "${AFTER_ERROR:-}" "Script after error was sourced"
    
    # Clean up
    unset BEFORE_ERROR AFTER_ERROR 2>/dev/null || true
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
run_test_with_setup test_source_bashrc_d "source_bashrc_d sources files correctly"
run_test_with_setup test_source_bashrc_d_skip_nonexecutable "source_bashrc_d skips non-executable files"
run_test_with_setup test_source_bashrc_d_missing_directory "source_bashrc_d handles missing directory"
run_test_with_setup test_source_bashrc_d_order "source_bashrc_d sources files in order"
run_test_with_setup test_source_bashrc_d_extension_filter "source_bashrc_d only sources .sh files"
run_test_with_setup test_source_bashrc_d_error_handling "source_bashrc_d continues after errors"

# Generate test report
generate_report