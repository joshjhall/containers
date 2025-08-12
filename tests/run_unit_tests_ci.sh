#!/usr/bin/env bash
# CI-specific test runner that runs without Docker
# This is used by GitLab CI to run tests in a simpler environment

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

# Change to project root
cd "$PROJECT_ROOT"

echo -e "${BLUE}Container Build System - CI Unit Test Runner${NC}"
echo "============================================="
echo "Date: $(date)"
echo "Project Root: $PROJECT_ROOT"
echo ""

# Create results directory
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Timestamp for this run
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Summary file
SUMMARY_FILE="$RESULTS_DIR/unit-test-summary-$TIMESTAMP.txt"

# JUnit XML file for GitLab
JUNIT_FILE="$RESULTS_DIR/junit.xml"

# Start JUnit XML
cat > "$JUNIT_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="Container Build System Tests" time="0">
EOF

# Function to run a test file
run_test_file() {
    local test_file="$1"
    local test_name=$(basename "$test_file" .sh)
    
    echo -n "  Running $test_name..."
    
    # Create a temporary file for output
    local output_file="$RESULTS_DIR/${test_name}-output.txt"
    
    # Run the test and capture output
    if bash "$test_file" > "$output_file" 2>&1; then
        echo -e " ${GREEN}✓${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        
        # Add success to JUnit
        cat >> "$JUNIT_FILE" <<EOF
  <testcase classname="unit.${test_name}" name="${test_name}" time="0">
  </testcase>
EOF
    else
        echo -e " ${RED}✗${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        
        # Get failure details
        local failure_msg=$(tail -20 "$output_file" | sed 's/&/&amp;/g; s/</&lt;/g; s/>/&gt;/g')
        
        # Add failure to JUnit
        cat >> "$JUNIT_FILE" <<EOF
  <testcase classname="unit.${test_name}" name="${test_name}" time="0">
    <failure message="Test failed">
${failure_msg}
    </failure>
  </testcase>
EOF
        
        # Show last few lines of output for debugging
        echo "    Last 5 lines of output:"
        tail -5 "$output_file" | sed 's/^/      /'
    fi
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

# Start test suite in JUnit
cat >> "$JUNIT_FILE" <<EOF
<testsuite name="Unit Tests" tests="0" failures="0" skipped="0">
EOF

# Run tests in each category
echo -e "${BLUE}Running base tests...${NC}"
if [ -d "$SCRIPT_DIR/unit/base" ]; then
    for test_file in "$SCRIPT_DIR"/unit/base/*.sh; do
        if [ -f "$test_file" ] && [ -x "$test_file" ]; then
            run_test_file "$test_file"
        fi
    done
fi

echo -e "${BLUE}Running feature tests...${NC}"
if [ -d "$SCRIPT_DIR/unit/features" ]; then
    for test_file in "$SCRIPT_DIR"/unit/features/*.sh; do
        if [ -f "$test_file" ] && [ -x "$test_file" ]; then
            run_test_file "$test_file"
        fi
    done
fi

echo -e "${BLUE}Running runtime tests...${NC}"
if [ -d "$SCRIPT_DIR/unit/runtime" ]; then
    for test_file in "$SCRIPT_DIR"/unit/runtime/*.sh; do
        if [ -f "$test_file" ] && [ -x "$test_file" ]; then
            run_test_file "$test_file"
        fi
    done
fi

echo -e "${BLUE}Running bin tests...${NC}"
if [ -d "$SCRIPT_DIR/unit/bin" ]; then
    for test_file in "$SCRIPT_DIR"/unit/bin/*.sh; do
        if [ -f "$test_file" ] && [ -x "$test_file" ]; then
            run_test_file "$test_file"
        fi
    done
fi

# Close test suite in JUnit
cat >> "$JUNIT_FILE" <<EOF
</testsuite>
</testsuites>
EOF

# Calculate pass rate
if [ $TOTAL_TESTS -gt 0 ]; then
    PASS_RATE=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
else
    PASS_RATE=0
fi

# Generate summary
{
    echo "Container Build System - CI Unit Test Summary"
    echo "=============================================="
    echo "Date: $(date)"
    echo "Project Root: $PROJECT_ROOT"
    echo ""
    echo "Test Results:"
    echo "  Total Tests: $TOTAL_TESTS"
    echo "  Passed: $PASSED_TESTS"
    echo "  Failed: $FAILED_TESTS"
    echo "  Skipped: $SKIPPED_TESTS"
    echo "  Pass Rate: ${PASS_RATE}%"
    echo ""
} | tee "$SUMMARY_FILE"

# Update JUnit with totals
sed -i.bak "s/<testsuite name=\"Unit Tests\" tests=\"0\" failures=\"0\"/<testsuite name=\"Unit Tests\" tests=\"$TOTAL_TESTS\" failures=\"$FAILED_TESTS\"/" "$JUNIT_FILE" && rm "$JUNIT_FILE.bak"

# Exit with appropriate code
if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "${RED}Tests failed! $FAILED_TESTS test(s) did not pass.${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed successfully!${NC}"
    exit 0
fi