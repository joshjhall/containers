#!/usr/bin/env bash
# Changed-File Test Runner
# Maps changed files to their corresponding unit tests and runs only those.
# Designed for pre-push hooks: fast feedback without running the full suite.
# Does NOT write a report file (avoids "files modified by hook" failures).

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

# ---------------------------------------------------------------------------
# Determine changed files
# ---------------------------------------------------------------------------
get_changed_files() {
    local remote="origin"

    local remote_head
    remote_head=$(git rev-parse --verify "${remote}/HEAD" 2>/dev/null ||
                  git rev-parse --verify "${remote}/main" 2>/dev/null ||
                  git rev-parse --verify "${remote}/master" 2>/dev/null || true)

    if [ -n "$remote_head" ]; then
        git diff --name-only "$remote_head"...HEAD 2>/dev/null || true
    else
        # Fallback: diff against HEAD~1 (at least catch the latest commit)
        git diff --name-only HEAD~1 HEAD 2>/dev/null || true
    fi

    # Also include any uncommitted staged/unstaged changes
    git diff --name-only HEAD 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Map a changed file to its corresponding unit test file(s)
# ---------------------------------------------------------------------------
map_to_test() {
    local file="$1"

    case "$file" in
        # Foundational files — signal to run ALL tests
        tests/framework.sh|tests/framework/*|Dockerfile)
            echo "ALL"
            return
            ;;

        # Test files themselves — run directly
        tests/unit/*.sh)
            if [ -f "${PROJECT_ROOT}/${file}" ]; then
                echo "${PROJECT_ROOT}/${file}"
            fi
            return
            ;;

        # lib/base/foo.sh → tests/unit/base/foo.sh
        lib/base/*.sh)
            local base
            base=$(basename "$file")
            local test_path="${TESTS_DIR}/unit/base/${base}"
            if [ -f "$test_path" ]; then
                echo "$test_path"
            fi
            return
            ;;

        # lib/features/lib/<subdir>/* → tests/unit/features/*<subdir>*.sh
        # Sub-files are helpers for a parent feature; match via the subdirectory name.
        # e.g. lib/features/lib/claude/claude-setup → tests/unit/features/claude-code-setup.sh
        lib/features/lib/*)
            # Extract the subdirectory name (e.g. "claude" from lib/features/lib/claude/foo)
            local subdir
            subdir=$(echo "$file" | sed 's|lib/features/lib/\([^/]*\)/.*|\1|')
            # First try exact basename match
            local base
            base=$(basename "$file")
            base="${base%.*}.sh"
            local test_path="${TESTS_DIR}/unit/features/${base}"
            if [ -f "$test_path" ]; then
                echo "$test_path"
                return
            fi
            # Fall back to glob matching on the subdirectory name
            local match
            for match in "${TESTS_DIR}"/unit/features/*"${subdir}"*.sh; do
                if [ -f "$match" ]; then
                    echo "$match"
                    return
                fi
            done
            return
            ;;

        # lib/features/foo.sh → tests/unit/features/foo.sh
        lib/features/*.sh)
            local base
            base=$(basename "$file")
            local test_path="${TESTS_DIR}/unit/features/${base}"
            if [ -f "$test_path" ]; then
                echo "$test_path"
            fi
            return
            ;;

        # lib/runtime/secrets/foo.sh → tests/unit/runtime/secrets/foo.sh
        lib/runtime/secrets/*.sh)
            local base
            base=$(basename "$file")
            local test_path="${TESTS_DIR}/unit/runtime/secrets/${base}"
            if [ -f "$test_path" ]; then
                echo "$test_path"
            fi
            return
            ;;

        # lib/runtime/commands/foo → tests/unit/runtime/foo.sh (no ext on source)
        lib/runtime/commands/*)
            local base
            base=$(basename "$file")
            local test_path="${TESTS_DIR}/unit/runtime/${base}.sh"
            if [ -f "$test_path" ]; then
                echo "$test_path"
            fi
            return
            ;;

        # lib/runtime/foo.sh → tests/unit/runtime/foo.sh
        lib/runtime/*.sh)
            local base
            base=$(basename "$file")
            local test_path="${TESTS_DIR}/unit/runtime/${base}"
            if [ -f "$test_path" ]; then
                echo "$test_path"
            fi
            return
            ;;

        # bin/foo.sh → tests/unit/bin/foo.sh
        bin/*.sh)
            local base
            base=$(basename "$file")
            local test_path="${TESTS_DIR}/unit/bin/${base}"
            if [ -f "$test_path" ]; then
                echo "$test_path"
            fi
            return
            ;;
    esac

    # No mapping found — no tests to run for this file
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo -e "${BLUE}=== Changed-File Unit Test Runner ===${NC}"
echo "Project Root: $PROJECT_ROOT"
echo ""

# Collect changed files
CHANGED_FILES=$(get_changed_files)

if [ -z "$CHANGED_FILES" ]; then
    echo -e "${GREEN}No changed files detected — nothing to test.${NC}"
    exit 0
fi

echo -e "${BLUE}Changed files:${NC}"
echo "$CHANGED_FILES" | sort -u | while IFS= read -r f; do
    echo "  $f"
done
echo ""

# Map changed files to test files
RUN_ALL=false
declare -A TEST_FILES_MAP  # associative array for deduplication

while IFS= read -r file; do
    [ -z "$file" ] && continue
    result=$(map_to_test "$file")
    [ -z "$result" ] && continue

    if [ "$result" = "ALL" ]; then
        RUN_ALL=true
        break
    fi

    TEST_FILES_MAP["$result"]=1
done < <(echo "$CHANGED_FILES" | sort -u)

# If foundational file changed, fall back to full suite
if [ "$RUN_ALL" = true ]; then
    echo -e "${YELLOW}Foundational file changed — running full unit test suite.${NC}"
    echo ""
    exec "$TESTS_DIR/run_unit_tests.sh"
fi

# Collect deduplicated test files
TEST_FILES=()
for tf in "${!TEST_FILES_MAP[@]}"; do
    TEST_FILES+=("$tf")
done

# Sort for deterministic order
mapfile -t TEST_FILES < <(printf '%s\n' "${TEST_FILES[@]}" | sort)

if [ ${#TEST_FILES[@]} -eq 0 ]; then
    echo -e "${GREEN}No unit tests match the changed files — nothing to run.${NC}"
    exit 0
fi

echo -e "${BLUE}Tests to run (${#TEST_FILES[@]}):${NC}"
for tf in "${TEST_FILES[@]}"; do
    echo "  - $(basename "$tf")"
done
echo ""

# ---------------------------------------------------------------------------
# Run matched tests (same execution logic as run_unit_tests.sh)
# ---------------------------------------------------------------------------
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0
FAILED_SUITES=()

for test_file in "${TEST_FILES[@]}"; do
    test_name=$(basename "$test_file" .sh)
    echo -e "${BLUE}Running $test_name...${NC}"

    chmod +x "$test_file"

    if output=$("$test_file" 2>&1); then
        suite_passed=$(echo "$output" | grep -o "Passed:[[:space:]]*[0-9]*" | grep -o "[0-9]*" || echo "0")
        suite_failed=$(echo "$output" | grep -o "Failed:[[:space:]]*[0-9]*" | grep -o "[0-9]*" || echo "0")
        suite_skipped=$(echo "$output" | grep -o "Skipped:[[:space:]]*[0-9]*" | grep -o "[0-9]*" || echo "0")
        suite_total=$((suite_passed + suite_failed + suite_skipped))

        TOTAL_TESTS=$((TOTAL_TESTS + suite_total))
        TOTAL_PASSED=$((TOTAL_PASSED + suite_passed))
        TOTAL_FAILED=$((TOTAL_FAILED + suite_failed))
        TOTAL_SKIPPED=$((TOTAL_SKIPPED + suite_skipped))

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

# ---------------------------------------------------------------------------
# Summary (no report file written)
# ---------------------------------------------------------------------------
echo -e "${BLUE}=== Changed-File Test Summary ===${NC}"
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

if [ ${#FAILED_SUITES[@]} -gt 0 ]; then
    echo -e "${RED}Failed Test Suites:${NC}"
    for suite in "${FAILED_SUITES[@]}"; do
        echo "  - $suite"
    done
    echo ""
fi

if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo -e "${RED}Some tests failed. Check individual test outputs for details.${NC}"
    exit 1
else
    echo -e "${GREEN}All changed-file tests passed!${NC}"
    exit 0
fi
