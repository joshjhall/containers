#!/usr/bin/env bash
# Unit tests for Go template system
#
# This test validates that:
# 1. All Go template files exist and are valid
# 2. The load_go_template function works correctly
# 3. Template placeholders are properly substituted

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

echo -e "${YELLOW}Testing Go Template System${NC}"
echo "========================================"
echo ""

# Test 1: All template files exist
echo "Test: Template files exist"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/go/common/gitignore.tmpl" "gitignore template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/go/common/Makefile.tmpl" "Makefile template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/go/cli/main.go.tmpl" "CLI template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/go/api/main.go.tmpl" "API template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/go/lib/lib.go.tmpl" "Library template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/go/lib/lib_test.go.tmpl" "Library test template exists"
echo ""

# Test 2: Template content validation
echo "Test: Template content is valid"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/go/common/gitignore.tmpl" "*.exe" "gitignore contains binary patterns"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/go/common/Makefile.tmpl" "build:" "Makefile has build target"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/go/cli/main.go.tmpl" "package main" "CLI template is main package"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/go/api/main.go.tmpl" "http.HandleFunc" "API template has HTTP handling"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/go/lib/lib.go.tmpl" "__PROJECT__" "Library template has placeholder"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/go/lib/lib_test.go.tmpl" "__PROJECT__" "Test template has placeholder"
echo ""

# Test 3: load_go_template function exists
echo "Test: load_go_template function exists in golang.sh"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "^load_go_template()" "load_go_template function is defined"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "sed \"s/__PROJECT__" "Function has placeholder substitution"
echo ""

# Test 4: go-new function uses templates
echo "Test: go-new function uses template loader"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "load_go_template.*gitignore.tmpl" "go-new uses gitignore template"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "load_go_template.*Makefile.tmpl" "go-new uses Makefile template"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "load_go_template.*cli/main.go.tmpl" "go-new uses CLI template"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "load_go_template.*api/main.go.tmpl" "go-new uses API template"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "load_go_template.*lib/lib.go.tmpl" "go-new uses lib template"
assert_file_contains "$PROJECT_ROOT/lib/features/golang.sh" "load_go_template.*lib/lib_test.go.tmpl" "go-new uses test template"
echo ""

# Test 5: Simulated template loading
echo "Test: Template loading simulation"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Simulate the load_go_template function
load_go_template_test() {
    local template_path="$1"
    local project_name="${2:-}"
    local template_file="$PROJECT_ROOT/lib/features/templates/go/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$project_name" ]; then
        sed "s/__PROJECT__/${project_name}/g" "$template_file"
    else
        cat "$template_file"
    fi
}

# Test loading without substitution
if load_go_template_test "common/gitignore.tmpl" > "$TEMP_DIR/gitignore"; then
    if grep -q "*.exe" "$TEMP_DIR/gitignore"; then
        echo -e "${GREEN}✓${NC} Template loads without substitution"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Template content invalid"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test loading with substitution
if load_go_template_test "lib/lib.go.tmpl" "testproject" > "$TEMP_DIR/lib.go"; then
    if grep -q "package testproject" "$TEMP_DIR/lib.go"; then
        echo -e "${GREEN}✓${NC} Template substitution works correctly"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Placeholder not substituted"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        cat "$TEMP_DIR/lib.go"
    fi
else
    echo -e "${RED}✗${NC} Template loading with substitution failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify placeholder was removed
if grep -q "__PROJECT__" "$TEMP_DIR/lib.go"; then
    echo -e "${RED}✗${NC} Placeholder still present after substitution"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} All placeholders substituted"
    TESTS_PASSED=$((TESTS_PASSED + 1))
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
