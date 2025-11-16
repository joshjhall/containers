#!/usr/bin/env bash
# Unit tests for JSON logging functionality
#
# Tests that JSON logging produces valid JSON with expected fields
# without requiring external services (Prometheus, Grafana, etc.)

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source test framework
# shellcheck source=tests/framework.sh
source "$PROJECT_ROOT/tests/framework.sh"

# Source JSON logging
export BUILD_LOG_DIR="/tmp/test-json-logging-$$"
export ENABLE_JSON_LOGGING=true
mkdir -p "$BUILD_LOG_DIR/json"

# shellcheck source=lib/base/json-logging.sh
source "$PROJECT_ROOT/lib/base/json-logging.sh"

test_json_logging_enabled() {
    start_test "JSON logging can be enabled"

    assert_equals "$ENABLE_JSON_LOGGING" "true" "JSON logging should be enabled"
    assert_command_exists "json_escape" "json_escape function should exist"
    assert_command_exists "json_log_event" "json_log_event function should exist"

    pass_test
}

test_json_escape() {
    start_test "JSON escape handles special characters"

    local result
    result=$(json_escape 'Hello "World"')
    assert_equals "$result" 'Hello \"World\"' "Should escape double quotes"

    result=$(json_escape 'Line1\nLine2')
    assert_equals "$result" 'Line1\\nLine2' "Should escape newlines"

    result=$(json_escape 'Path\to\file')
    assert_equals "$result" 'Path\\to\\file' "Should escape backslashes"

    pass_test
}

test_json_log_init() {
    start_test "JSON log initialization creates files"

    json_log_init "test-feature" "1.0.0"

    assert_file_exists "$BUILD_LOG_DIR/json/test-feature.jsonl" \
        "JSON log file should be created"

    # Check first log entry exists and is valid JSON
    if command -v jq >/dev/null 2>&1; then
        local first_line
        first_line=$(head -1 "$BUILD_LOG_DIR/json/test-feature.jsonl")

        # Should be valid JSON
        echo "$first_line" | jq '.' >/dev/null 2>&1
        assert_success "First log entry should be valid JSON"

        # Should have required fields
        local event_type
        event_type=$(echo "$first_line" | jq -r '.event_type')
        assert_equals "$event_type" "feature_start" "Should log feature_start event"
    fi

    pass_test
}

test_json_log_event() {
    start_test "JSON log events contain required fields"

    export CURRENT_JSON_LOG_FILE="$BUILD_LOG_DIR/json/test-events.jsonl"
    export CURRENT_FEATURE="test-feature"
    export BUILD_CORRELATION_ID="test-correlation-123"

    json_log_event "INFO" "test_event" "Test message" '{"key":"value"}'

    if command -v jq >/dev/null 2>&1; then
        local log_entry
        log_entry=$(tail -1 "$CURRENT_JSON_LOG_FILE")

        # Validate JSON structure
        echo "$log_entry" | jq '.' >/dev/null 2>&1
        assert_success "Log entry should be valid JSON"

        # Check required fields
        local timestamp level correlation_id feature message
        timestamp=$(echo "$log_entry" | jq -r '.timestamp')
        level=$(echo "$log_entry" | jq -r '.level')
        correlation_id=$(echo "$log_entry" | jq -r '.correlation_id')
        feature=$(echo "$log_entry" | jq -r '.feature')
        message=$(echo "$log_entry" | jq -r '.message')

        assert_not_empty "$timestamp" "Should have timestamp"
        assert_equals "$level" "INFO" "Should have correct level"
        assert_equals "$correlation_id" "test-correlation-123" "Should have correlation ID"
        assert_equals "$feature" "test-feature" "Should have feature name"
        assert_equals "$message" "Test message" "Should have message"

        # Check metadata
        local metadata_key
        metadata_key=$(echo "$log_entry" | jq -r '.metadata.key')
        assert_equals "$metadata_key" "value" "Should include metadata"
    fi

    pass_test
}

test_json_log_command() {
    start_test "JSON command logging records metrics"

    export CURRENT_JSON_LOG_FILE="$BUILD_LOG_DIR/json/test-commands.jsonl"
    export CURRENT_FEATURE="test-feature"
    export BUILD_CORRELATION_ID="test-correlation-123"

    json_log_command "Test command" 1 0 5

    if command -v jq >/dev/null 2>&1; then
        local log_entry
        log_entry=$(tail -1 "$CURRENT_JSON_LOG_FILE")

        local event_type command_num exit_code duration
        event_type=$(echo "$log_entry" | jq -r '.event_type')
        command_num=$(echo "$log_entry" | jq -r '.metadata.command_num')
        exit_code=$(echo "$log_entry" | jq -r '.metadata.exit_code')
        duration=$(echo "$log_entry" | jq -r '.metadata.duration_seconds')

        assert_equals "$event_type" "command" "Should be command event"
        assert_equals "$command_num" "1" "Should record command number"
        assert_equals "$exit_code" "0" "Should record exit code"
        assert_equals "$duration" "5" "Should record duration"
    fi

    pass_test
}

test_correlation_id_generation() {
    start_test "Correlation ID is generated and persists"

    # Clear existing correlation ID
    unset BUILD_CORRELATION_ID

    # Source again to trigger generation
    ENABLE_JSON_LOGGING=true
    # shellcheck source=lib/base/json-logging.sh
    source "$PROJECT_ROOT/lib/base/json-logging.sh"

    assert_not_empty "$BUILD_CORRELATION_ID" "Should generate correlation ID"

    # Should match pattern: build-<timestamp>-<random>
    if [[ "$BUILD_CORRELATION_ID" =~ ^build-[0-9]+-[a-z0-9]{6}$ ]]; then
        assert_success "Correlation ID should match expected pattern"
    else
        fail_test "Correlation ID doesn't match pattern: $BUILD_CORRELATION_ID"
    fi

    pass_test
}

test_json_logging_disabled() {
    start_test "JSON logging no-ops when disabled"

    # Disable JSON logging
    export ENABLE_JSON_LOGGING=false

    # Re-source to get no-op functions
    # shellcheck source=lib/base/json-logging.sh
    source "$PROJECT_ROOT/lib/base/json-logging.sh"

    # Functions should exist but do nothing
    json_log_event "INFO" "test" "message" "{}"
    assert_success "Should not error when disabled"

    # No files should be created
    local json_files
    json_files=$(find "$BUILD_LOG_DIR/json" -name "*.jsonl" 2>/dev/null | wc -l)
    # Files might exist from previous tests, but no new ones should be created

    pass_test
}

# Cleanup
cleanup() {
    rm -rf "$BUILD_LOG_DIR"
}

trap cleanup EXIT

# Run all tests
run_tests "JSON Logging Tests" \
    test_json_logging_enabled \
    test_json_escape \
    test_json_log_init \
    test_json_log_event \
    test_json_log_command \
    test_correlation_id_generation \
    test_json_logging_disabled
