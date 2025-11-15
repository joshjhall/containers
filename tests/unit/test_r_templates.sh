#!/usr/bin/env bash
# Unit tests for R template system
#
# This test validates that:
# 1. All R template files exist and are valid
# 2. The load_r_template function works correctly
# 3. Template content is properly loaded

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper
assert_file_exists() {
    local file="$1"
    local desc="$2"

    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $desc - file not found: $file"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local desc="$3"

    if grep -q "$pattern" "$file"; then
        echo -e "${GREEN}✓${NC} $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $desc - pattern not found: $pattern"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

echo -e "${YELLOW}Testing R Template System${NC}"
echo "========================================"
echo ""

# Test 1: Template file exists
echo "Test: Template file exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/r/analysis/analysis.Rmd.tmpl" "analysis.Rmd template exists"
echo ""

# Test 2: Template content validation
echo "Test: Template content is valid"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/r/analysis/analysis.Rmd.tmpl" "title: \"Analysis\"" "Template has YAML front matter"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/r/analysis/analysis.Rmd.tmpl" '{r setup' "Template has R code chunk"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/r/analysis/analysis.Rmd.tmpl" "library(tidyverse)" "Template loads tidyverse"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/r/analysis/analysis.Rmd.tmpl" "## Introduction" "Template has sections"
echo ""

# Test 3: load_r_template function exists
echo "Test: load_r_template function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/r-dev.sh" "^load_r_template()" "load_r_template function is defined"
assert_file_contains "$PROJECT_ROOT/lib/features/r-dev.sh" "templates/r/" "Function references R templates directory"
echo ""

# Test 4: r-init-analysis function uses template loader
echo "Test: r-init-analysis function uses template loader"
assert_file_contains "$PROJECT_ROOT/lib/features/r-dev.sh" "load_r_template.*analysis/analysis.Rmd.tmpl" "r-init-analysis uses template loader"
echo ""

# Test 5: Function naming convention
echo "Test: Function naming convention"
assert_file_contains "$PROJECT_ROOT/lib/features/r-dev.sh" "^r-init-package()" "r-init-package function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/r-dev.sh" "^r-init-analysis()" "r-init-analysis function exists"
echo ""

# Test 6: Simulated template loading
echo "Test: Template loading simulation"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Simulate the load_r_template function
load_r_template_test() {
    local template_path="$1"
    local template_file="$PROJECT_ROOT/lib/features/templates/r/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    cat "$template_file"
}

# Test loading
if load_r_template_test "analysis/analysis.Rmd.tmpl" > "$TEMP_DIR/analysis.Rmd"; then
    if grep -q "title: \"Analysis\"" "$TEMP_DIR/analysis.Rmd"; then
        echo -e "${GREEN}✓${NC} Template loads successfully"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Template content invalid"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify R Markdown structure
if grep -q '```{r setup' "$TEMP_DIR/analysis.Rmd" && grep -q "## Introduction" "$TEMP_DIR/analysis.Rmd"; then
    echo -e "${GREEN}✓${NC} R Markdown template has valid structure"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} R Markdown template missing required elements"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify inline R evaluation syntax
if grep -q "Sys.Date()" "$TEMP_DIR/analysis.Rmd"; then
    echo -e "${GREEN}✓${NC} Template includes inline R evaluation"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} Template missing inline R evaluation"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

echo ""
echo "========================================"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo "========================================"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
