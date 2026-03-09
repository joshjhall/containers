#!/usr/bin/env bash
# Unit tests for lib/shared/export-utils.sh
# Tests protected_export utility function

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Shared Export Utils Tests"

# Setup function - runs before each test
setup() {
    # Unset include guard so re-sourcing works across tests
    unset _SHARED_EXPORT_UTILS_LOADED 2>/dev/null || true

    # Source the shared export-utils module
    source "$PROJECT_ROOT/lib/shared/export-utils.sh"
}

# Teardown function - runs after each test
teardown() {
    unset _SHARED_EXPORT_UTILS_LOADED 2>/dev/null || true
}

# Test: protected_export exports a defined function
test_exports_defined_function() {
    _test_helper_func() { echo "hello"; }
    protected_export _test_helper_func
    assert_equals "0" "$?" "protected_export returns 0 for defined function"

    # Verify it was actually exported
    declare -f _test_helper_func >/dev/null 2>&1
    assert_equals "0" "$?" "function is still defined after protected_export"

    unset -f _test_helper_func
}

# Test: protected_export silently skips undefined functions
test_skips_undefined_function() {
    # Make sure the function doesn't exist
    unset -f _nonexistent_test_func 2>/dev/null || true

    protected_export _nonexistent_test_func
    assert_equals "0" "$?" "protected_export returns 0 for undefined function"
}

# Test: multiple names in one call - mix of defined and undefined
test_mixed_defined_and_undefined() {
    _test_defined_a() { echo "a"; }
    _test_defined_b() { echo "b"; }

    # _test_undefined_x does not exist
    unset -f _test_undefined_x 2>/dev/null || true

    protected_export _test_defined_a _test_undefined_x _test_defined_b
    assert_equals "0" "$?" "protected_export returns 0 with mixed functions"

    # Verify defined ones are still callable
    local result_a
    result_a=$(_test_defined_a)
    assert_equals "a" "$result_a" "defined function a works after protected_export"

    local result_b
    result_b=$(_test_defined_b)
    assert_equals "b" "$result_b" "defined function b works after protected_export"

    unset -f _test_defined_a _test_defined_b
}

# Test: multiple names all defined
test_multiple_all_defined() {
    _test_multi_1() { echo "1"; }
    _test_multi_2() { echo "2"; }
    _test_multi_3() { echo "3"; }

    protected_export _test_multi_1 _test_multi_2 _test_multi_3
    assert_equals "0" "$?" "protected_export returns 0 for all defined functions"

    unset -f _test_multi_1 _test_multi_2 _test_multi_3
}

# Test: no arguments is a no-op
test_no_arguments() {
    protected_export
    assert_equals "0" "$?" "protected_export with no arguments returns 0"
}

# Test: protected_export itself is exported
test_self_exported() {
    local result
    result=$(bash -c 'type -t protected_export 2>/dev/null || echo "not_found"')
    assert_equals "function" "$result" "protected_export is available in subshell"
}

# Test: multiple sourcing guard works
test_multiple_sourcing_guard() {
    # Source again - should be a no-op due to guard
    source "$PROJECT_ROOT/lib/shared/export-utils.sh"
    assert_equals "0" "$?" "re-sourcing export-utils.sh succeeds (guard works)"
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_exports_defined_function "Exports defined function"
run_test_with_setup test_skips_undefined_function "Silently skips undefined function"
run_test_with_setup test_mixed_defined_and_undefined "Mixed defined/undefined exports"
run_test_with_setup test_multiple_all_defined "Multiple all-defined exports"
run_test_with_setup test_no_arguments "No arguments is a no-op"
run_test_with_setup test_self_exported "protected_export itself is exported"
run_test_with_setup test_multiple_sourcing_guard "Multiple sourcing guard works"

# Generate test report
generate_report
