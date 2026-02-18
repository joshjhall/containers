#!/usr/bin/env bash
# Unit tests for lib/runtime/secrets/50-load-secrets.sh
# Tests the startup script that triggers secret loading

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "50-load-secrets Startup Script Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/secrets/50-load-secrets.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-50-load-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset SECRET_LOADER_ENABLED SECRET_LOADER_FAIL_ON_ERROR TEST_TEMP_DIR 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" "Script uses strict mode"
}

test_checks_secret_loader_enabled() {
    assert_file_contains "$SOURCE_FILE" 'SECRET_LOADER_ENABLED' \
        "Script checks SECRET_LOADER_ENABLED variable"
}

test_sources_load_secrets() {
    assert_file_contains "$SOURCE_FILE" 'load-secrets.sh' \
        "Script sources the load-secrets.sh file"
}

test_calls_load_all_secrets() {
    assert_file_contains "$SOURCE_FILE" 'load_all_secrets' \
        "Script calls load_all_secrets function"
}

test_checks_fail_on_error() {
    assert_file_contains "$SOURCE_FILE" 'SECRET_LOADER_FAIL_ON_ERROR' \
        "Script checks FAIL_ON_ERROR setting"
}

test_handles_missing_script() {
    assert_file_contains "$SOURCE_FILE" 'not found' \
        "Script handles missing load-secrets.sh"
}

test_continues_on_failure_by_default() {
    assert_file_contains "$SOURCE_FILE" 'Continuing container startup despite' \
        "Script continues on failure when FAIL_ON_ERROR is false"
}

test_script_path_is_correct() {
    assert_file_contains "$SOURCE_FILE" '/opt/container-runtime/secrets/load-secrets.sh' \
        "Script references correct path for loader"
}

# ============================================================================
# Run all tests
# ============================================================================

run_test_with_setup test_strict_mode "Script uses strict mode"
run_test_with_setup test_checks_secret_loader_enabled "Checks SECRET_LOADER_ENABLED"
run_test_with_setup test_sources_load_secrets "Sources load-secrets.sh"
run_test_with_setup test_calls_load_all_secrets "Calls load_all_secrets"
run_test_with_setup test_checks_fail_on_error "Checks FAIL_ON_ERROR"
run_test_with_setup test_handles_missing_script "Handles missing script"
run_test_with_setup test_continues_on_failure_by_default "Continues on failure by default"
run_test_with_setup test_script_path_is_correct "Script path is correct"

# Generate test report
generate_report
