#!/usr/bin/env bash
# Unit tests for bin/fix-shell-permissions.sh
# Tests the pre-commit hook for shell script executable permissions

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Bin Fix Shell Permissions Tests"

SCRIPT="$PROJECT_ROOT/bin/fix-shell-permissions.sh"

# Setup function - runs before each test
setup() {
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(mktemp -d -t "fix-perms-test-XXXXXX")

    # Create a temporary git repo for realistic testing
    export TEST_REPO="$TEST_TEMP_DIR/repo"
    mkdir -p "$TEST_REPO"
    git -C "$TEST_REPO" init -q
    git -C "$TEST_REPO" config user.email "test@test.com"
    git -C "$TEST_REPO" config user.name "Test"
}

# Teardown function - runs after each test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR TEST_REPO
}

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$SCRIPT"
    assert_executable "$SCRIPT"
}

# Test: Valid bash syntax
test_valid_syntax() {
    local exit_code=0
    bash -n "$SCRIPT" 2>/dev/null || exit_code=$?
    assert_equals "0" "$exit_code" "Script should have valid bash syntax"
}

# Test: No arguments → exit 0 (nothing to fix)
test_no_args_exits_0() {
    local exit_code=0
    (cd "$TEST_REPO" && "$SCRIPT") || exit_code=$?
    assert_equals "0" "$exit_code" "Script should exit 0 when no files provided"
}

# Test: Already executable file → exit 0 (no fix needed)
test_already_executable_exits_0() {
    # Create a script and add it with executable permission
    echo '#!/bin/bash' > "$TEST_REPO/already-exec.sh"
    chmod +x "$TEST_REPO/already-exec.sh"
    git -C "$TEST_REPO" add "$TEST_REPO/already-exec.sh"
    git -C "$TEST_REPO" update-index --chmod=+x "$TEST_REPO/already-exec.sh"

    local exit_code=0
    local output
    output=$(cd "$TEST_REPO" && "$SCRIPT" "already-exec.sh" 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for already-executable file"
    assert_not_contains "$output" "Fixed" "Should not report fixing an already-executable file"
}

# Test: Non-executable .sh file → outputs "Fixed" and exits 1
test_non_executable_outputs_fixed() {
    # Create a script and add it WITHOUT executable permission
    echo '#!/bin/bash' > "$TEST_REPO/needs-fix.sh"
    chmod 644 "$TEST_REPO/needs-fix.sh"
    git -C "$TEST_REPO" add "$TEST_REPO/needs-fix.sh"

    local exit_code=0
    local output
    output=$(cd "$TEST_REPO" && "$SCRIPT" "needs-fix.sh" 2>&1) || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when files were fixed"
    assert_contains "$output" "Fixed" "Should report fixing the file"
    assert_contains "$output" "needs-fix.sh" "Should mention the fixed filename"
    assert_contains "$output" "100644 -> 100755" "Should show mode change"
}

# Test: File not in git index → exit 0 (nothing to fix)
test_file_not_in_index_exits_0() {
    # Create a file but don't git-add it
    echo '#!/bin/bash' > "$TEST_REPO/untracked.sh"

    local exit_code=0
    local output
    output=$(cd "$TEST_REPO" && "$SCRIPT" "untracked.sh" 2>&1) || exit_code=$?
    assert_equals "0" "$exit_code" "Should exit 0 for file not in git index"
    assert_not_contains "$output" "Fixed" "Should not report fixing untracked file"
}

# Test: Exit code is 1 when files were fixed (pre-commit convention)
test_exit_code_1_when_fixed() {
    # Add multiple files: one needs fixing, one is fine
    echo '#!/bin/bash' > "$TEST_REPO/ok.sh"
    chmod +x "$TEST_REPO/ok.sh"
    git -C "$TEST_REPO" add "$TEST_REPO/ok.sh"
    git -C "$TEST_REPO" update-index --chmod=+x "$TEST_REPO/ok.sh"

    echo '#!/bin/bash' > "$TEST_REPO/bad.sh"
    chmod 644 "$TEST_REPO/bad.sh"
    git -C "$TEST_REPO" add "$TEST_REPO/bad.sh"

    local exit_code=0
    (cd "$TEST_REPO" && "$SCRIPT" "ok.sh" "bad.sh") >/dev/null 2>&1 || exit_code=$?
    assert_equals "1" "$exit_code" "Should exit 1 when any file was fixed"
}

# Run all tests
run_test test_script_exists "Script exists and is executable"
run_test test_valid_syntax "Valid bash syntax"
run_test test_no_args_exits_0 "No arguments exits with code 0"
run_test test_already_executable_exits_0 "Already executable file exits 0"
run_test test_non_executable_outputs_fixed "Non-executable file outputs Fixed"
run_test test_file_not_in_index_exits_0 "File not in git index exits 0"
run_test test_exit_code_1_when_fixed "Exit code 1 when files were fixed"

# Generate test report
generate_report
