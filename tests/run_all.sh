#!/usr/bin/env bash
# Master Test Runner for Container Build System
#
# Runs all test suites for the container build system

set -euo pipefail

# Get test directory
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERS_DIR="$(dirname "$TESTS_DIR")"

# Colors for output
readonly COLOR_HEADER='\033[1;36m'
readonly COLOR_SUCCESS='\033[0;32m'
readonly COLOR_ERROR='\033[0;31m'
readonly COLOR_RESET='\033[0m'

# Track overall results
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

# Header
echo -e "${COLOR_HEADER}=== Container Build System Test Suite ===${COLOR_RESET}"
echo "Test directory: $TESTS_DIR"
echo "Container directory: $CONTAINERS_DIR"
echo

# Function to run a test suite
run_test_suite() {
    local suite_file="$1"
    local suite_name="$2"

    TOTAL_SUITES=$((TOTAL_SUITES + 1))

    echo -e "${COLOR_HEADER}Running: $suite_name${COLOR_RESET}"
    echo "----------------------------------------"

    if bash "$suite_file"; then
        PASSED_SUITES=$((PASSED_SUITES + 1))
        echo -e "${COLOR_SUCCESS}✓ $suite_name completed successfully${COLOR_RESET}"
    else
        FAILED_SUITES=$((FAILED_SUITES + 1))
        echo -e "${COLOR_ERROR}✗ $suite_name failed${COLOR_RESET}"
    fi

    echo
}

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."

    # Check for Docker
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${COLOR_ERROR}Docker is not installed or not in PATH${COLOR_RESET}"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_ERROR}Docker daemon is not running${COLOR_RESET}"
        exit 1
    fi

    # Check if Dockerfile exists
    if [ ! -f "$CONTAINERS_DIR/Dockerfile" ]; then
        echo -e "${COLOR_ERROR}Dockerfile not found at: $CONTAINERS_DIR/Dockerfile${COLOR_RESET}"
        exit 1
    fi

    echo "Prerequisites check passed"
    echo
}

# Find and run all test files
run_all_tests() {
    # Unit tests
    if [ -d "$TESTS_DIR/unit" ]; then
        echo -e "${COLOR_HEADER}=== Unit Tests ===${COLOR_RESET}"
        while IFS= read -r test_file; do
            if [ -f "$test_file" ]; then
                test_name=$(basename "$test_file" .sh)
                run_test_suite "$test_file" "Unit: $test_name"
            fi
        done < <(find "$TESTS_DIR/unit" -name "test_*.sh" -o -name "*_test.sh" | sort)
    fi

    # Integration tests
    if [ -d "$TESTS_DIR/integration" ]; then
        echo -e "${COLOR_HEADER}=== Integration Tests ===${COLOR_RESET}"
        while IFS= read -r test_file; do
            if [ -f "$test_file" ]; then
                test_name=$(basename "$test_file" .sh)
                run_test_suite "$test_file" "Integration: $test_name"
            fi
        done < <(find "$TESTS_DIR/integration" -name "test_*.sh" -o -name "*_test.sh" | sort)
    fi

    # Performance tests (optional)
    if [ -d "$TESTS_DIR/performance" ] && [ "${RUN_PERFORMANCE_TESTS:-false}" = "true" ]; then
        echo -e "${COLOR_HEADER}=== Performance Tests ===${COLOR_RESET}"
        while IFS= read -r test_file; do
            if [ -f "$test_file" ]; then
                test_name=$(basename "$test_file" .sh)
                run_test_suite "$test_file" "Performance: $test_name"
            fi
        done < <(find "$TESTS_DIR/performance" -name "test_*.sh" -o -name "*_test.sh" | sort)
    fi
}

# Main execution
main() {
    # Check prerequisites
    check_prerequisites

    # Create results directory
    mkdir -p "$TESTS_DIR/results"

    # Run all tests
    run_all_tests

    # Summary
    echo -e "${COLOR_HEADER}=== Test Summary ===${COLOR_RESET}"
    echo "Total test suites: $TOTAL_SUITES"
    echo -e "Passed: ${COLOR_SUCCESS}$PASSED_SUITES${COLOR_RESET}"
    echo -e "Failed: ${COLOR_ERROR}$FAILED_SUITES${COLOR_RESET}"

    if [ $FAILED_SUITES -eq 0 ]; then
        echo
        echo -e "${COLOR_SUCCESS}All test suites passed!${COLOR_RESET}"
        exit 0
    else
        echo
        echo -e "${COLOR_ERROR}Some test suites failed${COLOR_RESET}"
        exit 1
    fi
}

# Run with timing
time main "$@"