#!/usr/bin/env bash
# Exit code assertion functions for test framework
#
# Provides assertions for checking command exit codes in a single line
# These functions execute commands and check their exit codes

# Assert that a command exits with a specific code
# Usage: assert_exit_code_equals expected_code command [args...]
# Example: assert_exit_code_equals 0 ls /tmp "Should succeed"
# Example: assert_exit_code_equals 1 with_warnings_suppressed false "Should fail with code 1"
assert_exit_code_equals() {
    local expected_code="$1"
    shift

    # Extract message if last arg contains spaces or starts with uppercase
    local message=""
    local args=("$@")
    local last_arg="${args[-1]}"

    if [[ "$last_arg" =~ \  ]] || [[ "$last_arg" =~ ^[A-Z] ]]; then
        message="$last_arg"
        unset 'args[-1]'
    fi

    # Execute the command
    "${args[@]}"
    local actual_code=$?

    if [ "$actual_code" -eq "$expected_code" ]; then
        return 0
    else
        tf_fail_assertion \
            "Expected exit code: $expected_code" \
            "Actual exit code:   $actual_code" \
            "Command: ${args[*]}" \
            "${message:-Exit codes should match}"
        return 1
    fi
}

# Assert that a command does NOT exit with a specific code
# Usage: assert_exit_code_not_equals unexpected_code command [args...]
# Example: assert_exit_code_not_equals 0 false "Should not succeed"
assert_exit_code_not_equals() {
    local unexpected_code="$1"
    shift

    # Extract message if last arg contains spaces or starts with uppercase
    local message=""
    local args=("$@")
    local last_arg="${args[-1]}"

    if [[ "$last_arg" =~ \  ]] || [[ "$last_arg" =~ ^[A-Z] ]]; then
        message="$last_arg"
        unset 'args[-1]'
    fi

    # Execute the command
    "${args[@]}"
    local actual_code=$?

    if [ "$actual_code" -ne "$unexpected_code" ]; then
        return 0
    else
        tf_fail_assertion \
            "Should NOT exit with code: $unexpected_code" \
            "But got exit code:         $actual_code" \
            "Command: ${args[*]}" \
            "${message:-Exit code should be different}"
        return 1
    fi
}

# Assert that a command exits with code 0 (success)
# This is an alias for assert_true but more explicit about checking exit codes
# Usage: assert_exit_code_success command [args...]
# Example: assert_exit_code_success ls /tmp "Should list directory successfully"
assert_exit_code_success() {
    assert_exit_code_equals 0 "$@"
}

# Assert that a command exits with non-zero code (failure)
# This is an alias for assert_false but more explicit about checking exit codes
# Usage: assert_exit_code_failure command [args...]
# Example: assert_exit_code_failure ls /nonexistent "Should fail to list nonexistent directory"
assert_exit_code_failure() {
    # Extract message if last arg contains spaces or starts with uppercase
    local message=""
    local args=("$@")
    local last_arg="${args[-1]}"

    if [[ "$last_arg" =~ \  ]] || [[ "$last_arg" =~ ^[A-Z] ]]; then
        message="$last_arg"
        unset 'args[-1]'
    fi

    # Execute the command
    "${args[@]}"
    local actual_code=$?

    if [ "$actual_code" -ne 0 ]; then
        return 0
    else
        tf_fail_assertion \
            "Expected non-zero exit code" \
            "But got exit code: 0 (success)" \
            "Command: ${args[*]}" \
            "${message:-Command should fail}"
        return 1
    fi
}

# Export all functions
export -f assert_exit_code_equals
export -f assert_exit_code_not_equals
export -f assert_exit_code_success
export -f assert_exit_code_failure
