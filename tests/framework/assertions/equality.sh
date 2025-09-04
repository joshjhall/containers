#!/usr/bin/env bash
# Equality Assertions - Value comparison checks
# Version: 2.0.0
#
# Provides assertions for comparing values for equality or inequality.
# These are fundamental assertions used throughout test suites.
#
# Functions:
# - assert_equals: Check two values are equal
# - assert_not_equals: Check two values are not equal
#
# Namespace: tfe_ (Test Framework Equality)
# All local variables use the tfe_ prefix.

# Assert that two values are equal
#
# Usage:
#   assert_equals "expected" "$actual" "Values should match"
#   assert_equals 0 $? "Command should succeed"
#   assert_equals "${#array[@]}" 5 "Array should have 5 elements"
#
# Args:
#   $1: Expected value
#   $2: Actual value
#   $3: Optional message
#
# Returns:
#   0 if values match, 1 if not
assert_equals() {
    local tfe_expected="$1"
    local tfe_actual="$2"
    local tfe_message="${3:-Values should be equal}"

    if [ "$tfe_expected" = "$tfe_actual" ]; then
        return 0
    else
        tf_fail_assertion \
            "Expected: '$tfe_expected'" \
            "Actual:   '$tfe_actual'" \
            "Message:  $tfe_message"
    fi
}

# Assert that two values are not equal
#
# Usage:
#   assert_not_equals "error" "$status" "Should not be in error state"
#   assert_not_equals 0 $error_count "Should have some errors"
#   assert_not_equals "$old_value" "$new_value" "Value should have changed"
#
# Args:
#   $1: Unexpected value (value that actual should NOT be)
#   $2: Actual value
#   $3: Optional message
#
# Returns:
#   0 if values differ, 1 if they match
assert_not_equals() {
    local tfe_unexpected="$1"
    local tfe_actual="$2"
    local tfe_message="${3:-Values should not be equal}"

    if [ "$tfe_unexpected" != "$tfe_actual" ]; then
        return 0
    else
        tf_fail_assertion \
            "Unexpected: '$tfe_unexpected'" \
            "Actual:     '$tfe_actual'" \
            "Message:    $tfe_message"
    fi
}

# Export all functions
export -f assert_equals assert_not_equals
