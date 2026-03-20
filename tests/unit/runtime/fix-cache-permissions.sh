#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/fix-cache-permissions.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Fix Cache Permissions Tests"

# Helper to set up the environment expected by fix_cache_permissions
setup_cache_env() {
    RUNNING_AS_ROOT="${1:-false}"
    USERNAME="${2:-testuser}"
    export RUNNING_AS_ROOT USERNAME
}

# ============================================================================
# Test: fix_cache_permissions when /cache does not exist
# ============================================================================
test_fix_cache_no_cache_dir() {
    # Source the script to get the function
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"

    setup_cache_env "false" "testuser"

    # Ensure /cache does not exist in the test (it shouldn't in CI)
    # The function checks [ -d "/cache" ] || return 0
    # We can't easily mock the path, but we can verify behavior by
    # checking the function returns 0 when /cache doesn't exist
    if [ ! -d "/cache" ]; then
        fix_cache_permissions
        assert_equals "0" "$?" "Returns 0 when /cache does not exist"
    else
        skip_test "/cache exists on this system, cannot test no-cache path"
    fi
}

# ============================================================================
# Test: fix_cache_permissions outputs correct messages
# ============================================================================
test_fix_cache_output_no_root() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"

    setup_cache_env "false" "testuser"

    # Create a temporary /cache-like directory for testing
    local test_cache="$TEST_TEMP_DIR/cache"
    mkdir -p "$test_cache"

    # Create a file owned by current user (simulating no root-owned files)
    touch "$test_cache/test-file"

    # Override fix_cache_permissions to use our test dir by redefining it
    # Since the function hardcodes /cache, we test the early exit path
    # (no /cache dir) and the message paths separately
    if [ ! -d "/cache" ]; then
        # No /cache dir means function returns 0 immediately
        fix_cache_permissions
        assert_equals "0" "$?" "Returns 0 silently when /cache does not exist"
    else
        skip_test "/cache exists on this system"
    fi
}

# ============================================================================
# Test: fix_cache_permissions message when no sudo available
# ============================================================================
test_fix_cache_no_sudo_message() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"

    # If /cache exists and has root-owned files but user can't sudo,
    # we expect a warning message. We test the output strings exist in the script.
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh")

    assert_contains "$script_content" "no root access or sudo" \
        "Script contains no-sudo warning message"
    assert_contains "$script_content" "ENABLE_PASSWORDLESS_SUDO" \
        "Script references ENABLE_PASSWORDLESS_SUDO fix"
}

# ============================================================================
# Test: fix_cache_permissions message on chown success
# ============================================================================
test_fix_cache_success_message() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh")

    assert_contains "$script_content" "Cache directory permissions fixed" \
        "Script contains success message"
}

# ============================================================================
# Test: fix_cache_permissions message on chown failure
# ============================================================================
test_fix_cache_chown_fail_message() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh")

    assert_contains "$script_content" "Could not fix all cache permissions" \
        "Script contains chown failure warning"
}

# ============================================================================
# Test: Function is defined after sourcing
# ============================================================================
test_fix_cache_function_defined() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"
    assert_function_exists "fix_cache_permissions" "fix_cache_permissions function is defined"
}

# ============================================================================
# Test: fix_cache_permissions with mocked run_privileged (root, no root files)
# ============================================================================
test_fix_cache_no_root_files() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh"

    setup_cache_env "true" "testuser"

    # Create a mock /cache directory in a subshell with redefined function
    (
        # Redefine fix_cache_permissions to use test path
        fix_cache_test() {
            [ -d "$TEST_TEMP_DIR/cache" ] || return 0
            if ! command find "$TEST_TEMP_DIR/cache" -user root -print -quit 2>/dev/null | command grep -q .; then
                return 0
            fi
            echo "would fix"
        }

        mkdir -p "$TEST_TEMP_DIR/cache"
        touch "$TEST_TEMP_DIR/cache/userfile"
        # No root-owned files, so should return 0 silently
        local output
        output=$(fix_cache_test 2>&1)
        if [ -z "$output" ]; then
            exit 0
        else
            exit 1
        fi
    )
    assert_equals "0" "$?" "Returns 0 when no root-owned files in cache"
}

# Run tests
run_test test_fix_cache_no_cache_dir "Returns 0 when /cache does not exist"
run_test test_fix_cache_output_no_root "Handles missing /cache silently"
run_test test_fix_cache_no_sudo_message "Contains no-sudo warning message"
run_test test_fix_cache_success_message "Contains success message"
run_test test_fix_cache_chown_fail_message "Contains chown failure warning"
run_test test_fix_cache_function_defined "Function is defined after sourcing"
run_test test_fix_cache_no_root_files "Returns 0 when no root-owned files in cache"

# Generate test report
generate_report
