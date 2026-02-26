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

# Test: Functions are exported
test_functions_exported() {
    # Check if the script exports the required functions
    if grep -q "export -f retry_with_backoff" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "retry_with_backoff function is exported"
    else
        assert_true false "retry_with_backoff function not exported"
    fi

    if grep -q "export -f retry_command" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "retry_command function is exported"
    else
        assert_true false "retry_command function not exported"
    fi

    if grep -q "export -f retry_github_api" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "retry_github_api function is exported"
    else
        assert_true false "retry_github_api function not exported"
    fi
}

# Test: retry_with_backoff function exists
test_retry_with_backoff_function() {
    # Check that retry_with_backoff function is defined
    if grep -q "^retry_with_backoff()" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "retry_with_backoff function is defined"
    else
        assert_true false "retry_with_backoff function not found"
    fi

    # Check for exponential backoff logic
    if grep -q "delay=\$((delay \* 2))" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "Exponential backoff logic is present"
    else
        assert_true false "Exponential backoff logic not found"
    fi
}

# Test: retry_command function exists
test_retry_command_function() {
    # Check that retry_command function is defined
    if grep -q "^retry_command()" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "retry_command function is defined"
    else
        assert_true false "retry_command function not found"
    fi

    # Check for logging integration
    if grep -q "log_message" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "Logging integration is present"
    else
        assert_true false "Logging integration not found"
    fi
}

# Test: retry_github_api function exists
test_retry_github_api_function() {
    # Check that retry_github_api function is defined
    if grep -q "^retry_github_api()" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "retry_github_api function is defined"
    else
        assert_true false "retry_github_api function not found"
    fi

    # Check for GitHub token support
    if grep -q "GITHUB_TOKEN" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "GitHub token support is present"
    else
        assert_true false "GitHub token support not found"
    fi

    # Check for rate limit detection
    if grep -q "rate limit" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "Rate limit detection is present"
    else
        assert_true false "Rate limit detection not found"
    fi
}

# Test: Configuration variables
test_configuration_variables() {
    # Check for RETRY_MAX_ATTEMPTS
    if grep -q "RETRY_MAX_ATTEMPTS" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "RETRY_MAX_ATTEMPTS configuration is present"
    else
        assert_true false "RETRY_MAX_ATTEMPTS configuration not found"
    fi

    # Check for RETRY_INITIAL_DELAY
    if grep -q "RETRY_INITIAL_DELAY" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "RETRY_INITIAL_DELAY configuration is present"
    else
        assert_true false "RETRY_INITIAL_DELAY configuration not found"
    fi

    # Check for RETRY_MAX_DELAY
    if grep -q "RETRY_MAX_DELAY" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "RETRY_MAX_DELAY configuration is present"
    else
        assert_true false "RETRY_MAX_DELAY configuration not found"
    fi
}

# Test: Shellcheck compliance
test_shellcheck_compliance() {
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck "$PROJECT_ROOT/lib/base/retry-utils.sh" 2>&1 | grep -qE "SC[0-9]+ \((error|warning)\)"; then
            assert_true false "Shellcheck found errors or warnings"
        else
            assert_true true "No shellcheck errors or warnings"
        fi
    else
        skip_test "shellcheck not installed"
    fi
}

# Test: Error handling with set -euo pipefail
test_error_handling() {
    # Check if set -euo pipefail is present
    if grep -q "set -euo pipefail" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "Error handling with set -euo pipefail is present"
    else
        assert_true false "set -euo pipefail not found"
    fi
}

# Test: Documentation comments
test_documentation() {
    # Check for function documentation
    local doc_count
    doc_count=$(grep -c "# ============================================================================" "$PROJECT_ROOT/lib/base/retry-utils.sh" || echo "0")

    if [ "$doc_count" -ge 3 ]; then
        assert_true true "Function documentation is present (found $doc_count sections)"
    else
        assert_true false "Insufficient function documentation"
    fi
}

# Test: Logging.sh source check
test_logging_source() {
    # Check for conditional logging.sh source
    if grep -q "source /tmp/build-scripts/base/logging.sh" "$PROJECT_ROOT/lib/base/retry-utils.sh"; then
        assert_true true "Logging.sh source is present"
    else
        assert_true false "Logging.sh source not found"
    fi
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

# Run all tests
run_test test_script_exists "Script exists"
run_test test_functions_exported "Functions are exported"
run_test test_retry_with_backoff_function "retry_with_backoff function"
run_test test_retry_command_function "retry_command function"
run_test test_retry_github_api_function "retry_github_api function"
run_test test_configuration_variables "Configuration variables"
run_test test_shellcheck_compliance "Shellcheck compliance"
run_test test_error_handling "Error handling"
run_test test_documentation "Documentation comments"
run_test test_logging_source "Logging.sh source check"

# Functional tests
run_test_with_setup test_retry_with_backoff_succeeds_immediately "retry_with_backoff succeeds immediately"
run_test_with_setup test_retry_with_backoff_fails_then_succeeds "retry_with_backoff fails then succeeds"
run_test_with_setup test_retry_with_backoff_all_attempts_fail "retry_with_backoff all attempts fail"
run_test_with_setup test_retry_with_backoff_exit_code_propagation "retry_with_backoff exit code propagation"

# Generate test report
generate_report
