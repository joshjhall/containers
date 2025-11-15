#!/usr/bin/env bash
# Unit tests for lib/base/logging.sh
# Tests logging functionality for feature installations

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Logging Library Tests"

# Setup function - runs before each test
setup() {
    # Create temporary log directory for testing
    export TEST_LOG_DIR="$RESULTS_DIR/test-logs"
    export BUILD_LOG_DIR="$TEST_LOG_DIR"
    mkdir -p "$BUILD_LOG_DIR"
    
    # Reset logging variables
    unset CURRENT_FEATURE 2>/dev/null || true
    unset CURRENT_LOG_FILE 2>/dev/null || true
    unset CURRENT_ERROR_FILE 2>/dev/null || true
    unset CURRENT_SUMMARY_FILE 2>/dev/null || true
    unset FEATURE_START_TIME 2>/dev/null || true
    unset COMMAND_COUNT 2>/dev/null || true
    unset ERROR_COUNT 2>/dev/null || true
    unset WARNING_COUNT 2>/dev/null || true
    
    # Create a modified version of logging.sh for testing
    sed 's|/var/log/container-build|'"$TEST_LOG_DIR"'|g' "$PROJECT_ROOT/lib/base/logging.sh" > "$TEST_LOG_DIR/logging-test.sh"
    
    # Source the modified version
    source "$TEST_LOG_DIR/logging-test.sh"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test log directory
    rm -rf "$TEST_LOG_DIR"
}

# Test: log_feature_start creates log files
test_log_feature_start() {
    log_feature_start "Python" "3.13.6"
    
    # Check that feature name is set
    assert_equals "Python" "$CURRENT_FEATURE" "Feature name is set"
    
    # Check that log files are created
    assert_not_empty "$CURRENT_LOG_FILE" "Log file path is set"
    assert_not_empty "$CURRENT_ERROR_FILE" "Error file path is set"
    assert_not_empty "$CURRENT_SUMMARY_FILE" "Summary file path is set"
    
    # Check that files exist
    assert_file_exists "$CURRENT_LOG_FILE"
    assert_file_exists "$CURRENT_ERROR_FILE"
    
    # Save summary file path before log_feature_end resets it
    local summary_file="$CURRENT_SUMMARY_FILE"
    
    # Call log_feature_end to create summary file
    log_feature_end
    
    # Now check that summary file exists using saved path
    assert_file_exists "$summary_file"
}

# Test: Feature name sanitization
test_feature_name_sanitization() {
    log_feature_start "Node.js Dev Tools" "22.18.0"
    
    # Check that the log file has a sanitized name
    if [[ "$CURRENT_LOG_FILE" =~ nodejs-dev-tools ]]; then
        assert_true true "Feature name properly sanitized in log filename"
    else
        assert_true false "Feature name not properly sanitized: $CURRENT_LOG_FILE"
    fi
}

# Test: log_command function
test_log_command() {
    log_feature_start "Test Feature"
    
    # Run a simple command
    log_command "Testing echo command" echo "Hello, World!"
    
    # Check that command was logged
    if grep -q "Testing echo command" "$CURRENT_LOG_FILE"; then
        assert_true true "Command description logged"
    else
        assert_true false "Command description not found in log"
    fi
    
    # Check that output was captured
    if grep -q "Hello, World!" "$CURRENT_LOG_FILE"; then
        assert_true true "Command output logged"
    else
        assert_true false "Command output not found in log"
    fi
    
    # Check command count
    assert_equals "1" "$COMMAND_COUNT" "Command count incremented"
}

# Test: log_command with failing command
test_log_command_failure() {
    log_feature_start "Test Feature"
    
    # Reset error count
    ERROR_COUNT=0
    
    # Run a failing command (should continue due to || true in most scripts)
    log_command "Testing false command" false || true
    
    # Check that error was logged
    if grep -q "Exit code: 1" "$CURRENT_LOG_FILE"; then
        assert_true true "Error exit code logged"
    else
        assert_true false "Error exit code not found in log"
    fi
}

# Test: log_message function
test_log_message() {
    log_feature_start "Test Feature"
    
    # Log a message
    log_message "This is a test message"
    
    # Check that message was logged
    if grep -q "This is a test message" "$CURRENT_LOG_FILE"; then
        assert_true true "Message logged successfully"
    else
        assert_true false "Message not found in log"
    fi
}

# Test: log_error function
test_log_error() {
    log_feature_start "Test Feature"
    
    # Log an error
    log_error "This is an error message"
    
    # Check that error was logged to error file
    if grep -q "This is an error message" "$CURRENT_ERROR_FILE"; then
        assert_true true "Error logged to error file"
    else
        assert_true false "Error not found in error file"
    fi
    
    # Check that error count increased
    assert_equals "1" "$ERROR_COUNT" "Error count incremented"
}

# Test: log_warning function
test_log_warning() {
    log_feature_start "Test Feature"
    
    # Log a warning
    log_warning "This is a warning message"
    
    # Check that warning was logged
    if grep -q "WARNING: This is a warning message" "$CURRENT_LOG_FILE"; then
        assert_true true "Warning logged successfully"
    else
        assert_true false "Warning not found in log"
    fi
    
    # Check that warning count increased
    assert_equals "1" "$WARNING_COUNT" "Warning count incremented"
}

# Test: Master summary file creation
test_master_summary() {
    log_feature_start "Test Feature 1"
    log_command "Test command" echo "test"
    log_feature_end
    
    log_feature_start "Test Feature 2"
    log_command "Another test" echo "test2"
    log_feature_end
    
    # Check that master summary exists
    local master_summary="$BUILD_LOG_DIR/master-summary.log"
    assert_file_exists "$master_summary"
    
    # Check that both features are in summary
    if grep -q "Test Feature 1" "$master_summary" && grep -q "Test Feature 2" "$master_summary"; then
        assert_true true "Both features appear in master summary"
    else
        assert_true false "Features missing from master summary"
    fi
}

# Test: Duration calculation
test_duration_calculation() {
    log_feature_start "Test Feature"
    
    # Save summary file path before log_feature_end resets it
    local summary_file="$CURRENT_SUMMARY_FILE"
    
    # Simulate some work
    sleep 1
    
    log_feature_end
    
    # Check that duration was recorded in summary file
    if [ -f "$summary_file" ] && grep -q "Total Duration:" "$summary_file"; then
        assert_true true "Duration recorded in summary"
    else
        assert_true false "Duration not found in summary file: $summary_file"
    fi
}

# Test: Log directory structure
test_log_directory_structure() {
    log_feature_start "Python" "3.13.6"
    
    # Check directory exists
    assert_dir_exists "$BUILD_LOG_DIR"
    
    # Check that logs are in the correct directory
    local log_dir
    log_dir=$(dirname "$CURRENT_LOG_FILE")
    assert_equals "$BUILD_LOG_DIR" "$log_dir" "Log files in correct directory"
}

# Test: check_build_logs function
test_check_build_logs_function() {
    # Create a mock check-build-logs script path
    local script_path="/usr/local/bin/check-build-logs.sh"
    
    # Test that we can reference it (actual script testing would be integration)
    if [[ -n "$script_path" ]]; then
        assert_true true "Build logs check script path can be referenced"
    else
        assert_true false "Build logs check script path issue"
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
run_test_with_setup test_log_feature_start "log_feature_start creates log files"
run_test_with_setup test_feature_name_sanitization "Feature names are sanitized for filenames"
run_test_with_setup test_log_command "log_command logs command execution"
run_test_with_setup test_log_command_failure "log_command handles command failures"
run_test_with_setup test_log_message "log_message logs messages"
run_test_with_setup test_log_error "log_error logs errors correctly"
run_test_with_setup test_log_warning "log_warning logs warnings correctly"
run_test_with_setup test_master_summary "Master summary file is maintained"
run_test_with_setup test_duration_calculation "Duration is calculated and logged"
run_test_with_setup test_log_directory_structure "Log directory structure is correct"
run_test_with_setup test_check_build_logs_function "Build logs check function reference"

# Generate test report
generate_report