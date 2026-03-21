#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/resource-limits.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Resource Limits Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/lib/resource-limits.sh"

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "resource-limits.sh exists"
}

test_script_executable() {
    assert_executable "$SOURCE_FILE" "resource-limits.sh is executable"
}

test_multiple_source_guard() {
    assert_file_contains "$SOURCE_FILE" "_RESOURCE_LIMITS_LOADED" \
        "Script has multiple-source guard"
}

test_file_descriptor_default() {
    assert_file_contains "$SOURCE_FILE" 'FILE_DESCRIPTOR_LIMIT="${FILE_DESCRIPTOR_LIMIT:-4096}"' \
        "FILE_DESCRIPTOR_LIMIT defaults to 4096"
}

test_max_processes_default() {
    assert_file_contains "$SOURCE_FILE" 'MAX_USER_PROCESSES="${MAX_USER_PROCESSES:-2048}"' \
        "MAX_USER_PROCESSES defaults to 2048"
}

test_core_dump_default() {
    assert_file_contains "$SOURCE_FILE" 'CORE_DUMP_SIZE="${CORE_DUMP_SIZE:-0}"' \
        "CORE_DUMP_SIZE defaults to 0"
}

test_ulimit_file_descriptors() {
    assert_file_contains "$SOURCE_FILE" 'ulimit -n' \
        "Script sets file descriptor limit via ulimit -n"
}

test_ulimit_max_processes() {
    assert_file_contains "$SOURCE_FILE" 'ulimit -u' \
        "Script sets max processes via ulimit -u"
}

test_ulimit_core_dumps() {
    assert_file_contains "$SOURCE_FILE" 'ulimit -c' \
        "Script sets core dump size via ulimit -c"
}

test_fd_warning_message() {
    assert_file_contains "$SOURCE_FILE" "Could not set file descriptor limit" \
        "Script warns on failed file descriptor ulimit"
}

test_process_warning_message() {
    assert_file_contains "$SOURCE_FILE" "Could not set max user processes limit" \
        "Script warns on failed max processes ulimit"
}

test_error_suppression() {
    assert_file_contains "$SOURCE_FILE" '2>/dev/null || {' \
        "Script suppresses stderr and handles errors"
}

# ============================================================================
# Functional Tests
# ============================================================================

test_sourcing_sets_loaded_flag() {
    (
        unset _RESOURCE_LIMITS_LOADED 2>/dev/null || true
        source "$SOURCE_FILE"
        [ "${_RESOURCE_LIMITS_LOADED:-}" = "1" ] || exit 1
    )
    assert_equals "0" "$?" "Sourcing sets _RESOURCE_LIMITS_LOADED=1"
}

test_guard_prevents_double_source() {
    (
        unset _RESOURCE_LIMITS_LOADED 2>/dev/null || true
        source "$SOURCE_FILE"

        # Capture ulimit -n before re-source
        local fd_before
        fd_before=$(ulimit -n 2>/dev/null || echo "unknown")

        # Override the limit variable to detect if re-sourcing re-runs ulimit
        export FILE_DESCRIPTOR_LIMIT=99999

        # Re-source — guard should cause immediate return
        source "$SOURCE_FILE"

        # ulimit -n should NOT have changed to 99999
        local fd_after
        fd_after=$(ulimit -n 2>/dev/null || echo "unknown")
        [ "$fd_before" = "$fd_after" ] || exit 1
    )
    assert_equals "0" "$?" "Guard prevents re-execution on second source"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_script_executable "Script is executable"
run_test test_multiple_source_guard "Has multiple-source guard"
run_test test_file_descriptor_default "FILE_DESCRIPTOR_LIMIT defaults to 4096"
run_test test_max_processes_default "MAX_USER_PROCESSES defaults to 2048"
run_test test_core_dump_default "CORE_DUMP_SIZE defaults to 0"
run_test test_ulimit_file_descriptors "Sets file descriptors via ulimit -n"
run_test test_ulimit_max_processes "Sets max processes via ulimit -u"
run_test test_ulimit_core_dumps "Sets core dump size via ulimit -c"
run_test test_fd_warning_message "Warns on failed fd ulimit"
run_test test_process_warning_message "Warns on failed processes ulimit"
run_test test_error_suppression "Suppresses stderr on ulimit failures"

# Functional tests
run_test test_sourcing_sets_loaded_flag "Sourcing sets _RESOURCE_LIMITS_LOADED"
run_test test_guard_prevents_double_source "Guard prevents re-execution"

# Generate test report
generate_report
