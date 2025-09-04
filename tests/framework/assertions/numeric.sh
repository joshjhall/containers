#!/usr/bin/env bash
# Numeric Assertions - Numeric comparison checks
# Version: 2.0.0
#
# Provides assertions for comparing numeric values.
# All functions validate that inputs are numeric before comparison.
#
# Functions:
# - assert_greater_than: Check value is greater than expected
# - assert_less_than: Check value is less than expected
# - assert_greater_or_equal: Check value is greater than or equal to expected
# - assert_less_or_equal: Check value is less than or equal to expected
#
# Namespace: tfn_ (Test Framework Numeric)
# All local variables use the tfn_ prefix.

# Assert that a value is greater than expected
#
# Usage:
#   assert_greater_than $count 10 "Should have more than 10 items"
#   assert_greater_than "${#array[@]}" 0 "Array should not be empty"
#
# Args:
#   $1: Actual value (must be numeric)
#   $2: Expected value (must be numeric)
#   $3: Optional message
#
# Returns:
#   0 if actual > expected, 1 if not (or if non-numeric)
assert_greater_than() {
    local tfn_actual="$1"
    local tfn_expected="$2"
    local tfn_message="${3:-Value should be greater than expected}"

    # Validate numeric inputs
    if ! [[ "$tfn_actual" =~ ^-?[0-9]+$ ]] || ! [[ "$tfn_expected" =~ ^-?[0-9]+$ ]]; then
        tf_fail_assertion \
            "Error: Non-numeric values provided" \
            "Actual:   '$tfn_actual'" \
            "Expected: '$tfn_expected'"
        return 1
    fi

    if [ "$tfn_actual" -gt "$tfn_expected" ]; then
        return 0
    else
        tf_fail_assertion \
            "Actual:   $tfn_actual" \
            "Expected: > $tfn_expected" \
            "Message:  $tfn_message"
    fi
}

# Assert that a value is less than expected
#
# Usage:
#   assert_less_than $error_count 5 "Should have fewer than 5 errors"
#   assert_less_than $elapsed_time 1000 "Should complete in under 1 second"
#
# Args:
#   $1: Actual value (must be numeric)
#   $2: Expected value (must be numeric)
#   $3: Optional message
#
# Returns:
#   0 if actual < expected, 1 if not (or if non-numeric)
assert_less_than() {
    local tfn_actual="$1"
    local tfn_expected="$2"
    local tfn_message="${3:-Value should be less than expected}"

    # Validate numeric inputs
    if ! [[ "$tfn_actual" =~ ^-?[0-9]+$ ]] || ! [[ "$tfn_expected" =~ ^-?[0-9]+$ ]]; then
        tf_fail_assertion \
            "Error: Non-numeric values provided" \
            "Actual:   '$tfn_actual'" \
            "Expected: '$tfn_expected'"
        return 1
    fi

    if [ "$tfn_actual" -lt "$tfn_expected" ]; then
        return 0
    else
        tf_fail_assertion \
            "Actual:   $tfn_actual" \
            "Expected: < $tfn_expected" \
            "Message:  $tfn_message"
    fi
}

# Assert that a value is greater than or equal to expected
#
# Usage:
#   assert_greater_or_equal $score 70 "Should pass with 70 or higher"
#   assert_greater_or_equal $count 1 "Should have at least one item"
#
# Args:
#   $1: Actual value (must be numeric)
#   $2: Expected value (must be numeric)
#   $3: Optional message
#
# Returns:
#   0 if actual >= expected, 1 if not (or if non-numeric)
assert_greater_or_equal() {
    local tfn_actual="$1"
    local tfn_expected="$2"
    local tfn_message="${3:-Value should be greater than or equal to expected}"

    # Validate numeric inputs
    if ! [[ "$tfn_actual" =~ ^-?[0-9]+$ ]] || ! [[ "$tfn_expected" =~ ^-?[0-9]+$ ]]; then
        tf_fail_assertion \
            "Error: Non-numeric values provided" \
            "Actual:   '$tfn_actual'" \
            "Expected: '$tfn_expected'"
        return 1
    fi

    if [ "$tfn_actual" -ge "$tfn_expected" ]; then
        return 0
    else
        tf_fail_assertion \
            "Actual:   $tfn_actual" \
            "Expected: >= $tfn_expected" \
            "Message:  $tfn_message"
    fi
}

# Assert that a value is less than or equal to expected
#
# Usage:
#   assert_less_or_equal $retry_count 3 "Should retry at most 3 times"
#   assert_less_or_equal $cpu_usage 80 "CPU should not exceed 80%"
#
# Args:
#   $1: Actual value (must be numeric)
#   $2: Expected value (must be numeric)
#   $3: Optional message
#
# Returns:
#   0 if actual <= expected, 1 if not (or if non-numeric)
assert_less_or_equal() {
    local tfn_actual="$1"
    local tfn_expected="$2"
    local tfn_message="${3:-Value should be less than or equal to expected}"

    # Validate numeric inputs
    if ! [[ "$tfn_actual" =~ ^-?[0-9]+$ ]] || ! [[ "$tfn_expected" =~ ^-?[0-9]+$ ]]; then
        tf_fail_assertion \
            "Error: Non-numeric values provided" \
            "Actual:   '$tfn_actual'" \
            "Expected: '$tfn_expected'"
        return 1
    fi

    if [ "$tfn_actual" -le "$tfn_expected" ]; then
        return 0
    else
        tf_fail_assertion \
            "Actual:   $tfn_actual" \
            "Expected: <= $tfn_expected" \
            "Message:  $tfn_message"
    fi
}

# Export all functions
export -f assert_greater_than assert_less_than
export -f assert_greater_or_equal assert_less_or_equal
