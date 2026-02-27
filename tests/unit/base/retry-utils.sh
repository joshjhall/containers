#!/bin/bash
# Unit tests for retry-utils.sh functionality
set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Retry Utilities Tests"

# Source file under test
RETRY_SOURCE_FILE="$PROJECT_ROOT/lib/base/retry-utils.sh"

# Helper: run a subshell that sources retry-utils.sh with stubbed dependencies
# Stubs log_message, log_error, and sleep to avoid real delays / missing deps.
_run_retry_subshell() {
    bash -c "
        # Stub logging and sleep
        log_message() { :; }
        log_error() { :; }
        sleep() { :; }
        export -f log_message log_error sleep
        source '$RETRY_SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# Setup function - runs before each functional test
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-retry-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each functional test
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Test: Script exists
test_script_exists() {
    assert_file_exists "$PROJECT_ROOT/lib/base/retry-utils.sh"
}

# ============================================================================
# Functional Tests - sourcing and configuration
# ============================================================================

test_functions_available_after_source() {
    # Source file in subshell, check all 3 functions exist via declare -f
    local output
    output=$(_run_retry_subshell "
        declare -f retry_with_backoff >/dev/null && echo 'retry_with_backoff:ok'
        declare -f retry_command >/dev/null && echo 'retry_command:ok'
        declare -f retry_github_api >/dev/null && echo 'retry_github_api:ok'
    ")

    assert_contains "$output" "retry_with_backoff:ok" "retry_with_backoff is available after source"
    assert_contains "$output" "retry_command:ok" "retry_command is available after source"
    assert_contains "$output" "retry_github_api:ok" "retry_github_api is available after source"
}

test_configuration_defaults() {
    # Source file, check default values of config variables
    local output
    output=$(_run_retry_subshell "
        echo \"max=\$RETRY_MAX_ATTEMPTS\"
        echo \"delay=\$RETRY_INITIAL_DELAY\"
        echo \"maxdelay=\$RETRY_MAX_DELAY\"
    ")

    assert_contains "$output" "max=3" "RETRY_MAX_ATTEMPTS defaults to 3"
    assert_contains "$output" "delay=2" "RETRY_INITIAL_DELAY defaults to 2"
    assert_contains "$output" "maxdelay=30" "RETRY_MAX_DELAY defaults to 30"
}

test_include_guard_prevents_double_source() {
    # Source twice, verify no error (the _RETRY_UTILS_LOADED guard)
    local exit_code=0
    _run_retry_subshell "
        source '$RETRY_SOURCE_FILE' >/dev/null 2>&1
        echo 'second source ok'
    " || exit_code=$?

    assert_equals "0" "$exit_code" "Double-sourcing does not error"
}

# ============================================================================
# Functional Tests - retry_command()
# ============================================================================

test_retry_command_succeeds() {
    local exit_code=0
    _run_retry_subshell "
        retry_command 'test op' true
    " || exit_code=$?

    assert_equals "0" "$exit_code" "retry_command returns 0 when command succeeds"
}

test_retry_command_fails() {
    local exit_code=0
    _run_retry_subshell "
        export RETRY_MAX_ATTEMPTS=1
        retry_command 'test op' false
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" "retry_command returns non-zero when command fails"
}

# ============================================================================
# Functional Tests - retry_github_api()
# ============================================================================

test_retry_github_api_succeeds() {
    # Mock curl that echoes JSON
    local exit_code=0
    local output
    output=$(_run_retry_subshell "
        curl() { echo '{\"tag_name\":\"v1.0\"}'; return 0; }
        export -f curl
        retry_github_api curl https://api.github.com/repos/test/test/releases/latest
    ") || exit_code=$?

    assert_equals "0" "$exit_code" "retry_github_api returns 0 on success"
    assert_contains "$output" "v1.0" "retry_github_api outputs curl response"
}

test_retry_github_api_uses_token() {
    # Set GITHUB_TOKEN, mock curl that checks for auth header
    local exit_code=0
    local output
    output=$(_run_retry_subshell "
        export GITHUB_TOKEN=test-token-123
        curl() {
            for arg in \"\$@\"; do
                if [[ \"\$arg\" == *'token test-token-123'* ]]; then
                    echo 'auth_header_found'
                    return 0
                fi
            done
            echo 'no_auth_header'
            return 0
        }
        export -f curl
        retry_github_api curl https://api.github.com/repos/test/test
    ") || exit_code=$?

    assert_equals "0" "$exit_code" "retry_github_api returns 0"
    assert_contains "$output" "auth_header_found" "retry_github_api passes GITHUB_TOKEN as auth header"
}

# ============================================================================
# Functional Tests - retry_with_backoff()
# ============================================================================

test_retry_with_backoff_succeeds_immediately() {
    # Command exits 0 on first try — should return 0
    local exit_code=0
    _run_retry_subshell "
        export RETRY_MAX_ATTEMPTS=3
        retry_with_backoff true
    " || exit_code=$?

    assert_equals "0" "$exit_code" "retry_with_backoff returns 0 when command succeeds immediately"
}

test_retry_with_backoff_fails_then_succeeds() {
    # Use a counter file: fail on first call, succeed on second
    local exit_code=0
    _run_retry_subshell "
        export RETRY_MAX_ATTEMPTS=3
        COUNTER_FILE='$TEST_TEMP_DIR/attempt_counter'
        echo '0' > \"\$COUNTER_FILE\"
        my_cmd() {
            local n
            n=\$(cat \"\$COUNTER_FILE\")
            n=\$((n + 1))
            echo \"\$n\" > \"\$COUNTER_FILE\"
            [ \"\$n\" -ge 2 ] && return 0 || return 1
        }
        export -f my_cmd
        retry_with_backoff my_cmd
    " || exit_code=$?

    assert_equals "0" "$exit_code" "retry_with_backoff returns 0 when command fails then succeeds"
}

test_retry_with_backoff_all_attempts_fail() {
    # Always-failing command with max 2 attempts — should return non-zero
    local exit_code=0
    _run_retry_subshell "
        export RETRY_MAX_ATTEMPTS=2
        retry_with_backoff false
    " || exit_code=$?

    assert_not_equals "0" "$exit_code" "retry_with_backoff returns non-zero when all attempts fail"
}

test_retry_with_backoff_exit_code_propagation() {
    # Failing command exits 42 — should propagate that exit code
    local exit_code=0
    _run_retry_subshell "
        export RETRY_MAX_ATTEMPTS=1
        fail42() { return 42; }
        export -f fail42
        retry_with_backoff fail42
    " || exit_code=$?

    assert_equals "42" "$exit_code" "retry_with_backoff propagates the original exit code"
}

test_retry_respects_max_attempts() {
    # Counter file tracks attempts, set max=3, fail all — verify exactly 3 attempts
    local exit_code=0
    _run_retry_subshell "
        export RETRY_MAX_ATTEMPTS=3
        COUNTER_FILE='$TEST_TEMP_DIR/attempt_count'
        echo '0' > \"\$COUNTER_FILE\"
        count_and_fail() {
            local n
            n=\$(cat \"\$COUNTER_FILE\")
            n=\$((n + 1))
            echo \"\$n\" > \"\$COUNTER_FILE\"
            return 1
        }
        export -f count_and_fail
        retry_with_backoff count_and_fail
    " || exit_code=$?

    local attempts
    attempts=$(cat "$TEST_TEMP_DIR/attempt_count")
    assert_equals "3" "$attempts" "retry_with_backoff makes exactly RETRY_MAX_ATTEMPTS attempts"
}

# Run all tests
run_test test_script_exists "Script exists"

# Functional tests - sourcing and configuration
run_test_with_setup test_functions_available_after_source "Functions available after source"
run_test_with_setup test_configuration_defaults "Configuration defaults"
run_test_with_setup test_include_guard_prevents_double_source "Include guard prevents double source"

# Functional tests - retry_command
run_test_with_setup test_retry_command_succeeds "retry_command succeeds"
run_test_with_setup test_retry_command_fails "retry_command fails"

# Functional tests - retry_github_api
run_test_with_setup test_retry_github_api_succeeds "retry_github_api succeeds"
run_test_with_setup test_retry_github_api_uses_token "retry_github_api uses GITHUB_TOKEN"

# Functional tests - retry_with_backoff
run_test_with_setup test_retry_with_backoff_succeeds_immediately "retry_with_backoff succeeds immediately"
run_test_with_setup test_retry_with_backoff_fails_then_succeeds "retry_with_backoff fails then succeeds"
run_test_with_setup test_retry_with_backoff_all_attempts_fail "retry_with_backoff all attempts fail"
run_test_with_setup test_retry_with_backoff_exit_code_propagation "retry_with_backoff exit code propagation"
run_test_with_setup test_retry_respects_max_attempts "retry_with_backoff respects max attempts"

# Generate test report
generate_report
