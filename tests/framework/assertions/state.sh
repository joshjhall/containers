#!/usr/bin/env bash
# State Assertions - Function and variable state checks
# Version: 2.0.0
#
# Provides assertions for checking the state of functions and variables
# in the shell environment.
#
# Functions:
# - assert_function_exists/assert_function_not_exists: Check function definitions
# - assert_variable_set/assert_variable_unset: Check variable state
#
# Namespace: tfst_ (Test Framework State)
# All local variables use the tfst_ prefix.

# Assert that a function is defined in the current shell
#
# Usage:
#   assert_function_exists "validate_input" "Validation function required"
#   assert_function_exists "log_info" "Logging should be loaded"
#
# Args:
#   $1: Function name to check
#   $2: Optional message
#
# Returns:
#   0 if function exists, 1 if not
assert_function_exists() {
    local tfst_func_name="$1"
    local tfst_message="${2:-Function should exist}"

    if declare -f "$tfst_func_name" >/dev/null 2>&1; then
        return 0
    else
        tf_fail_assertion \
            "Function: '$tfst_func_name'" \
            "Message:  $tfst_message"
    fi
}

# Assert that a function is not defined in the current shell
#
# Usage:
#   assert_function_not_exists "deprecated_func" "Old function should be removed"
#   assert_function_not_exists "internal_helper" "Internal function should not be exported"
#
# Args:
#   $1: Function name to check
#   $2: Optional message
#
# Returns:
#   0 if function doesn't exist, 1 if it does
assert_function_not_exists() {
    local tfst_func_name="$1"
    local tfst_message="${2:-Function should not exist}"

    if ! declare -f "$tfst_func_name" >/dev/null 2>&1; then
        return 0
    else
        tf_fail_assertion \
            "Function: '$tfst_func_name' exists but should not" \
            "Message:  $tfst_message"
    fi
}

# Assert that a variable is set (defined, even if empty)
#
# Usage:
#   assert_variable_set "HOME" "HOME variable must be set"
#   assert_variable_set "CONFIG_LOADED" "Config should be loaded"
#
# Note: This checks if variable is DEFINED, not if it has a value.
#       An empty variable (VAR="") is still considered "set".
#
# Args:
#   $1: Variable name to check (without $)
#   $2: Optional message
#
# Returns:
#   0 if variable is set, 1 if not
assert_variable_set() {
    local tfst_var_name="$1"
    local tfst_message="${2:-Variable should be set}"

    if [ -n "${!tfst_var_name+x}" ]; then
        return 0
    else
        tf_fail_assertion \
            "Variable: '$tfst_var_name'" \
            "Message:  $tfst_message"
    fi
}

# Assert that a variable is not set (undefined)
#
# Usage:
#   assert_variable_unset "TEMP_VAR" "Temporary variable should be cleaned up"
#   assert_variable_unset "DEBUG_MODE" "Debug mode should not be set in production"
#
# Args:
#   $1: Variable name to check (without $)
#   $2: Optional message
#
# Returns:
#   0 if variable is unset, 1 if it's set
assert_variable_unset() {
    local tfst_var_name="$1"
    local tfst_message="${2:-Variable should be unset}"

    if [ -z "${!tfst_var_name+x}" ]; then
        return 0
    else
        tf_fail_assertion \
            "Variable: '$tfst_var_name' is set with value '${!tfst_var_name}'" \
            "Message:  $tfst_message"
    fi
}

# Export all functions
export -f assert_function_exists assert_function_not_exists
export -f assert_variable_set assert_variable_unset
