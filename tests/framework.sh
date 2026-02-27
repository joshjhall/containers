#!/usr/bin/env bash
# Test Framework for Container Build System
# Version: 4.15.2
# Test framework for container build system
#
# Provides comprehensive assertion-based testing for container builds.
# All test framework variables and internal functions use the tf_ prefix
# to avoid namespace collisions with code under test.
#
# Key Features:
# - Comprehensive assertion library (equality, strings, files, etc.)
# - Docker-specific assertions for container testing
# - Automatic setup/teardown for each test
# - Test report generation with pass/fail statistics
# - Color output support (when terminal supports it)
# - Safe implementation (no eval statements)
#
# Dependencies:
# - framework/helpers.sh (loaded automatically)
# - Docker installed and running
# - Bash 4.0+
#
# Usage:
#   source framework.sh
#   init_test_framework
#   test_suite "My Test Suite"
#   run_test my_test_function "test description"
#   generate_report
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -euo pipefail

# Framework version (exported for external use)
# shellcheck disable=SC2034  # Used by external scripts
readonly TEST_FRAMEWORK_VERSION="4.15.2"

# Initialize test directories
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERS_DIR="$(dirname "$TESTS_DIR")"

# Source framework components
source "$TESTS_DIR/framework/helpers.sh"

# Source all assertion modules
source "$TESTS_DIR/framework/assertions/core.sh"
source "$TESTS_DIR/framework/assertions/equality.sh"
source "$TESTS_DIR/framework/assertions/string.sh"
source "$TESTS_DIR/framework/assertions/numeric.sh"
source "$TESTS_DIR/framework/assertions/file.sh"
source "$TESTS_DIR/framework/assertions/state.sh"
source "$TESTS_DIR/framework/assertions/exit_code.sh"
source "$TESTS_DIR/framework/assertions/docker.sh"

# Test framework configuration
# shellcheck disable=SC2034  # Used by test files
PROJECT_ROOT="$CONTAINERS_DIR"
RESULTS_DIR="$TESTS_DIR/results"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Test counters
declare -g TESTS_RUN=0
declare -g TESTS_PASSED=0
declare -g TESTS_FAILED=0
declare -g TESTS_SKIPPED=0

# Central assertion failure handler
tf_fail_assertion() {
    echo -e "${TEST_COLOR_FAIL}FAIL${TEST_COLOR_RESET}"
    while [ $# -gt 0 ]; do
        echo "    $1"
        shift
    done
    # Only increment TESTS_FAILED once per test (not per assertion)
    if [ "$TEST_STATUS" != "failed" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TEST_STATUS="failed"
    return 1
}

# Current test context
declare -g CURRENT_TEST=""
declare -g CURRENT_SUITE=""
declare -g TEST_STATUS=""

# Colors for output - check if terminal supports color
if [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM}" != "dumb" ] && command -v tput >/dev/null 2>&1; then
    readonly TEST_COLOR_PASS='\033[0;32m'
    readonly TEST_COLOR_FAIL='\033[0;31m'
    readonly TEST_COLOR_SKIP='\033[0;33m'
    readonly TEST_COLOR_INFO='\033[0;36m'
    readonly TEST_COLOR_RESET='\033[0m'
else
    # No color support
    readonly TEST_COLOR_PASS=''
    readonly TEST_COLOR_FAIL=''
    readonly TEST_COLOR_SKIP=''
    readonly TEST_COLOR_INFO=''
    readonly TEST_COLOR_RESET=''
fi

# Initialize test framework
init_test_framework() {
    # Reset test counters for this test run
    TESTS_RUN=0
    TESTS_PASSED=0
    TESTS_FAILED=0
    TESTS_SKIPPED=0
    TEST_STATUS=""

    # Create directories
    mkdir -p "$RESULTS_DIR"
    mkdir -p "$FIXTURES_DIR"

    # Set up test environment
    export TEST_MODE=1
    export LOG_LEVEL="${LOG_LEVEL:-1}"  # WARN level by default in tests

    # Timestamp for this test run
    export TEST_RUN_ID
    TEST_RUN_ID=$(date +%Y%m%d-%H%M%S)

    # Check Docker is available (skip if SKIP_DOCKER_CHECK is set)
    if [ "${SKIP_DOCKER_CHECK:-false}" != "true" ]; then
        if ! command -v docker >/dev/null 2>&1; then
            echo -e "${TEST_COLOR_FAIL}ERROR: Docker is not installed or not in PATH${TEST_COLOR_RESET}"
            exit 1
        fi

        if ! docker info >/dev/null 2>&1; then
            echo -e "${TEST_COLOR_FAIL}ERROR: Docker daemon is not running${TEST_COLOR_RESET}"
            exit 1
        fi
    else
        echo -e "${TEST_COLOR_INFO}Skipping Docker check (SKIP_DOCKER_CHECK is set)${TEST_COLOR_RESET}"
    fi

    echo -e "${TEST_COLOR_INFO}=== Test Framework Initialized ===${TEST_COLOR_RESET}"
    echo "Test run ID: $TEST_RUN_ID"
    echo "Results dir: $RESULTS_DIR"
    echo
}

# Define a test suite
test_suite() {
    local suite_name="$1"
    # shellcheck disable=SC2034  # Set for test consumption
    CURRENT_SUITE="$suite_name"

    echo -e "${TEST_COLOR_INFO}=== Test Suite: $suite_name ===${TEST_COLOR_RESET}"
}

# Define a test
test_case() {
    local test_name="$1"
    # shellcheck disable=SC2034  # Set for test consumption
    CURRENT_TEST="$test_name"
    TESTS_RUN=$((TESTS_RUN + 1))

    echo -n "  $test_name ... "
}

# Pass current test
pass_test() {
    echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
    # Only increment TESTS_PASSED once per test (not per assertion)
    if [ "$TEST_STATUS" != "passed" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
    TEST_STATUS="passed"
}

# Fail current test
fail_test() {
    local reason="$1"
    echo -e "${TEST_COLOR_FAIL}FAIL${TEST_COLOR_RESET}"
    echo "    $reason"
    # Only increment TESTS_FAILED once per test (not per assertion)
    if [ "$TEST_STATUS" != "failed" ]; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TEST_STATUS="failed"
}

# Skip current test
skip_test() {
    local reason="$1"
    echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
    echo "    $reason"
    # Only increment TESTS_SKIPPED once per test
    if [ "$TEST_STATUS" != "skipped" ]; then
        TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    fi
    TEST_STATUS="skipped"
}

# Setup function (run before each test)
setup() {
    # Create temp directory for test
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(mktemp -d -t "container-test-XXXXXX")

    # Track Docker resources created during test
    export TEST_IMAGES=()
    export TEST_CONTAINERS=()
}

# Teardown function (run after each test)
teardown() {
    # Clean up Docker resources
    if [ -n "${TEST_CONTAINERS+x}" ] && [ ${#TEST_CONTAINERS[@]} -gt 0 ]; then
        docker rm -f "${TEST_CONTAINERS[@]}" >/dev/null 2>&1 || true
    fi

    if [ -n "${TEST_IMAGES+x}" ] && [ ${#TEST_IMAGES[@]} -gt 0 ]; then
        docker rmi -f "${TEST_IMAGES[@]}" >/dev/null 2>&1 || true
    fi

    # Clean up temp directory
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi

    # Reset environment
    unset TEST_TEMP_DIR TEST_IMAGES TEST_CONTAINERS
}

# Run a test with setup/teardown
run_test() {
    local test_func="$1"
    local test_desc="${2:-$test_func}"

    # Reset test status and output (prevent accumulation)
    TEST_STATUS=""
    # shellcheck disable=SC2034  # Set by helpers.sh, read by assertions
    TEST_OUTPUT=""
    # shellcheck disable=SC2034  # Set by helpers.sh, read by assertions
    TEST_EXIT_CODE=0

    # Show test description
    test_case "$test_desc"

    # Run setup
    setup

    # Run the test
    if $test_func; then
        # Only mark as passed if not already marked as skipped or failed
        if [ "$TEST_STATUS" != "skipped" ] && [ "$TEST_STATUS" != "failed" ]; then
            pass_test
        fi
    fi

    # Run teardown
    teardown
}

# Start a test (compatibility function for inline test descriptions)
# Usage: start_test "Description of what this test does"
start_test() {
    local description="$1"
    # This is a no-op for inline descriptions within test functions
    # The actual test tracking is done by run_test
    :
}

# Assert command succeeded (compatibility function)
# Usage: assert_success "Description of what should succeed"
assert_success() {
    local description="${1:-Command should succeed}"
    # This is effectively a no-op since test functions that reach this
    # point without exiting have succeeded
    :
}

# Assert command exists (check if command is available in PATH or as function)
# Usage: assert_command_exists "command_name" "Description"
assert_command_exists() {
    local cmd="$1"
    local description="${2:-Command $cmd should exist}"

    if command -v "$cmd" >/dev/null 2>&1; then
        # Command exists (in PATH or as function/alias/builtin)
        return 0
    else
        # Command doesn't exist - fail the assertion
        tf_fail_assertion "$description (command '$cmd' not found)"
        return 1
    fi
}

# Assert file is executable (compatibility alias for assert_executable)
# Usage: assert_file_executable "file_path" "Description"
assert_file_executable() {
    assert_executable "$@"
}

# Run multiple tests with a suite name (convenience function)
# Usage: run_tests "Suite Name" test_func1 test_func2 test_func3
run_tests() {
    local suite_name="$1"
    shift

    # Initialize framework if not already initialized
    # Check TEST_RUN_ID instead of TESTS_RUN since RUN_ID is only set in init
    if [ -z "${TEST_RUN_ID:-}" ]; then
        init_test_framework
    fi

    # Set the test suite
    test_suite "$suite_name"

    # Run each test function
    for test_func in "$@"; do
        run_test "$test_func" "$test_func"
    done

    # Generate report
    generate_report
}

# Generate test report
generate_report() {
    local report_file="$RESULTS_DIR/test-report-$TEST_RUN_ID.txt"

    {
        echo "Test Report"
        echo "==========="
        echo "Date: $(date)"
        echo "Test Run ID: $TEST_RUN_ID"
        echo
        echo "Summary:"
        echo "  Total Tests: $TESTS_RUN"
        echo "  Passed:      $TESTS_PASSED"
        echo "  Failed:      $TESTS_FAILED"
        echo "  Skipped:     $TESTS_SKIPPED"
        echo

        local pass_rate=0
        if [ $TESTS_RUN -gt 0 ]; then
            pass_rate=$((TESTS_PASSED * 100 / TESTS_RUN))
        fi
        echo "  Pass Rate:   ${pass_rate}%"

    } | tee "$report_file"

    echo
    echo "Report saved to: $report_file"

    # Return non-zero if any tests failed
    [ $TESTS_FAILED -eq 0 ]
}

# Export framework core functions
export -f test_suite test_case
export -f tf_fail_assertion
export -f pass_test fail_test skip_test
export -f setup teardown run_test run_tests
export -f start_test assert_success assert_command_exists assert_file_executable
export -f init_test_framework generate_report
