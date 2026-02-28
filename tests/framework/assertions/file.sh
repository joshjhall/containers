#!/usr/bin/env bash
# File Assertions - File system and permission checks
# Version: 2.1.0
#
# Provides assertions for file system operations including existence checks,
# directory validation, permission verification, and content checks.
#
# Functions:
# - assert_file_exists/assert_file_not_exists: Check file existence
# - assert_dir_exists/assert_dir_not_exists: Check directory existence
# - assert_readable/assert_writable/assert_executable: Check file permissions
# - assert_file_contains/assert_file_not_contains: Check file contents
#
# Namespace: tff_ (Test Framework File)
# All local variables use the tff_ prefix.

# Assert that a file exists
#
# Usage:
#   assert_file_exists "/etc/passwd" "System password file should exist"
#   assert_file_exists "$config_file"
#
# Args:
#   $1: File path to check
#   $2: Optional message
#
# Returns:
#   0 if file exists, 1 if not
assert_file_exists() {
    local tff_file="$1"
    local tff_message="${2:-File should exist}"

    if [ -f "$tff_file" ]; then
        return 0
    else
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Message:  $tff_message"
    fi
}

# Assert that a file does not exist
#
# Usage:
#   assert_file_not_exists "/tmp/lock.file" "Lock file should be cleaned up"
#   assert_file_not_exists "$temp_file"
#
# Args:
#   $1: File path to check
#   $2: Optional message
#
# Returns:
#   0 if file doesn't exist, 1 if it does
assert_file_not_exists() {
    local tff_file="$1"
    local tff_message="${2:-File should not exist}"

    if [ ! -f "$tff_file" ]; then
        return 0
    else
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Message:  $tff_message"
    fi
}

# Assert that a directory exists
#
# Usage:
#   assert_dir_exists "$HOME/.config" "Config directory should exist"
#   assert_dir_exists "/tmp"
#
# Args:
#   $1: Directory path to check
#   $2: Optional message
#
# Returns:
#   0 if directory exists, 1 if not
assert_dir_exists() {
    local tff_dir="$1"
    local tff_message="${2:-Directory should exist}"

    if [ -d "$tff_dir" ]; then
        return 0
    else
        tf_fail_assertion \
            "Directory: '$tff_dir'" \
            "Message:   $tff_message"
    fi
}

# Assert that a directory does not exist
#
# Usage:
#   assert_dir_not_exists "$temp_dir" "Temp directory should be cleaned up"
#   assert_dir_not_exists "/nonexistent"
#
# Args:
#   $1: Directory path to check
#   $2: Optional message
#
# Returns:
#   0 if directory doesn't exist, 1 if it does
assert_dir_not_exists() {
    local tff_dir="$1"
    local tff_message="${2:-Directory should not exist}"

    if [ ! -d "$tff_dir" ]; then
        return 0
    else
        tf_fail_assertion \
            "Directory: '$tff_dir'" \
            "Message:   $tff_message"
    fi
}

# Assert that a file/directory is readable by the current user
#
# Usage:
#   assert_readable "$config_file" "Config file must be readable"
#   assert_readable "/etc/hosts"
#
# Args:
#   $1: File/directory path to check
#   $2: Optional message
#
# Returns:
#   0 if readable, 1 if not
assert_readable() {
    local tff_file="$1"
    local tff_message="${2:-File should be readable}"

    if [ -r "$tff_file" ]; then
        return 0
    else
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Message:  $tff_message"
    fi
}

# Assert that a file/directory is writable by the current user
#
# Usage:
#   assert_writable "$log_file" "Must be able to write to log file"
#   assert_writable "/tmp"
#
# Args:
#   $1: File/directory path to check
#   $2: Optional message
#
# Returns:
#   0 if writable, 1 if not
assert_writable() {
    local tff_file="$1"
    local tff_message="${2:-File should be writable}"

    if [ -w "$tff_file" ]; then
        return 0
    else
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Message:  $tff_message"
    fi
}

# Assert that a file is executable by the current user
#
# Usage:
#   assert_executable "$script_path" "Script must be executable"
#   assert_executable "/usr/bin/git"
#
# Args:
#   $1: File path to check
#   $2: Optional message
#
# Returns:
#   0 if executable, 1 if not
assert_executable() {
    local tff_file="$1"
    local tff_message="${2:-File should be executable}"

    if [ -x "$tff_file" ]; then
        return 0
    else
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Message:  $tff_message"
    fi
}

# Assert that a file contains a pattern (grep pattern)
#
# Usage:
#   assert_file_contains "$config_file" "debug=true" "Debug mode should be enabled"
#   assert_file_contains "/etc/hosts" "localhost"
#   assert_file_contains "$script" "^main()" "Script should have main function"
#
# Args:
#   $1: File path to check
#   $2: Pattern to search for (grep regex)
#   $3: Optional message
#
# Returns:
#   0 if pattern found, 1 if not
assert_file_contains() {
    local tff_file="$1"
    local tff_pattern="$2"
    local tff_message="${3:-File should contain pattern}"

    if [ ! -f "$tff_file" ]; then
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Pattern:  '$tff_pattern'" \
            "Error:    File does not exist" \
            "Message:  $tff_message"
        return 1
    fi

    if command grep -q -- "$tff_pattern" "$tff_file" 2>/dev/null; then
        return 0
    else
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Pattern:  '$tff_pattern'" \
            "Message:  $tff_message"
    fi
}

# Assert that a file does not contain a pattern
#
# Usage:
#   assert_file_not_contains "$config_file" "password=" "Config should not have plaintext password"
#   assert_file_not_contains "$script" "TODO" "No TODOs should remain"
#
# Args:
#   $1: File path to check
#   $2: Pattern to search for (grep regex)
#   $3: Optional message
#
# Returns:
#   0 if pattern not found, 1 if found
assert_file_not_contains() {
    local tff_file="$1"
    local tff_pattern="$2"
    local tff_message="${3:-File should not contain pattern}"

    if [ ! -f "$tff_file" ]; then
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Pattern:  '$tff_pattern'" \
            "Error:    File does not exist" \
            "Message:  $tff_message"
        return 1
    fi

    if ! command grep -q -- "$tff_pattern" "$tff_file" 2>/dev/null; then
        return 0
    else
        local tff_match
        tff_match=$(command grep -n -- "$tff_pattern" "$tff_file" 2>/dev/null | command head -1)
        tf_fail_assertion \
            "File:     '$tff_file'" \
            "Pattern:  '$tff_pattern'" \
            "Found:    $tff_match" \
            "Message:  $tff_message"
    fi
}

# Export all functions
export -f assert_file_exists assert_file_not_exists
export -f assert_dir_exists assert_dir_not_exists
export -f assert_readable assert_writable assert_executable
export -f assert_file_contains assert_file_not_contains
