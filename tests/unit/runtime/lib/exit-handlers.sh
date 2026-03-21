#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/exit-handlers.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Exit Handlers Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/lib/exit-handlers.sh"

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "exit-handlers.sh exists"
}

test_script_executable() {
    assert_executable "$SOURCE_FILE" "exit-handlers.sh is executable"
}

test_multiple_source_guard() {
    assert_file_contains "$SOURCE_FILE" "_EXIT_HANDLERS_LOADED" \
        "Script has multiple-source guard"
}

test_defines_cleanup_on_exit() {
    assert_file_contains "$SOURCE_FILE" "cleanup_on_exit()" \
        "Script defines cleanup_on_exit function"
}

test_trap_exit() {
    assert_file_contains "$SOURCE_FILE" "trap cleanup_on_exit EXIT" \
        "Script sets trap for EXIT signal"
}

test_trap_term() {
    assert_file_contains "$SOURCE_FILE" "TERM" \
        "Script sets trap for TERM signal"
}

test_trap_int() {
    assert_file_contains "$SOURCE_FILE" "INT" \
        "Script sets trap for INT signal"
}

test_audit_log_conditional() {
    assert_file_contains "$SOURCE_FILE" "declare -f audit_log" \
        "Script conditionally calls audit_log"
}

test_shutdown_message() {
    assert_file_contains "$SOURCE_FILE" "Container shutting down" \
        "Script outputs shutdown message with exit code"
}

test_metrics_dir_check() {
    assert_file_contains "$SOURCE_FILE" "/tmp/container-metrics" \
        "Script checks metrics directory"
}

test_sync_call() {
    assert_file_contains "$SOURCE_FILE" "sync" \
        "Script calls sync for filesystem flush"
}

test_exit_code_preservation() {
    assert_file_contains "$SOURCE_FILE" 'exit $exit_code' \
        "Script preserves original exit code"
}

test_exit_code_capture() {
    assert_file_contains "$SOURCE_FILE" 'local exit_code=$?' \
        "Script captures exit code at function entry"
}

# ============================================================================
# Functional Tests
# ============================================================================

test_sourcing_defines_function() {
    (
        unset _EXIT_HANDLERS_LOADED 2>/dev/null || true
        source "$SOURCE_FILE"
        declare -f cleanup_on_exit >/dev/null 2>&1 || exit 1
    )
    assert_equals "0" "$?" "Sourcing defines cleanup_on_exit function"
}

test_sourcing_sets_loaded_flag() {
    (
        unset _EXIT_HANDLERS_LOADED 2>/dev/null || true
        source "$SOURCE_FILE"
        [ "${_EXIT_HANDLERS_LOADED:-}" = "1" ] || exit 1
    )
    assert_equals "0" "$?" "Sourcing sets _EXIT_HANDLERS_LOADED=1"
}

test_trap_registered_for_exit() {
    (
        unset _EXIT_HANDLERS_LOADED 2>/dev/null || true
        source "$SOURCE_FILE"
        # Check that EXIT trap includes cleanup_on_exit
        trap -p EXIT | command grep -q "cleanup_on_exit" || exit 1
    )
    assert_equals "0" "$?" "EXIT trap is registered with cleanup_on_exit"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_script_executable "Script is executable"
run_test test_multiple_source_guard "Has multiple-source guard"
run_test test_defines_cleanup_on_exit "Defines cleanup_on_exit function"
run_test test_trap_exit "Sets trap for EXIT"
run_test test_trap_term "Sets trap for TERM"
run_test test_trap_int "Sets trap for INT"
run_test test_audit_log_conditional "Conditionally calls audit_log"
run_test test_shutdown_message "Outputs shutdown message"
run_test test_metrics_dir_check "Checks metrics directory"
run_test test_sync_call "Calls sync for filesystem flush"
run_test test_exit_code_preservation "Preserves exit code on exit"
run_test test_exit_code_capture "Captures exit code at function entry"

# Functional tests
run_test test_sourcing_defines_function "Sourcing defines cleanup_on_exit"
run_test test_sourcing_sets_loaded_flag "Sourcing sets _EXIT_HANDLERS_LOADED"
run_test test_trap_registered_for_exit "EXIT trap registered"

# Generate test report
generate_report
