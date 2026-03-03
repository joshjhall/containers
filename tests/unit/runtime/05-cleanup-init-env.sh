#!/usr/bin/env bash
# Unit tests for lib/runtime/05-cleanup-init-env.sh
# Tests the container-side cleanup of .devcontainer/.env

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "05-cleanup-init-env Startup Script Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/05-cleanup-init-env.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-cleanup-init-env-$unique_id"
    command mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR SKIP_INIT_ENV_CLEANUP WORKSPACE_ROOT 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "05-cleanup-init-env.sh should exist"

    if [ -x "$SOURCE_FILE" ]; then
        pass_test "05-cleanup-init-env.sh is executable"
    else
        fail_test "05-cleanup-init-env.sh is not executable"
    fi
}

test_syntax_valid() {
    if bash -n "$SOURCE_FILE" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

test_has_skip_gate() {
    assert_file_contains "$SOURCE_FILE" "SKIP_INIT_ENV_CLEANUP" \
        "Script checks SKIP_INIT_ENV_CLEANUP variable"
}

test_uses_full_paths() {
    assert_file_contains "$SOURCE_FILE" "/usr/bin/shred" \
        "Uses full path for shred"
    assert_file_contains "$SOURCE_FILE" "/usr/bin/rm" \
        "Uses full path for rm"
}

test_uses_shred() {
    assert_file_contains "$SOURCE_FILE" "shred" \
        "Script uses shred for secure deletion"
}

test_checks_devcontainer_env() {
    assert_file_contains "$SOURCE_FILE" ".devcontainer/.env" \
        "Script checks for .devcontainer/.env"
}

test_checks_workspace_root() {
    assert_file_contains "$SOURCE_FILE" "WORKSPACE_ROOT" \
        "Script uses WORKSPACE_ROOT variable"
}

# ============================================================================
# Behavioral Tests
# ============================================================================

test_no_file_clean_exit() {
    # No .devcontainer/.env → exit 0
    command mkdir -p "$TEST_TEMP_DIR/workspace"
    (
        cd "$TEST_TEMP_DIR/workspace"
        WORKSPACE_ROOT="$TEST_TEMP_DIR/workspace" bash "$SOURCE_FILE"
    )
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        pass_test "Clean exit when .devcontainer/.env does not exist"
    else
        fail_test "Expected exit 0, got $rc"
    fi
}

test_file_deleted() {
    command mkdir -p "$TEST_TEMP_DIR/workspace/.devcontainer"
    printf 'SECRET=value\n' > "$TEST_TEMP_DIR/workspace/.devcontainer/.env"

    (
        cd "$TEST_TEMP_DIR/workspace"
        WORKSPACE_ROOT="$TEST_TEMP_DIR/workspace" bash "$SOURCE_FILE"
    )

    if [ -f "$TEST_TEMP_DIR/workspace/.devcontainer/.env" ]; then
        fail_test ".devcontainer/.env should be deleted after cleanup"
    else
        pass_test ".devcontainer/.env successfully deleted"
    fi
}

test_skip_gate_works() {
    command mkdir -p "$TEST_TEMP_DIR/workspace/.devcontainer"
    printf 'SECRET=value\n' > "$TEST_TEMP_DIR/workspace/.devcontainer/.env"

    (
        cd "$TEST_TEMP_DIR/workspace"
        SKIP_INIT_ENV_CLEANUP=true WORKSPACE_ROOT="$TEST_TEMP_DIR/workspace" bash "$SOURCE_FILE"
    )

    if [ -f "$TEST_TEMP_DIR/workspace/.devcontainer/.env" ]; then
        pass_test "Skip gate preserves .devcontainer/.env"
    else
        fail_test "Skip gate did not prevent deletion"
    fi
}

test_idempotent() {
    command mkdir -p "$TEST_TEMP_DIR/workspace/.devcontainer"
    printf 'SECRET=value\n' > "$TEST_TEMP_DIR/workspace/.devcontainer/.env"

    # Run twice
    (
        cd "$TEST_TEMP_DIR/workspace"
        WORKSPACE_ROOT="$TEST_TEMP_DIR/workspace" bash "$SOURCE_FILE"
    )
    local rc1=$?

    (
        cd "$TEST_TEMP_DIR/workspace"
        WORKSPACE_ROOT="$TEST_TEMP_DIR/workspace" bash "$SOURCE_FILE"
    )
    local rc2=$?

    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; then
        pass_test "Idempotent — no error on second run"
    else
        fail_test "Expected exit 0 on both runs, got $rc1 and $rc2"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script has valid bash syntax"
run_test test_has_skip_gate "Has skip gate for SKIP_INIT_ENV_CLEANUP"
run_test test_uses_full_paths "Uses full paths for commands"
run_test test_uses_shred "Uses shred for secure deletion"
run_test test_checks_devcontainer_env "Checks .devcontainer/.env"
run_test test_checks_workspace_root "Uses WORKSPACE_ROOT"

# Behavioral tests
run_test_with_setup test_no_file_clean_exit "No file → clean exit"
run_test_with_setup test_file_deleted "File exists → deleted"
run_test_with_setup test_skip_gate_works "Skip gate works"
run_test_with_setup test_idempotent "Idempotent (run twice, no error)"

# Generate test report
generate_report
