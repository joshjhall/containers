#!/usr/bin/env bash
# Unit tests for lib/base/cleanup-handler.sh
# Tests cleanup handler registration, unregistration, LIFO ordering, and edge cases.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Cleanup Handler Tests"

# Extract functions from cleanup-handler.sh into a temp file for isolated testing.
# Sourcing the file directly would install EXIT traps that interfere with tests,
# so we extract just the function definitions and array declaration.
_CLEANUP_FUNC_FILE="$RESULTS_DIR/_cleanup_funcs.sh"
command sed -n '
    /^declare -a _FEATURE_CLEANUP_ITEMS/p
    /^cleanup_on_interrupt()/,/^}/p
    /^register_cleanup()/,/^}/p
    /^unregister_cleanup()/,/^}/p
' "$PROJECT_ROOT/lib/base/cleanup-handler.sh" >"$_CLEANUP_FUNC_FILE"

# Setup function - runs before each test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-cleanup-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    command rm -rf "$TEST_TEMP_DIR"
}

# ============================================================================
# register_cleanup tests
# ============================================================================

# Test: register_cleanup with valid item adds to array
test_register_adds_to_array() {
    local output
    output=$(bash -c '
        log_warning() { :; }
        log_message() { :; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup "/tmp/test-item"
        echo "count=${#_FEATURE_CLEANUP_ITEMS[@]}"
        echo "item=${_FEATURE_CLEANUP_ITEMS[0]}"
    ' 2>/dev/null)
    assert_contains "$output" "count=1" "Array has 1 item after register"
    assert_contains "$output" "item=/tmp/test-item" "Registered item is correct"
}

# Test: register_cleanup accumulates multiple items
test_register_multiple_items() {
    local output
    output=$(bash -c '
        log_warning() { :; }
        log_message() { :; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup "/tmp/a"
        register_cleanup "/tmp/b"
        register_cleanup "/tmp/c"
        echo "count=${#_FEATURE_CLEANUP_ITEMS[@]}"
    ' 2>/dev/null)
    assert_contains "$output" "count=3" "Array has 3 items after three registers"
}

# Test: register_cleanup with empty arg returns 1 and warns
test_register_empty_arg() {
    local exit_code=0
    local output
    output=$(bash -c '
        set -e
        log_warning() { echo "WARNING: $*" >&2; }
        log_message() { :; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup ""
    ' 2>&1) || exit_code=$?
    assert_not_equals "0" "$exit_code" "register_cleanup returns 1 for empty arg"
    assert_contains "$output" "WARNING" "Warning logged for empty arg"
}

# ============================================================================
# unregister_cleanup tests
# ============================================================================

# Test: unregister_cleanup removes item from array
test_unregister_removes_item() {
    local output
    output=$(bash -c '
        log_warning() { :; }
        log_message() { :; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup "/tmp/a"
        register_cleanup "/tmp/b"
        register_cleanup "/tmp/c"
        unregister_cleanup "/tmp/b"
        echo "count=${#_FEATURE_CLEANUP_ITEMS[@]}"
        for item in "${_FEATURE_CLEANUP_ITEMS[@]}"; do echo "item=$item"; done
    ' 2>/dev/null)
    assert_contains "$output" "count=2" "Array has 2 items after unregister"
    assert_contains "$output" "item=/tmp/a" "Item a remains"
    assert_contains "$output" "item=/tmp/c" "Item c remains"
    assert_not_contains "$output" "item=/tmp/b" "Item b was removed"
}

# Test: unregister_cleanup with non-present item — no error, array unchanged
test_unregister_nonpresent_item() {
    local exit_code=0
    local output
    output=$(bash -c '
        log_warning() { :; }
        log_message() { :; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup "/tmp/a"
        register_cleanup "/tmp/b"
        unregister_cleanup "/tmp/not-there"
        echo "count=${#_FEATURE_CLEANUP_ITEMS[@]}"
    ' 2>/dev/null) || exit_code=$?
    assert_equals "0" "$exit_code" "unregister of non-present item does not error"
    assert_contains "$output" "count=2" "Array unchanged after unregistering non-present item"
}

# ============================================================================
# cleanup_on_interrupt tests
# ============================================================================

# Test: cleanup_on_interrupt processes items in LIFO order (last registered = first cleaned)
test_cleanup_lifo_ordering() {
    mkdir -p "$TEST_TEMP_DIR/cleanup-lifo"
    echo 'a' >"$TEST_TEMP_DIR/cleanup-lifo/file-a"
    echo 'b' >"$TEST_TEMP_DIR/cleanup-lifo/file-b"
    echo 'c' >"$TEST_TEMP_DIR/cleanup-lifo/file-c"

    local output
    output=$(bash -c '
        log_warning() { :; }
        log_message() { :; }
        exit() { return "${1:-0}"; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup "'"$TEST_TEMP_DIR"'/cleanup-lifo/file-a"
        register_cleanup "'"$TEST_TEMP_DIR"'/cleanup-lifo/file-b"
        register_cleanup "'"$TEST_TEMP_DIR"'/cleanup-lifo/file-c"
        cleanup_on_interrupt
    ' 2>&1)

    # Verify LIFO order: C appears before B, B appears before A
    local pos_a pos_b pos_c
    pos_a=$(echo "$output" | command grep -n 'file-a' | command head -1 | command cut -d: -f1)
    pos_b=$(echo "$output" | command grep -n 'file-b' | command head -1 | command cut -d: -f1)
    pos_c=$(echo "$output" | command grep -n 'file-c' | command head -1 | command cut -d: -f1)

    if [ -n "$pos_a" ] && [ -n "$pos_b" ] && [ -n "$pos_c" ]; then
        if [ "$pos_c" -lt "$pos_b" ] && [ "$pos_b" -lt "$pos_a" ]; then
            assert_true true "Cleanup in LIFO order: C before B before A"
        else
            assert_true false "Cleanup not in LIFO order: C=$pos_c B=$pos_b A=$pos_a"
        fi
    else
        assert_true false "Could not find all cleanup messages (a=$pos_a b=$pos_b c=$pos_c)"
    fi
}

# Test: cleanup_on_interrupt with empty array — no crash, no banner
test_cleanup_empty_array() {
    local exit_code=0
    local output
    output=$(bash -c '
        log_warning() { :; }
        log_message() { :; }
        exit() { return "${1:-0}"; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        cleanup_on_interrupt
    ' 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "cleanup_on_interrupt does not crash with empty array"
    assert_not_contains "$output" "Cleaning up interrupted build" "No cleanup banner for empty array"
}

# Test: cleanup_on_interrupt removes real files and directories
test_cleanup_removes_files_and_dirs() {
    mkdir -p "$TEST_TEMP_DIR/cleanup-test-dir"
    echo "test" >"$TEST_TEMP_DIR/cleanup-test-file"

    bash -c '
        log_warning() { :; }
        log_message() { :; }
        exit() { return "${1:-0}"; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup "'"$TEST_TEMP_DIR"'/cleanup-test-file"
        register_cleanup "'"$TEST_TEMP_DIR"'/cleanup-test-dir"
        cleanup_on_interrupt
    ' 2>/dev/null

    if [ -f "$TEST_TEMP_DIR/cleanup-test-file" ]; then
        assert_true false "Temp file should have been removed"
    else
        assert_true true "Temp file was removed"
    fi

    if [ -d "$TEST_TEMP_DIR/cleanup-test-dir" ]; then
        assert_true false "Temp directory should have been removed"
    else
        assert_true true "Temp directory was removed"
    fi
}

# Test: cleanup_on_interrupt skips non-existent items without error
test_cleanup_nonexistent_items() {
    local exit_code=0
    bash -c '
        log_warning() { :; }
        log_message() { :; }
        exit() { return "${1:-0}"; }
        source "'"$_CLEANUP_FUNC_FILE"'"
        register_cleanup "/tmp/does-not-exist-cleanup-test"
        cleanup_on_interrupt
    ' 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Non-existent items do not cause errors"
}

# ============================================================================
# Build-failure annotation tests (#583)
#
# cleanup_on_interrupt is the build-aborting chokepoint: on a non-zero exit
# with an active feature it emits a greppable sentinel and, under CI, a GitHub
# ::error annotation naming the feature + command. These tests drive that block
# by seeding the feature-logging globals and forcing a non-zero $? before the
# trap runs (`false` sets $? for the synthesized "$?" capture).
# ============================================================================

# Helper: run cleanup_on_interrupt with seeded failure context.
#   $1 = GITHUB_ACTIONS value ("true" or empty)
#   $2 = exit status to simulate (the value of $? when the trap fires)
_run_failure_trap() {
    local gha="$1" status="$2"
    bash -c '
        log_warning() { :; }
        log_message() { :; }
        exit() { return "${1:-0}"; }
        export GITHUB_ACTIONS="'"$gha"'"
        export CURRENT_FEATURE="Demo Feature"
        export COMMAND_COUNT=3
        export LAST_COMMAND_DESC="Installing widget"
        export LAST_COMMAND_TEXT="apt-get install widget"
        export BUILD_LOG_DIR="'"$TEST_TEMP_DIR"'"
        source "'"$_CLEANUP_FUNC_FILE"'"
        ( exit '"$status"' )   # set $? for the trap to capture
        cleanup_on_interrupt
    ' 2>&1
}

# Test: non-zero exit with active feature emits the greppable sentinel
test_failure_emits_sentinel() {
    local output
    output=$(_run_failure_trap "" 1)
    assert_contains "$output" ">>> BUILD FAILURE:" "Sentinel emitted on failure"
    assert_contains "$output" "feature='Demo Feature'" "Sentinel names the feature"
    assert_contains "$output" "command=#3" "Sentinel includes command number"
    assert_contains "$output" "desc='Installing widget'" "Sentinel includes description"
    assert_contains "$output" "cmd='apt-get install widget'" "Sentinel includes command text"
    assert_contains "$output" "exit=1" "Sentinel includes exit code"
}

# Test: sentinel is persisted to build-failure.log
test_failure_writes_log_file() {
    _run_failure_trap "" 1 >/dev/null
    if [ -f "$TEST_TEMP_DIR/build-failure.log" ]; then
        assert_contains "$(command cat "$TEST_TEMP_DIR/build-failure.log")" \
            ">>> BUILD FAILURE:" "build-failure.log records the sentinel"
    else
        assert_true false "build-failure.log should have been written"
    fi
}

# Test: under GITHUB_ACTIONS a ::error annotation is emitted
test_failure_emits_github_error_under_ci() {
    local output
    output=$(_run_failure_trap "true" 1)
    assert_contains "$output" "::error title=Build failed in Demo Feature::" \
        "::error annotation emitted under CI"
    assert_contains "$output" "COMMAND #3 'Installing widget' failed (exit 1)" \
        "::error names command + exit code"
    assert_contains "$output" "::endgroup::" "Open log group is closed before the error"
}

# Test: outside CI the sentinel appears but no ::error annotation
test_failure_no_github_error_outside_ci() {
    local output
    output=$(_run_failure_trap "" 1)
    assert_contains "$output" ">>> BUILD FAILURE:" "Sentinel still emitted outside CI"
    assert_not_contains "$output" "::error" "No ::error annotation outside CI"
}

# Test: a clean (exit 0) interrupt emits no failure annotation
test_no_failure_on_clean_exit() {
    local output
    output=$(_run_failure_trap "true" 0)
    assert_not_contains "$output" ">>> BUILD FAILURE:" "No sentinel on clean exit"
    assert_not_contains "$output" "::error" "No ::error on clean exit"
}

# Test: a failure with no active feature emits nothing (interrupt between features)
test_no_failure_without_active_feature() {
    local output
    output=$(bash -c '
        log_warning() { :; }
        log_message() { :; }
        exit() { return "${1:-0}"; }
        export GITHUB_ACTIONS="true"
        export CURRENT_FEATURE=""
        source "'"$_CLEANUP_FUNC_FILE"'"
        ( exit 1 )
        cleanup_on_interrupt
    ' 2>&1)
    assert_not_contains "$output" ">>> BUILD FAILURE:" "No sentinel without an active feature"
    assert_not_contains "$output" "::error" "No ::error without an active feature"
}

# ============================================================================
# Guard tests
# ============================================================================

# Test: _CLEANUP_HANDLER_LOADED guard prevents multiple sourcing
test_multiple_sourcing_guard() {
    # Verify guard variable exists in source
    if command grep -q '_CLEANUP_HANDLER_LOADED' "$PROJECT_ROOT/lib/base/cleanup-handler.sh"; then
        assert_true true "Multiple-sourcing guard exists"
    else
        assert_true false "Multiple-sourcing guard not found"
    fi

    # Verify re-sourcing returns 0 when already loaded
    local exit_code=0
    bash -c '
        log_warning() { :; }
        log_message() { :; }
        _CLEANUP_HANDLER_LOADED=1
        source "'"$PROJECT_ROOT"'/lib/base/cleanup-handler.sh"
    ' 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Re-sourcing returns 0 when already loaded"
}

# ============================================================================
# Run all tests
# ============================================================================
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# register_cleanup
run_test_with_setup test_register_adds_to_array "register_cleanup adds item to array"
run_test_with_setup test_register_multiple_items "register_cleanup accumulates items"
run_test_with_setup test_register_empty_arg "register_cleanup rejects empty arg with warning"

# unregister_cleanup
run_test_with_setup test_unregister_removes_item "unregister_cleanup removes item from array"
run_test_with_setup test_unregister_nonpresent_item "unregister non-present item — no error"

# cleanup_on_interrupt
run_test_with_setup test_cleanup_lifo_ordering "cleanup_on_interrupt LIFO ordering"
run_test_with_setup test_cleanup_empty_array "cleanup_on_interrupt with empty array — no crash"
run_test_with_setup test_cleanup_removes_files_and_dirs "cleanup_on_interrupt removes files and directories"
run_test_with_setup test_cleanup_nonexistent_items "cleanup_on_interrupt skips non-existent items"

# Build-failure annotation (#583)
run_test_with_setup test_failure_emits_sentinel "Failure emits greppable sentinel"
run_test_with_setup test_failure_writes_log_file "Failure sentinel persisted to build-failure.log"
run_test_with_setup test_failure_emits_github_error_under_ci "Failure emits ::error under CI"
run_test_with_setup test_failure_no_github_error_outside_ci "No ::error outside CI"
run_test_with_setup test_no_failure_on_clean_exit "No failure annotation on clean exit"
run_test_with_setup test_no_failure_without_active_feature "No failure annotation without active feature"

# Guard
run_test_with_setup test_multiple_sourcing_guard "Guard prevents multiple sourcing"

# Generate test report
generate_report
