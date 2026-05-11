#!/usr/bin/env bash
# Run all integration tests
#
# This script runs the integration test suite which builds and tests
# actual Docker containers with various feature combinations.
#
# Usage:
#   ./tests/run_integration_tests.sh [--tier=<tier>] [test_name]
#
# Tiers (filter tests by their `# @tier: ...` header comment):
#   pr        — fast feedback on every PR (<15min)
#   merge     — representative cluster on main push (<30min, default coverage)
#   weekly    — full matrix on Sunday cadence
#   monthly   — long-tail: image-size regression, abandonment scans
#   quarterly — cross-version dependency drift
#
# A test without an `@tier:` header defaults to the `merge` tier. See
# docs/operations/ci-tiers.md for the full tier definitions.
#
# Examples:
#   ./tests/run_integration_tests.sh                 # All tests
#   ./tests/run_integration_tests.sh --tier=pr       # PR-tier only
#   ./tests/run_integration_tests.sh minimal         # Run only minimal tests
#   ./tests/run_integration_tests.sh python_dev      # Run only python-dev tests

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
# shellcheck source=lib/shared/colors.sh
source "$PROJECT_ROOT/lib/shared/colors.sh"

# Export project root for tests
export PROJECT_ROOT
export CONTAINERS_DIR="$PROJECT_ROOT"

# Check if Docker is available
if ! command -v docker &>/dev/null; then
    echo -e "${RED}Error: Docker is not available${NC}"
    echo "Integration tests require Docker to build and run containers"
    exit 1
fi

# Check if Docker daemon is running
if ! docker info &>/dev/null; then
    echo -e "${RED}Error: Docker daemon is not running${NC}"
    exit 1
fi

echo -e "${BLUE}=== Integration Test Suite ===${NC}"
echo "Project: Container Build System"
echo "Date: $(date)"
echo ""

# Parse arguments: optional --tier=<tier> and optional test_name.
TIER=""
TEST_NAME=""
for arg in "$@"; do
    case "$arg" in
        --tier=*) TIER="${arg#--tier=}" ;;
        -*)
            echo -e "${RED}Error: unknown option: $arg${NC}"
            exit 2
            ;;
        *)
            if [ -n "$TEST_NAME" ]; then
                echo -e "${RED}Error: too many positional arguments${NC}"
                exit 2
            fi
            TEST_NAME="$arg"
            ;;
    esac
done

case "$TIER" in
    "" | pr | merge | weekly | monthly | quarterly) ;;
    *)
        echo -e "${RED}Error: unknown tier: $TIER${NC}"
        echo "Valid tiers: pr, merge, weekly, monthly, quarterly"
        exit 2
        ;;
esac

# Returns 0 if the test file declares membership in $TIER (or if $TIER is
# empty — meaning "no filter"). Reads the first 5 non-shebang lines for an
# `@tier: ...` comment; absence defaults to `merge` (matches the historical
# behavior — every test pre-tier was effectively a merge-tier test).
test_in_tier() {
    local file="$1"
    local want="$2"
    [ -z "$want" ] && return 0

    local declared
    declared=$(/usr/bin/grep -m1 -oE '^#[[:space:]]*@tier:[[:space:]]*[a-z,[:space:]]+' "$file" 2>/dev/null |
        command sed -E 's/^#[[:space:]]*@tier:[[:space:]]*//' || true)
    [ -z "$declared" ] && declared="merge"

    echo "$declared" | command tr ',' '\n' | command tr -d '[:space:]' | command grep -Fxq "$want"
}

# Find all integration test files (then filter by tier if requested).
TEST_FILES=()
if [ -z "$TEST_NAME" ]; then
    while IFS= read -r file; do
        if test_in_tier "$file" "$TIER"; then
            TEST_FILES+=("$file")
        fi
    done < <(command find "$SCRIPT_DIR/integration/builds" -name "test_*.sh" -type f | sort)

    if [ -n "$TIER" ]; then
        echo -e "${BLUE}Filtering by tier: $TIER${NC}"
    fi
else
    TEST_FILE="$SCRIPT_DIR/integration/builds/test_${TEST_NAME}.sh"
    if [ ! -f "$TEST_FILE" ]; then
        echo -e "${RED}Error: Test file not found: $TEST_FILE${NC}"
        exit 1
    fi
    if [ -n "$TIER" ] && ! test_in_tier "$TEST_FILE" "$TIER"; then
        echo -e "${YELLOW}Note: $TEST_NAME is not in tier '$TIER' — running anyway (explicit name overrides filter).${NC}"
    fi
    TEST_FILES=("$TEST_FILE")
fi

if [ ${#TEST_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}No integration tests match tier '$TIER' — nothing to run.${NC}"
    exit 0
fi

echo -e "${BLUE}Found ${#TEST_FILES[@]} integration test suite(s)${NC}"
echo ""

# Run each test
TOTAL_PASSED=0
TOTAL_FAILED=0
FAILED_TESTS=()

for test_file in "${TEST_FILES[@]}"; do
    test_name=$(basename "$test_file" .sh)
    echo -e "${BLUE}Running $test_name...${NC}"

    if bash "$test_file"; then
        echo -e "${GREEN}✓ PASS${NC}"
        TOTAL_PASSED=$((TOTAL_PASSED + 1))
    else
        echo -e "${RED}✗ FAIL${NC}"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
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
