#!/usr/bin/env bash
# Unit tests for lib/shared/logging.sh
# Tests lightweight runtime logging functions

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Shared Logging Tests"

# Setup function - runs before each test
setup() {
    # Unset include guard so re-sourcing works across tests
    unset _SHARED_LOGGING_LOADED 2>/dev/null || true

    # Source the shared logging module
    source "$PROJECT_ROOT/lib/shared/logging.sh"
}

# Teardown function - runs after each test
teardown() {
    unset _SHARED_LOGGING_LOADED 2>/dev/null || true
    unset LOG_LEVEL 2>/dev/null || true
}

# Test: log level constants are defined
test_log_level_constants() {
    assert_equals "0" "$LOG_LEVEL_ERROR" "LOG_LEVEL_ERROR is 0"
    assert_equals "1" "$LOG_LEVEL_WARN" "LOG_LEVEL_WARN is 1"
    assert_equals "2" "$LOG_LEVEL_INFO" "LOG_LEVEL_INFO is 2"
    assert_equals "3" "$LOG_LEVEL_DEBUG" "LOG_LEVEL_DEBUG is 3"
}

# Test: _get_log_level_num defaults to INFO
test_get_log_level_num_default() {
    unset LOG_LEVEL 2>/dev/null || true
    local result
    result=$(_get_log_level_num)
    assert_equals "2" "$result" "Default log level is INFO (2)"
}

# Test: _get_log_level_num with various inputs
test_get_log_level_num_values() {
    LOG_LEVEL=ERROR
    assert_equals "0" "$(_get_log_level_num)" "ERROR maps to 0"

    LOG_LEVEL=WARN
    assert_equals "1" "$(_get_log_level_num)" "WARN maps to 1"

    LOG_LEVEL=INFO
    assert_equals "2" "$(_get_log_level_num)" "INFO maps to 2"

    LOG_LEVEL=DEBUG
    assert_equals "3" "$(_get_log_level_num)" "DEBUG maps to 3"

    LOG_LEVEL=invalid
    assert_equals "2" "$(_get_log_level_num)" "Invalid maps to INFO (2)"
}

# Test: _should_log respects log levels
test_should_log() {
    LOG_LEVEL=WARN
    if _should_log $LOG_LEVEL_ERROR; then
        assert_true true "ERROR messages shown at WARN level"
    else
        assert_true false "ERROR messages should be shown at WARN level"
    fi

    if _should_log $LOG_LEVEL_INFO; then
        assert_true false "INFO messages should not be shown at WARN level"
    else
        assert_true true "INFO messages suppressed at WARN level"
    fi
}

# Test: log_message outputs to stdout
test_log_message_output() {
    export LOG_LEVEL=INFO
    local output
    output=$(log_message "test message" 2>/dev/null)
    if [[ "$output" == *"test message"* ]]; then
        assert_true true "log_message outputs message"
    else
        assert_true false "log_message did not output expected message"
    fi
}

# Test: log_message suppressed at ERROR level
test_log_message_suppressed() {
    export LOG_LEVEL=ERROR
    local output
    output=$(log_message "should not appear" 2>/dev/null)
    if [ -z "$output" ]; then
        assert_true true "log_message suppressed at ERROR level"
    else
        assert_true false "log_message should be suppressed at ERROR level"
    fi
}

# Test: log_info is alias for log_message
test_log_info() {
    export LOG_LEVEL=INFO
    local output
    output=$(log_info "info message" 2>/dev/null)
    if [[ "$output" == *"info message"* ]]; then
        assert_true true "log_info outputs message"
    else
        assert_true false "log_info did not output expected message"
    fi
}

# Test: log_debug only shown at DEBUG level
test_log_debug() {
    export LOG_LEVEL=DEBUG
    local output
    output=$(log_debug "debug msg" 2>/dev/null)
    if [[ "$output" == *"DEBUG: debug msg"* ]]; then
        assert_true true "log_debug shown at DEBUG level"
    else
        assert_true false "log_debug not shown at DEBUG level"
    fi

    export LOG_LEVEL=INFO
    output=$(log_debug "hidden debug" 2>/dev/null)
    if [ -z "$output" ]; then
        assert_true true "log_debug hidden at INFO level"
    else
        assert_true false "log_debug should be hidden at INFO level"
    fi
}

# Test: log_error outputs to stderr
test_log_error() {
    local output
    output=$(log_error "error msg" 2>&1 1>/dev/null)
    if [[ "$output" == *"ERROR: error msg"* ]]; then
        assert_true true "log_error outputs to stderr"
    else
        assert_true false "log_error did not output expected error"
    fi
}

# Test: log_warning outputs to stderr
test_log_warning() {
    export LOG_LEVEL=WARN
    local output
    output=$(log_warning "warn msg" 2>&1 1>/dev/null)
    if [[ "$output" == *"WARNING: warn msg"* ]]; then
        assert_true true "log_warning outputs to stderr"
    else
        assert_true false "log_warning did not output expected warning"
    fi
}

# Test: log_warning suppressed at ERROR level
test_log_warning_suppressed() {
    export LOG_LEVEL=ERROR
    local output
    output=$(log_warning "hidden warn" 2>&1)
    if [ -z "$output" ]; then
        assert_true true "log_warning suppressed at ERROR level"
    else
        assert_true false "log_warning should be suppressed at ERROR level"
    fi
}

# Test: shared logging file does not contain build-time functions
test_no_build_functions_in_file() {
    local shared_file="$PROJECT_ROOT/lib/shared/logging.sh"
    if command grep -q "log_feature_start" "$shared_file"; then
        assert_true false "log_feature_start should not be in shared/logging.sh"
    else
        assert_true true "log_feature_start not in shared/logging.sh (build-only)"
    fi

    if command grep -q "log_command" "$shared_file"; then
        assert_true false "log_command should not be in shared/logging.sh"
    else
        assert_true true "log_command not in shared/logging.sh (build-only)"
    fi
}

# Test: functions are exported
test_functions_exported() {
    if declare -F log_message >/dev/null 2>&1; then
        assert_true true "log_message is defined"
    else
        assert_true false "log_message not defined"
    fi

    if declare -F _get_log_level_num >/dev/null 2>&1; then
        assert_true true "_get_log_level_num is defined"
    else
        assert_true false "_get_log_level_num not defined"
    fi

    if declare -F _should_log >/dev/null 2>&1; then
        assert_true true "_should_log is defined"
    else
        assert_true false "_should_log not defined"
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
run_test_with_setup test_log_level_constants "Log level constants are defined"
run_test_with_setup test_get_log_level_num_default "Default log level is INFO"
run_test_with_setup test_get_log_level_num_values "Log level string to numeric mapping"
run_test_with_setup test_should_log "Log level filtering works"
run_test_with_setup test_log_message_output "log_message outputs to stdout"
run_test_with_setup test_log_message_suppressed "log_message suppressed at ERROR level"
run_test_with_setup test_log_info "log_info is alias for log_message"
run_test_with_setup test_log_debug "log_debug respects log level"
run_test_with_setup test_log_error "log_error outputs to stderr"
run_test_with_setup test_log_warning "log_warning outputs to stderr"
run_test_with_setup test_log_warning_suppressed "log_warning suppressed at ERROR level"
run_test_with_setup test_no_build_functions_in_file "Build-time functions not in shared file"
run_test_with_setup test_functions_exported "Core functions are exported"

# Generate test report
generate_report
