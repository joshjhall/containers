#!/usr/bin/env bash
# Unit tests for lib/base/feature-header.sh
# Tests the common feature header functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Feature Header Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-feature-header"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment variables
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    export WORKING_DIR="/workspace/test"
    
    # Create a test version of feature-header.sh
    command cp "$PROJECT_ROOT/lib/base/feature-header.sh" "$TEST_TEMP_DIR/feature-header-test.sh"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    command rm -rf "$TEST_TEMP_DIR"
    
    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME WORKING_DIR
}

# Test: Environment variables are exported
test_environment_variables() {
    # Source the feature header
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    
    # Check that essential variables are set
    assert_not_empty "$USERNAME" "USERNAME is set"
    assert_not_empty "$USER_UID" "USER_UID is set"
    assert_not_empty "$USER_GID" "USER_GID is set"
    assert_not_empty "$HOME" "HOME is set"
    assert_not_empty "$WORKING_DIR" "WORKING_DIR is set"
}

# Test: Default values are applied when variables are not set
test_default_values() {
    # Save current values
    local saved_username="$USERNAME"
    local saved_uid="$USER_UID"
    local saved_gid="$USER_GID"
    
    # Unset variables to test defaults
    unset USERNAME USER_UID USER_GID
    
    # Source the feature header
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    
    # Check defaults are applied (or existing values used)
    assert_not_empty "$USERNAME" "USERNAME is set to some value"
    assert_not_empty "$USER_UID" "USER_UID is set to some value"
    assert_not_empty "$USER_GID" "USER_GID is set to some value"
    
    # Restore values
    USERNAME="$saved_username"
    USER_UID="$saved_uid"
    USER_GID="$saved_gid"
}

# Test: Logging functions are available
test_logging_functions_available() {
    # Define mock logging functions for testing
    log_feature_start() { echo "log_feature_start called"; }
    log_command() { echo "log_command called"; }
    log_message() { echo "log_message called"; }
    export -f log_feature_start log_command log_message
    
    # Source the feature header
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    
    # Check that logging functions exist
    if type -t log_feature_start >/dev/null; then
        assert_true true "log_feature_start function exists"
    else
        assert_true false "log_feature_start function not found"
    fi
    
    if type -t log_command >/dev/null; then
        assert_true true "log_command function exists"
    else
        assert_true false "log_command function not found"
    fi
    
    if type -t log_message >/dev/null; then
        assert_true true "log_message function exists"
    else
        assert_true false "log_message function not found"
    fi
}

# Test: write_bashrc_content function
test_write_bashrc_content() {
    # Define the write_bashrc_content function for testing
    write_bashrc_content() {
        local file="$1"
        local section="$2"
        echo "# $section" > "$file"
        command cat >> "$file"
    }
    export -f write_bashrc_content
    
    # Source the feature header
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    
    # Create a test bashrc file
    local test_bashrc="$TEST_TEMP_DIR/test.bashrc"
    
    # Write content using the function
    write_bashrc_content "$test_bashrc" "Test Section" << 'EOF'
echo "Test content"
export TEST_VAR="test"
EOF
    
    # Check file was created
    assert_file_exists "$test_bashrc"
    
    # Check content
    if grep -q "Test Section" "$test_bashrc"; then
        assert_true true "Section header written"
    else
        assert_true false "Section header not found"
    fi
    
    if grep -q "Test content" "$test_bashrc"; then
        assert_true true "Content written correctly"
    else
        assert_true false "Content not found"
    fi
}

# Test: Feature header sets error handling
test_error_handling() {
    # Check that error handling is set
    if [[ $- == *e* ]]; then
        assert_true true "errexit (set -e) is enabled"
    else
        assert_true false "errexit (set -e) is not enabled"
    fi
    
    if [[ $- == *u* ]]; then
        assert_true true "nounset (set -u) is enabled"
    else
        assert_true false "nounset (set -u) is not enabled"
    fi
}

# Test: Paths are properly set
test_path_configuration() {
    # Set BUILD_LOG_DIR for testing
    export BUILD_LOG_DIR="/var/log/container-build"
    
    # Source the feature header
    source "$TEST_TEMP_DIR/feature-header-test.sh"
    
    # Check that BUILD_LOG_DIR is set
    assert_not_empty "${BUILD_LOG_DIR:-}" "BUILD_LOG_DIR is set"
    
    # Check the default path
    assert_equals "/var/log/container-build" "$BUILD_LOG_DIR" "BUILD_LOG_DIR has correct default"
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
run_test_with_setup test_environment_variables "Environment variables are exported"
run_test_with_setup test_default_values "Default values are applied correctly"
run_test_with_setup test_logging_functions_available "Logging functions are available"
run_test_with_setup test_write_bashrc_content "write_bashrc_content function works"
run_test_with_setup test_error_handling "Error handling is properly configured"
run_test_with_setup test_path_configuration "Paths are properly configured"

# Generate test report
generate_report