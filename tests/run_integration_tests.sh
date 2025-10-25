#!/usr/bin/env bash
# Run all integration tests
#
# This script runs the integration test suite which builds and tests
# actual Docker containers with various feature combinations.
#
# Usage:
#   ./tests/run_integration_tests.sh [test_name]
#
# Examples:
#   ./tests/run_integration_tests.sh                 # Run all integration tests
#   ./tests/run_integration_tests.sh minimal         # Run only minimal tests
#   ./tests/run_integration_tests.sh python_dev      # Run only python-dev tests

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Export project root for tests
export PROJECT_ROOT
export CONTAINERS_DIR="$PROJECT_ROOT"

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not available${NC}"
    echo "Integration tests require Docker to build and run containers"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &> /dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    exit 1
fi

echo -e "${BLUE}=== Integration Test Suite ===${NC}"
echo "Project: Container Build System"
echo "Date: $(date)"
echo ""

# Find all integration test files
TEST_FILES=()
if [ $# -eq 0 ]; then
    # Run all tests
    while IFS= read -r file; do
        TEST_FILES+=("$file")
    done < <(find "$SCRIPT_DIR/integration/builds" -name "test_*.sh" -type f | sort)
else
    # Run specific test
    TEST_NAME="$1"
    TEST_FILE="$SCRIPT_DIR/integration/builds/test_${TEST_NAME}.sh"
    if [ ! -f "$TEST_FILE" ]; then
        echo -e "${RED}Error: Test file not found: $TEST_FILE${NC}"
        exit 1
    fi
    TEST_FILES=("$TEST_FILE")
fi

echo -e "${BLUE}Found ${#TEST_FILES[@]} integration test suite(s)${NC}"
echo ""

# Run each test
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
FAILED_TESTS=()

for test_file in "${TEST_FILES[@]}"; do
    test_name=$(basename "$test_file" .sh)
    echo -e "${BLUE}Running $test_name...${NC}"

    if bash "$test_file"; then
        echo -e "${GREEN}✓ PASS${NC}"
        ((TOTAL_PASSED++))
    else
        echo -e "${RED}✗ FAIL${NC}"
        ((TOTAL_FAILED++))
        FAILED_TESTS+=("$test_name")
    fi
    echo ""
done

# Print summary
echo -e "${BLUE}=== Integration Test Summary ===${NC}"
echo "Date: $(date)"
echo ""
echo "Test Results:"
echo -e "  Total Suites: ${#TEST_FILES[@]}"
echo -e "  Passed: ${GREEN}$TOTAL_PASSED${NC}"
echo -e "  Failed: ${RED}$TOTAL_FAILED${NC}"
echo ""

# List failed tests if any
if [ $TOTAL_FAILED -gt 0 ]; then
    echo -e "${RED}Failed Tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
    echo ""
    exit 1
fi

echo -e "${GREEN}All integration tests passed!${NC}"
exit 0
