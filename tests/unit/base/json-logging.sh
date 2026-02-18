#!/usr/bin/env bash
# Unit tests for lib/base/json-logging.sh
# Tests JSON structured logging utilities for observability

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "JSON Logging Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/base/json-logging.sh"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-json-logging-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR ENABLE_JSON_LOGGING BUILD_LOG_DIR BUILD_CORRELATION_ID 2>/dev/null || true
    unset CURRENT_JSON_LOG_FILE JSON_LOG_DIR CURRENT_FEATURE 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Helper: run a subshell with JSON logging disabled (for json_escape tests)
_run_json_subshell() {
    bash -c "
        export BUILD_LOG_DIR='$TEST_TEMP_DIR'
        export ENABLE_JSON_LOGGING='false'
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "Script uses strict mode"
}

test_defines_json_escape() {
    assert_file_contains "$SOURCE_FILE" "json_escape()" \
        "Script defines json_escape function"
}

test_defines_json_log_init() {
    assert_file_contains "$SOURCE_FILE" "json_log_init()" \
        "Script defines json_log_init function"
}

test_defines_json_log_event() {
    assert_file_contains "$SOURCE_FILE" "json_log_event()" \
        "Script defines json_log_event function"
}

test_defines_json_log_command() {
    assert_file_contains "$SOURCE_FILE" "json_log_command()" \
        "Script defines json_log_command function"
}

test_defines_json_log_error() {
    assert_file_contains "$SOURCE_FILE" "json_log_error()" \
        "Script defines json_log_error function"
}

test_defines_json_log_warning() {
    assert_file_contains "$SOURCE_FILE" "json_log_warning()" \
        "Script defines json_log_warning function"
}

test_defines_json_log_feature_end() {
    assert_file_contains "$SOURCE_FILE" "json_log_feature_end()" \
        "Script defines json_log_feature_end function"
}

test_defines_json_log_build_metadata() {
    assert_file_contains "$SOURCE_FILE" "json_log_build_metadata()" \
        "Script defines json_log_build_metadata function"
}

test_exports_json_escape() {
    assert_file_contains "$SOURCE_FILE" "export -f json_escape" \
        "json_escape is exported"
}

test_exports_json_log_init() {
    assert_file_contains "$SOURCE_FILE" "export -f json_log_init" \
        "json_log_init is exported"
}

test_exports_json_log_event() {
    assert_file_contains "$SOURCE_FILE" "export -f json_log_event" \
        "json_log_event is exported"
}

test_exports_json_log_command() {
    assert_file_contains "$SOURCE_FILE" "export -f json_log_command" \
        "json_log_command is exported"
}

test_exports_json_log_error() {
    assert_file_contains "$SOURCE_FILE" "export -f json_log_error" \
        "json_log_error is exported"
}

test_exports_json_log_warning() {
    assert_file_contains "$SOURCE_FILE" "export -f json_log_warning" \
        "json_log_warning is exported"
}

test_exports_json_log_feature_end() {
    assert_file_contains "$SOURCE_FILE" "export -f json_log_feature_end" \
        "json_log_feature_end is exported"
}

test_exports_json_log_build_metadata() {
    assert_file_contains "$SOURCE_FILE" "export -f json_log_build_metadata" \
        "json_log_build_metadata is exported"
}

test_enable_json_logging_toggle() {
    assert_file_contains "$SOURCE_FILE" "ENABLE_JSON_LOGGING" \
        "Script references ENABLE_JSON_LOGGING toggle"
}

test_iso8601_timestamp_pattern() {
    assert_file_contains "$SOURCE_FILE" '%Y-%m-%dT%H:%M:%S' \
        "Script uses ISO 8601 timestamp format"
}

test_correlation_id_pattern() {
    assert_file_contains "$SOURCE_FILE" "BUILD_CORRELATION_ID" \
        "Script uses BUILD_CORRELATION_ID for log correlation"
}

test_jsonl_format() {
    assert_file_contains "$SOURCE_FILE" ".jsonl" \
        "Script uses JSONL file extension for log files"
}

# ============================================================================
# Functional Tests - json_escape
# ============================================================================

test_json_escape_backslashes() {
    local result
    result=$(_run_json_subshell "json_escape 'path\\\\to\\\\file'")

    assert_contains "$result" '\\' \
        "json_escape should escape backslashes"
}

test_json_escape_double_quotes() {
    local result
    result=$(_run_json_subshell 'json_escape "say \"hello\""')

    assert_contains "$result" '\"' \
        "json_escape should escape double quotes"
}

test_json_escape_newlines() {
    local result
    result=$(_run_json_subshell $'json_escape "line1\nline2"')

    assert_contains "$result" '\n' \
        "json_escape should escape newlines"
}

test_json_escape_tabs() {
    local result
    result=$(_run_json_subshell $'json_escape "col1\tcol2"')

    assert_contains "$result" '\t' \
        "json_escape should escape tabs"
}

# ============================================================================
# Functional Tests - json_log_event
# ============================================================================

test_json_log_event_returns_0_when_disabled() {
    local exit_code=0
    bash -c "
        export BUILD_LOG_DIR='$TEST_TEMP_DIR'
        export ENABLE_JSON_LOGGING='false'
        source '$SOURCE_FILE' >/dev/null 2>&1
        json_log_event 'INFO' 'test_event' 'test message'
    " 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "json_log_event should return 0 when logging is disabled"
}

test_json_log_event_writes_to_file() {
    local output
    output=$(bash -c "
        export BUILD_LOG_DIR='$TEST_TEMP_DIR'
        export ENABLE_JSON_LOGGING='true'
        export CURRENT_FEATURE='test-feature'
        source '$SOURCE_FILE' >/dev/null 2>&1
        export CURRENT_JSON_LOG_FILE='$TEST_TEMP_DIR/json/test.jsonl'
        mkdir -p '$TEST_TEMP_DIR/json'
        json_log_event 'INFO' 'test_event' 'test message'
        cat '$TEST_TEMP_DIR/json/test.jsonl'
    " 2>/dev/null)

    assert_contains "$output" '"level":"INFO"' \
        "json_log_event output should contain log level"
    assert_contains "$output" '"event_type":"test_event"' \
        "json_log_event output should contain event type"
    assert_contains "$output" 'test message' \
        "json_log_event output should contain message"
}

test_json_log_command_includes_duration() {
    local output
    output=$(bash -c "
        export BUILD_LOG_DIR='$TEST_TEMP_DIR'
        export ENABLE_JSON_LOGGING='true'
        export CURRENT_FEATURE='test-feature'
        source '$SOURCE_FILE' >/dev/null 2>&1
        export CURRENT_JSON_LOG_FILE='$TEST_TEMP_DIR/json/cmd.jsonl'
        mkdir -p '$TEST_TEMP_DIR/json'
        json_log_command 'Installing deps' 1 0 5
        cat '$TEST_TEMP_DIR/json/cmd.jsonl'
    " 2>/dev/null)

    assert_contains "$output" '"duration_seconds":5' \
        "json_log_command output should include duration metrics"
    assert_contains "$output" '"command_num":1' \
        "json_log_command output should include command number"
}

test_json_log_command_error_level_on_nonzero_exit() {
    local output
    output=$(bash -c "
        export BUILD_LOG_DIR='$TEST_TEMP_DIR'
        export ENABLE_JSON_LOGGING='true'
        export CURRENT_FEATURE='test-feature'
        source '$SOURCE_FILE' >/dev/null 2>&1
        export CURRENT_JSON_LOG_FILE='$TEST_TEMP_DIR/json/err.jsonl'
        mkdir -p '$TEST_TEMP_DIR/json'
        json_log_command 'Failing command' 2 1 3
        cat '$TEST_TEMP_DIR/json/err.jsonl'
    " 2>/dev/null)

    assert_contains "$output" '"level":"ERROR"' \
        "json_log_command should set ERROR level on non-zero exit code"
    assert_contains "$output" '"exit_code":1' \
        "json_log_command should include the exit code"
}

test_build_correlation_id_format() {
    local corr_id
    corr_id=$(bash -c "
        export BUILD_LOG_DIR='$TEST_TEMP_DIR'
        export ENABLE_JSON_LOGGING='true'
        source '$SOURCE_FILE' >/dev/null 2>&1
        echo \"\$BUILD_CORRELATION_ID\"
    " 2>/dev/null)

    assert_matches "$corr_id" '^build-[0-9]+-[a-z0-9]+$' \
        "BUILD_CORRELATION_ID should match build-<timestamp>-<random> format"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis - function definitions
run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_defines_json_escape "Defines json_escape function"
run_test_with_setup test_defines_json_log_init "Defines json_log_init function"
run_test_with_setup test_defines_json_log_event "Defines json_log_event function"
run_test_with_setup test_defines_json_log_command "Defines json_log_command function"
run_test_with_setup test_defines_json_log_error "Defines json_log_error function"
run_test_with_setup test_defines_json_log_warning "Defines json_log_warning function"
run_test_with_setup test_defines_json_log_feature_end "Defines json_log_feature_end function"
run_test_with_setup test_defines_json_log_build_metadata "Defines json_log_build_metadata function"

# Static analysis - exports
run_test_with_setup test_exports_json_escape "json_escape is exported"
run_test_with_setup test_exports_json_log_init "json_log_init is exported"
run_test_with_setup test_exports_json_log_event "json_log_event is exported"
run_test_with_setup test_exports_json_log_command "json_log_command is exported"
run_test_with_setup test_exports_json_log_error "json_log_error is exported"
run_test_with_setup test_exports_json_log_warning "json_log_warning is exported"
run_test_with_setup test_exports_json_log_feature_end "json_log_feature_end is exported"
run_test_with_setup test_exports_json_log_build_metadata "json_log_build_metadata is exported"

# Static analysis - patterns
run_test_with_setup test_enable_json_logging_toggle "ENABLE_JSON_LOGGING toggle present"
run_test_with_setup test_iso8601_timestamp_pattern "ISO 8601 timestamp pattern present"
run_test_with_setup test_correlation_id_pattern "BUILD_CORRELATION_ID pattern present"
run_test_with_setup test_jsonl_format "JSONL file format used"

# Functional tests - json_escape
run_test_with_setup test_json_escape_backslashes "json_escape handles backslashes"
run_test_with_setup test_json_escape_double_quotes "json_escape handles double quotes"
run_test_with_setup test_json_escape_newlines "json_escape handles newlines"
run_test_with_setup test_json_escape_tabs "json_escape handles tabs"

# Functional tests - json_log_event
run_test_with_setup test_json_log_event_returns_0_when_disabled "json_log_event returns 0 when disabled"
run_test_with_setup test_json_log_event_writes_to_file "json_log_event writes to JSONL file when enabled"
run_test_with_setup test_json_log_command_includes_duration "json_log_command includes duration metrics"
run_test_with_setup test_json_log_command_error_level_on_nonzero_exit "json_log_command sets ERROR level on non-zero exit"
run_test_with_setup test_build_correlation_id_format "BUILD_CORRELATION_ID format validation"

# Generate test report
generate_report
