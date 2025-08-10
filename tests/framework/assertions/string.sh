#!/usr/bin/env bash
# String Assertions - String content and pattern matching
# Version: 2.0.0
#
# Provides assertions for string manipulation, pattern matching, and content checks.
# Includes substring searches, regex matching, prefix/suffix checks, and length validation.
#
# Functions:
# - assert_contains/assert_not_contains: Check for substrings
# - assert_matches: Check regex pattern match
# - assert_starts_with/assert_ends_with: Check string boundaries
# - assert_length: Check string length
# - assert_empty/assert_not_empty: Check for empty values
#
# Namespace: tfs_ (Test Framework String)
# All local variables use the tfs_ prefix.

# Assert that a string contains a substring
#
# Usage:
#   assert_contains "$output" "success" "Output should contain success"
#   assert_contains "hello world" "world"
#
# Args:
#   $1: Haystack (string to search in)
#   $2: Needle (substring to find)
#   $3: Optional message
#
# Returns:
#   0 if substring found, 1 if not
assert_contains() {
    local tfs_haystack="$1"
    local tfs_needle="$2"
    local tfs_message="${3:-String should contain substring}"

    if [[ "$tfs_haystack" == *"$tfs_needle"* ]]; then
        return 0
    else
        tf_fail_assertion \
            "String:   '$tfs_haystack'" \
            "Missing:  '$tfs_needle'" \
            "Message:  $tfs_message"
    fi
}

# Assert that a string does not contain a substring
#
# Usage:
#   assert_not_contains "$output" "error" "Output should not have errors"
#   assert_not_contains "hello world" "goodbye"
#
# Args:
#   $1: Haystack (string to search in)
#   $2: Needle (substring that should not exist)
#   $3: Optional message
#
# Returns:
#   0 if substring not found, 1 if found
assert_not_contains() {
    local tfs_haystack="$1"
    local tfs_needle="$2"
    local tfs_message="${3:-String should not contain substring}"

    if [[ "$tfs_haystack" != *"$tfs_needle"* ]]; then
        return 0
    else
        tf_fail_assertion \
            "String:      '$tfs_haystack'" \
            "Should not:  '$tfs_needle'" \
            "Message:     $tfs_message"
    fi
}

# Assert that a string matches a regular expression pattern
#
# Usage:
#   assert_matches "$email" "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$" "Valid email"
#   assert_matches "$output" "[0-9]+" "Should contain numbers"
#
# Args:
#   $1: String to test
#   $2: Regex pattern (Bash regex syntax)
#   $3: Optional message
#
# Returns:
#   0 if pattern matches, 1 if not
assert_matches() {
    local tfs_string="$1"
    local tfs_pattern="$2"
    local tfs_message="${3:-String should match pattern}"

    if [[ "$tfs_string" =~ $tfs_pattern ]]; then
        return 0
    else
        tf_fail_assertion \
            "String:   '$tfs_string'" \
            "Pattern:  '$tfs_pattern'" \
            "Message:  $tfs_message"
    fi
}

# Assert that a string starts with a specific prefix
#
# Usage:
#   assert_starts_with "$filename" "/tmp/" "Should be in temp directory"
#   assert_starts_with "hello world" "hello"
#
# Args:
#   $1: String to test
#   $2: Expected prefix
#   $3: Optional message
#
# Returns:
#   0 if string starts with prefix, 1 if not
assert_starts_with() {
    local tfs_string="$1"
    local tfs_prefix="$2"
    local tfs_message="${3:-String should start with prefix}"

    if [[ "$tfs_string" == "$tfs_prefix"* ]]; then
        return 0
    else
        tf_fail_assertion \
            "String:   '$tfs_string'" \
            "Prefix:   '$tfs_prefix'" \
            "Message:  $tfs_message"
    fi
}

# Assert that a string ends with a specific suffix
#
# Usage:
#   assert_ends_with "$filename" ".txt" "Should be a text file"
#   assert_ends_with "hello world" "world"
#
# Args:
#   $1: String to test
#   $2: Expected suffix
#   $3: Optional message
#
# Returns:
#   0 if string ends with suffix, 1 if not
assert_ends_with() {
    local tfs_string="$1"
    local tfs_suffix="$2"
    local tfs_message="${3:-String should end with suffix}"

    if [[ "$tfs_string" == *"$tfs_suffix" ]]; then
        return 0
    else
        tf_fail_assertion \
            "String:   '$tfs_string'" \
            "Suffix:   '$tfs_suffix'" \
            "Message:  $tfs_message"
    fi
}

# Assert that a string has a specific length
#
# Usage:
#   assert_length "$zip_code" 5 "ZIP code should be 5 digits"
#   assert_length "abc" 3
#
# Args:
#   $1: String to measure
#   $2: Expected length
#   $3: Optional message
#
# Returns:
#   0 if length matches, 1 if not
assert_length() {
    local tfs_value="$1"
    local tfs_expected_length="$2"
    local tfs_message="${3:-Length should match expected}"
    local tfs_actual_length=${#tfs_value}

    if [ "$tfs_actual_length" -eq "$tfs_expected_length" ]; then
        return 0
    else
        tf_fail_assertion \
            "Value:    '$tfs_value'" \
            "Length:   $tfs_actual_length" \
            "Expected: $tfs_expected_length" \
            "Message:  $tfs_message"
    fi
}

# Assert that a value is empty (zero length)
#
# Usage:
#   assert_empty "$error_message" "No errors should occur"
#   assert_empty "${optional_var:-}"
#
# Args:
#   $1: Value to test
#   $2: Optional message
#
# Returns:
#   0 if value is empty, 1 if not
assert_empty() {
    local tfs_value="$1"
    local tfs_message="${2:-Value should be empty}"

    if [ -z "$tfs_value" ]; then
        return 0
    else
        tf_fail_assertion \
            "Value:    '$tfs_value'" \
            "Message:  $tfs_message"
    fi
}

# Assert that a value is not empty (has content)
#
# Usage:
#   assert_not_empty "$username" "Username is required"
#   assert_not_empty "${API_KEY:-}" "API key must be set"
#
# Args:
#   $1: Value to test
#   $2: Optional message
#
# Returns:
#   0 if value has content, 1 if empty
assert_not_empty() {
    local tfs_value="$1"
    local tfs_message="${2:-Value should not be empty}"

    if [ -n "$tfs_value" ]; then
        return 0
    else
        tf_fail_assertion \
            "Value:    (empty)" \
            "Message:  $tfs_message"
    fi
}

# Export all functions
export -f assert_contains assert_not_contains assert_matches
export -f assert_starts_with assert_ends_with assert_length
export -f assert_empty assert_not_empty
