#!/usr/bin/env bash
# Comprehensive Unit Test Runner
# Runs all unit tests and generates combined reports

set -euo pipefail

# Get script directory
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TESTS_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test statistics
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
FAILED_SUITES=()

echo -e "${BLUE}=== Container Build System Unit Tests ===${NC}"
echo "Project Root: $PROJECT_ROOT"
echo "Tests Directory: $TESTS_DIR"
echo ""

# Find all unit test files
echo -e "${BLUE}Discovering unit tests...${NC}"
# Look for all .sh files in unit directory except the runner itself
UNIT_TEST_FILES=$(command find "$TESTS_DIR/unit" -name "*.sh" -type f ! -name "run_*.sh" | sort)

if [ -z "$UNIT_TEST_FILES" ]; then
    echo -e "${YELLOW}No unit test files found in $TESTS_DIR/unit${NC}"
    exit 0
fi

echo "Found unit test files:"
for test_file in $UNIT_TEST_FILES; do
    echo "  - $(basename "$test_file")"
done
echo ""

# Run each test suite
for test_file in $UNIT_TEST_FILES; do
    test_name=$(basename "$test_file" .sh)
    echo -e "${BLUE}Running $test_name...${NC}"

    # Make sure test is executable
    chmod +x "$test_file"

    # Run the test and capture output
    if output=$("$test_file" 2>&1); then
        # Parse test results from output
        suite_passed=$(echo "$output" | command grep -o "Passed:[[:space:]]*[0-9]*" | command grep -o "[0-9]*" || echo "0")
        suite_failed=$(echo "$output" | command grep -o "Failed:[[:space:]]*[0-9]*" | command grep -o "[0-9]*" || echo "0")
        suite_skipped=$(echo "$output" | command grep -o "Skipped:[[:space:]]*[0-9]*" | command grep -o "[0-9]*" || echo "0")
        suite_total=$((suite_passed + suite_failed + suite_skipped))

        # Update totals
        TOTAL_TESTS=$((TOTAL_TESTS + suite_total))
        TOTAL_PASSED=$((TOTAL_PASSED + suite_passed))
        TOTAL_FAILED=$((TOTAL_FAILED + suite_failed))
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + suite_skipped))

        # Report suite results
        if [ "$suite_failed" -eq 0 ]; then
            echo -e "  ${GREEN}✓ PASS${NC} ($suite_passed passed, $suite_skipped skipped)"
        else
            echo -e "  ${RED}✗ FAIL${NC} ($suite_passed passed, $suite_failed failed, $suite_skipped skipped)"
            FAILED_SUITES+=("$test_name")
        fi
    else
        echo -e "  ${RED}✗ ERROR${NC} (Test suite failed to run)"
        echo "  Output: $output"
        FAILED_SUITES+=("$test_name")
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
    echo ""
done

# Generate summary report
echo -e "${BLUE}=== Unit Test Summary ===${NC}"
echo "Date: $(date)"
echo "Project: Container Build System"
echo ""
echo "Test Results:"
echo "  Total Tests: $TOTAL_TESTS"
echo -e "  Passed: ${GREEN}$TOTAL_PASSED${NC}"
if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo -e "  Failed: ${RED}$TOTAL_FAILED${NC}"
else
    echo -e "  Failed: $TOTAL_FAILED"
fi
echo -e "  Skipped: ${YELLOW}$TOTAL_SKIPPED${NC}"

if [ "$TOTAL_TESTS" -gt 0 ]; then
    PASS_RATE=$(( (TOTAL_PASSED * 100) / TOTAL_TESTS ))
    echo "  Pass Rate: $PASS_RATE%"
fi

echo ""

# List failed suites if any
if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo -e "${RED}Failed Test Suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo "  - $suite"
    done
    echo ""
fi

# Generate combined report file
REPORT_FILE="$TESTS_DIR/results/unit-test-summary-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$REPORT_FILE")"

command cat > "$REPORT_FILE" <<EOF
Container Build System - Unit Test Summary
==========================================
Date: $(date)
Project Root: $PROJECT_ROOT

Test Results:
  Total Tests: $TOTAL_TESTS
  Passed: $TOTAL_PASSED
  Failed: $TOTAL_FAILED
  Skipped: $TOTAL_SKIPPED
  Pass Rate: ${PASS_RATE:-0}%

Test Suites:
EOF

for test_file in $UNIT_TEST_FILES; do
    echo "  - $(basename "$test_file")" >> "$REPORT_FILE"
done

if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo "" >> "$REPORT_FILE"
    echo "Failed Suites:" >> "$REPORT_FILE"
    for suite in "${FAILED_SUITES[@]}"; do
        echo "  - $suite" >> "$REPORT_FILE"
    done
fi

echo "Report saved to: $REPORT_FILE"
echo ""

# Exit with appropriate code
if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo -e "${RED}Some tests failed. Check individual test outputs for details.${NC}"
    exit 1
else
    echo -e "${GREEN}All unit tests passed!${NC}"
    exit 0
fi
