#!/usr/bin/env bash
# Core Assertions - Basic true/false and exit code checks
# Version: 2.0.0
#
# Provides fundamental assertion functions for boolean logic and exit codes.
# These are the most commonly used assertions in the test framework.
#
# Functions:
# - assert_true/false: Multi-purpose assertions that can execute commands or check exit codes
# - assert_exit_code: Check specific exit code values
# - pass_test/fail_test/skip_test: Manual test control
#
# Namespace: tfc_ (Test Framework Core)
# All local variables and internal functions use the tfc_ prefix.

# Original assert_true/false that take exit codes
tfc_assert_true_exit_code() {
    local tfc_exit_code="$1"
    local tfc_message="${2:-Command should succeed (exit 0)}"

    if [[ "$tfc_exit_code" -eq 0 ]]; then
        return 0
    else
        tf_fail_assertion \
            "Exit code: $tfc_exit_code (expected 0)" \
            "Message:   $tfc_message"
    fi
}

tfc_assert_false_exit_code() {
    local tfc_exit_code="$1"
    local tfc_message="${2:-Command should fail (non-zero exit)}"

    if [[ "$tfc_exit_code" -ne 0 ]]; then
        return 0
    else
        tf_fail_assertion \
            "Exit code: $tfc_exit_code (expected non-zero)" \
            "Message:   $tfc_message"
    fi
}

# Assert that a command succeeds or an exit code is 0
#
# This is a multi-purpose assertion that can:
# 1. Execute a command and check if it succeeds (exit 0)
# 2. Check if a provided exit code is 0
#
# Usage:
#   assert_true [ -f "/etc/passwd" ] "File should exist"   # Execute test command
#   assert_true grep -q "pattern" file.txt "Should find pattern"
#   assert_true 0 "Exit code should be 0"                   # Check exit code
#
# Args:
#   $1: Command to execute OR numeric exit code
#   $@: Additional command arguments and optional message
#   Last arg: Optional message (detected by spaces or capital letter)
#
# Returns:
#   0 if assertion passes, 1 if it fails
assert_true() {
    # If first arg is a number, treat as exit code (backward compatible)
    if [[ "$1" =~ ^-?[0-9]+$ ]]; then
        tfc_assert_true_exit_code "$@"
        return $?
    fi

    # For new syntax, we use eval but in a controlled way:
    # 1. This is test framework code, not production
    # 2. The entire command comes from the test author
    # 3. We're not interpolating user input

    # Find the last argument to check if it's a message
    local tfc_all_args=("$@")
    local tfc_last="${tfc_all_args[*]: -1}"
    local tfc_message="Command should succeed"
    local tfc_cmd

    # If last arg contains spaces or starts with capital, it's likely a message
    if [[ "$tfc_last" =~ [[:space:]] ]] || [[ "$tfc_last" =~ ^[A-Z] ]]; then
        tfc_message="$tfc_last"
        # Get all but last argument
        tfc_cmd="${tfc_all_args[*]:0:${#tfc_all_args[@]}-1}"
    else
        tfc_cmd="$*"
    fi

    # Execute the command and preserve output for debugging
    eval "$tfc_cmd"
    tfc_assert_true_exit_code $? "$tfc_message"
}

# Assert that a command fails or an exit code is non-zero
#
# This is a multi-purpose assertion that can:
# 1. Execute a command and check if it fails (non-zero exit)
# 2. Check if a provided exit code is non-zero
#
# Usage:
#   assert_false [ -f "/nonexistent" ] "File should not exist"
#   assert_false grep -q "missing" file.txt "Should not find pattern"
#   assert_false 1 "Exit code should be non-zero"
#
# Args:
#   $1: Command to execute OR numeric exit code
#   $@: Additional command arguments and optional message
#   Last arg: Optional message (detected by spaces or capital letter)
#
# Returns:
#   0 if assertion passes, 1 if it fails
assert_false() {
    # If first arg is a number, treat as exit code (backward compatible)
    if [[ "$1" =~ ^-?[0-9]+$ ]]; then
        tfc_assert_false_exit_code "$@"
        return $?
    fi

    # Find the last argument to check if it's a message
    local tfc_all_args=("$@")
    local tfc_last="${tfc_all_args[*]: -1}"
    local tfc_message="Command should fail"
    local tfc_cmd

    # If last arg contains spaces or starts with capital, it's likely a message
    if [[ "$tfc_last" =~ [[:space:]] ]] || [[ "$tfc_last" =~ ^[A-Z] ]]; then
        tfc_message="$tfc_last"
        # Get all but last argument
        tfc_cmd="${tfc_all_args[*]:0:${#tfc_all_args[@]}-1}"
    else
        tfc_cmd="$*"
    fi

    # Execute the command and preserve output for debugging
    eval "$tfc_cmd"
    tfc_assert_false_exit_code $? "$tfc_message"
}

# Assert that an exit code matches an expected value
#
# Usage:
#   assert_exit_code 0 $? "Command should succeed"
#   assert_exit_code 2 $exit_code "Should return error code 2"
#
# Args:
#   $1: Expected exit code
#   $2: Actual exit code
#   $3: Optional message
#
# Returns:
#   0 if codes match, 1 if they don't
assert_exit_code() {
    local tfc_expected="$1"
    local tfc_actual="$2"
    local tfc_message="${3:-Exit code should match}"

    if [ "$tfc_expected" = "$tfc_actual" ]; then
        return 0
    else
        tf_fail_assertion \
            "Expected exit: $tfc_expected" \
            "Actual exit:   $tfc_actual" \
            "Message:       $tfc_message"
    fi
}

# Manually mark the current test as passed
#
# Usage:
#   if complex_check; then
#       pass_test
#   else
#       fail_test "Complex check failed"
#   fi
#
# Returns:
#   Always returns 0
pass_test() {
    echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

# Manually mark the current test as failed with a reason
#
# Usage:
#   fail_test "Unable to connect to database"
#
# Args:
#   $1: Failure message/reason
#
# Returns:
#   Always returns 1
fail_test() {
    local tfc_message="$1"
    echo -e "${TEST_COLOR_FAIL}FAIL${TEST_COLOR_RESET}"
    echo "    Message: $tfc_message"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Skip the current test with a reason
#
# Usage:
#   if ! command -v docker >/dev/null; then
#       skip_test "Docker not installed"
#       return
#   fi
#
# Args:
#   $1: Reason for skipping
#
# Returns:
#   Always returns 0
skip_test() {
    local tfc_reason="$1"
    echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
    echo "    Reason: $tfc_reason"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

# Export all functions
export -f assert_true assert_false tfc_assert_true_exit_code tfc_assert_false_exit_code
export -f assert_exit_code pass_test fail_test skip_test
