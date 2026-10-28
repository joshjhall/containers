#!/usr/bin/env bash
# Extended unit tests for lib/base/logging.sh
# Tests uncovered paths: log_debug filtering, multiple features in sequence,
# uninitialized state, log_command error extraction, and counter reset.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Logging Extended Tests"

# Setup function - runs before each test
setup() {
    export TEST_LOG_DIR="$TEST_SCRATCH_BASE/test-logs-ext"
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

    # Source shared dependencies
    source "$PROJECT_ROOT/lib/shared/export-utils.sh"
    source "$PROJECT_ROOT/lib/shared/logging.sh"

    # Create a modified version of logging.sh for testing
    command sed 's|/var/log/container-build|'"$TEST_LOG_DIR"'|g' "$PROJECT_ROOT/lib/base/logging.sh" >"$TEST_LOG_DIR/logging-test.sh"

    # Copy sub-modules to the test directory so relative sourcing works
    command cp "$PROJECT_ROOT/lib/base/feature-logging.sh" "$TEST_LOG_DIR/feature-logging.sh"
    command cp "$PROJECT_ROOT/lib/base/message-logging.sh" "$TEST_LOG_DIR/message-logging.sh"

    # Source the modified version
    source "$TEST_LOG_DIR/logging-test.sh"
}

# Teardown function - runs after each test
teardown() {
    command rm -rf "$TEST_LOG_DIR"

    # Unset include guards so re-sourcing works across tests
    unset _LOGGING_LOADED 2>/dev/null || true
    unset _SHARED_LOGGING_LOADED 2>/dev/null || true
    unset _SHARED_EXPORT_UTILS_LOADED 2>/dev/null || true
    unset _FEATURE_LOGGING_LOADED 2>/dev/null || true
    unset _MESSAGE_LOGGING_LOADED 2>/dev/null || true
}

# ============================================================================
# log_debug Level Filtering Tests
# ============================================================================

test_log_debug_visible_at_debug_level() {
    export LOG_LEVEL=DEBUG
    log_feature_start "DebugTest"

    log_debug "Debug visible message"

    if command grep -q "DEBUG: Debug visible message" "$CURRENT_LOG_FILE"; then
        assert_true true "log_debug output appears at DEBUG level"
    else
        assert_true false "log_debug output missing at DEBUG level"
    fi
}

test_log_debug_hidden_at_info_level() {
    export LOG_LEVEL=INFO
    log_feature_start "DebugTest"

    log_debug "Debug hidden message"

    if command grep -q "Debug hidden message" "$CURRENT_LOG_FILE"; then
        assert_true false "log_debug output should be hidden at INFO level"
    else
        assert_true true "log_debug output correctly hidden at INFO level"
    fi
}

# ============================================================================
# Multiple Features in Sequence
# ============================================================================

test_multiple_features_in_master_summary() {
    log_feature_start "Feature-A" "1.0"
    log_command "Step A" echo "output-a"
    log_feature_end

    log_feature_start "Feature-B" "2.0"
    log_command "Step B" echo "output-b"
    log_feature_end

    local master_summary="$BUILD_LOG_DIR/master-summary.log"
    assert_file_exists "$master_summary"

    local count_a count_b
    count_a=$(command grep -c "Feature-A" "$master_summary" || echo 0)
    count_b=$(command grep -c "Feature-B" "$master_summary" || echo 0)

    assert_true [ "$count_a" -ge 1 ] "Feature-A appears in master summary"
    assert_true [ "$count_b" -ge 1 ] "Feature-B appears in master summary"
}

test_counters_reset_between_features() {
    log_feature_start "Feature-X"
    log_command "Step 1" echo "hello"
    log_command "Step 2" echo "world"
    log_error "Test error"
    log_warning "Test warning"

    # Check counters before end
    assert_true [ "$COMMAND_COUNT" -ge 2 ] "Command count incremented during feature"
    assert_true [ "$ERROR_COUNT" -ge 1 ] "Error count incremented during feature"
    assert_true [ "$WARNING_COUNT" -ge 1 ] "Warning count incremented during feature"

    log_feature_end

    # After log_feature_end, CURRENT_FEATURE should be reset
    assert_equals "" "$CURRENT_FEATURE" "CURRENT_FEATURE reset after log_feature_end"
    assert_equals "" "$CURRENT_LOG_FILE" "CURRENT_LOG_FILE reset after log_feature_end"

    # Start a new feature and verify counters start fresh
    log_feature_start "Feature-Y"

    assert_equals "0" "$COMMAND_COUNT" "COMMAND_COUNT resets for new feature"
    assert_equals "0" "$ERROR_COUNT" "ERROR_COUNT resets for new feature"
    assert_equals "0" "$WARNING_COUNT" "WARNING_COUNT resets for new feature"

    log_feature_end
}

# ============================================================================
# Uninitialized State Tests
# ============================================================================

test_log_message_before_feature_start() {
    # Reset CURRENT_LOG_FILE to simulate uninitialized state
    CURRENT_LOG_FILE=""
    export LOG_LEVEL=INFO

    # Should not crash — just prints to stdout
    local output
    output=$(log_message "Before feature start" 2>&1)

    assert_true [ $? -eq 0 ] "log_message does not crash before feature start"
    if command grep -q "Before feature start" <<<"$output"; then
        assert_true true "log_message outputs to stdout when uninitialized"
    else
        assert_true false "log_message output missing when uninitialized"
    fi
}

test_log_error_before_feature_start() {
    # Simulate uninitialized file state but keep counters initialized
    # (logging.sh initializes ERROR_COUNT=0 at source time)
    CURRENT_LOG_FILE=""
    export CURRENT_ERROR_FILE=""
    ERROR_COUNT=0

    # Should not crash — just prints to stderr
    local output
    output=$(log_error "Error before feature start" 2>&1)

    assert_true [ $? -eq 0 ] "log_error does not crash before feature start"
    if command grep -q "Error before feature start" <<<"$output"; then
        assert_true true "log_error outputs to stderr when uninitialized"
    else
        assert_true false "log_error output missing when uninitialized"
    fi
}

# ============================================================================
# log_command Error/Warning Extraction
# ============================================================================

test_log_command_extracts_error_patterns() {
    log_feature_start "PatternTest"

    # Reset counters (log_feature_start already does this, but be explicit)
    ERROR_COUNT=0
    WARNING_COUNT=0

    # Run a command whose output contains ERROR text
    log_command "Command with error output" echo "ERROR: something went wrong"

    # The error extraction should have picked up the ERROR pattern
    assert_true [ "$ERROR_COUNT" -ge 1 ] "ERROR pattern in command output increments ERROR_COUNT"
}

test_log_command_extracts_warning_patterns() {
    log_feature_start "PatternTest"

    ERROR_COUNT=0
    WARNING_COUNT=0

    # Run a command whose output contains WARNING text
    log_command "Command with warning output" echo "WARNING: something may be wrong"

    assert_true [ "$WARNING_COUNT" -ge 1 ] "WARNING pattern in command output increments WARNING_COUNT"
}

# Crate names carry "error" as part of a word; they are build progress, not
# failures (#1537).
test_log_command_ignores_error_inside_names() {
    log_feature_start "PatternTest"
    log_command "Cargo progress" printf '%s\n' \
        "  Downloaded thiserror-impl v2.0.21" "   Compiling gix-error v0.1.0" \
        "   Compiling no-warnings-lint v0.1.0"
    assert_equals "0" "$ERROR_COUNT" "thiserror / gix-error are not counted as errors"
    assert_equals "0" "$WARNING_COUNT" "no-warnings-lint is not counted as a warning"
}

# cargo-binstall logs a recovered fallback as WARN followed by "Error ...
# Failed ..."; it counts once, as a warning (#1537).
test_log_command_warn_tagged_error_is_warning() {
    log_feature_start "PatternTest"
    log_command "binstall fallback" echo \
        "cargo-binstall:  WARN resolve: Error while downloading from fetcher QuickInstall: Failed to download"
    assert_equals "0" "$ERROR_COUNT" "WARN-tagged Error line is not an error"
    assert_equals "1" "$WARNING_COUNT" "WARN-tagged Error line is one warning"
    # The line lands in the error file once (via the warning extraction)
    assert_equals "1" "$(command grep -c 'QuickInstall' "$CURRENT_ERROR_FILE")" \
        "WARN-tagged Error line is written to the error file exactly once"
}

# An error that mentions warnings later in the line is still an error.
test_log_command_error_mentioning_warnings_is_error() {
    log_feature_start "PatternTest"
    log_command "rustc abort" printf '%s\n' \
        "error: aborting due to 1 previous error; 1 warning emitted" \
        "error[E0425]: cannot find value" "E: Failed to fetch http://x" \
        "Errors were encountered while processing:" "2 errors generated." \
        "npm error code ELIFECYCLE"
    assert_equals "6" "$ERROR_COUNT" "genuine error lines (incl. plurals) are each counted"
    # The rustc line also mentions a warning; it counts on both sides
    assert_equals "1" "$WARNING_COUNT" "only the rustc line counts as a warning"
    assert_file_contains "$CURRENT_ERROR_FILE" "aborting due to 1 previous error" \
        "genuine error line is copied to the error file"
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
run_test_with_setup test_log_debug_visible_at_debug_level "log_debug output appears at DEBUG level"
run_test_with_setup test_log_debug_hidden_at_info_level "log_debug output hidden at INFO level"
run_test_with_setup test_multiple_features_in_master_summary "Multiple features appear in master summary"
run_test_with_setup test_counters_reset_between_features "Counters reset between features"
run_test_with_setup test_log_message_before_feature_start "log_message works before feature start"
run_test_with_setup test_log_error_before_feature_start "log_error works before feature start"
run_test_with_setup test_log_command_extracts_error_patterns "log_command extracts ERROR patterns"
run_test_with_setup test_log_command_extracts_warning_patterns "log_command extracts WARNING patterns"
run_test_with_setup test_log_command_ignores_error_inside_names "log_command ignores error inside crate names"
run_test_with_setup test_log_command_warn_tagged_error_is_warning "WARN-tagged Error line counts as a warning"
run_test_with_setup test_log_command_error_mentioning_warnings_is_error "Error line mentioning warnings counts as an error"

# Generate test report
generate_report
