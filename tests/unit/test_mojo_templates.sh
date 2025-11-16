#!/usr/bin/env bash
# Unit tests for Mojo template system
#
# This test validates that:
# 1. All Mojo template files exist and are valid
# 2. The load_mojo_template function works correctly
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

echo -e "${YELLOW}Testing Mojo Template System${NC}"
echo "========================================"
echo ""

# Test 1: Template files exist
echo "Test: Template files exist"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/mojo/project/README.md.tmpl" "README.md template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/mojo/project/gitignore.tmpl" "gitignore template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/mojo/src/main.mojo.tmpl" "main.mojo template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/mojo/tests/test_main.mojo.tmpl" "test_main.mojo template exists"
echo ""

# Test 2: Template content validation
echo "Test: Template content is valid"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/project/README.md.tmpl" "__PROJECT_NAME__" "README has project name placeholder"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/project/README.md.tmpl" "mojo run src/main.mojo" "README has run command"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/project/gitignore.tmpl" "*.mojopkg" "gitignore has Mojo artifacts"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/project/gitignore.tmpl" "__pycache__" "gitignore has Python cache"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/src/main.mojo.tmpl" "fn main()" "main.mojo has main function"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/src/main.mojo.tmpl" "Hello from Mojo" "main.mojo has greeting"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/tests/test_main.mojo.tmpl" "from testing import assert_equal" "test has assert import"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/mojo/tests/test_main.mojo.tmpl" "fn test_basic()" "test has test function"
echo ""

# Test 3: load_mojo_template function exists in mojo-init
echo "Test: load_mojo_template function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/mojo-dev.sh" "load_mojo_template()" "load_mojo_template function is defined"
assert_file_contains "$PROJECT_ROOT/lib/features/mojo-dev.sh" "templates/mojo/" "Function references Mojo templates directory"
echo ""

# Test 4: mojo-init uses template loader
echo "Test: mojo-init uses template loader"
assert_file_contains "$PROJECT_ROOT/lib/features/mojo-dev.sh" "load_mojo_template.*project/README.md.tmpl" "mojo-init uses README template"
assert_file_contains "$PROJECT_ROOT/lib/features/mojo-dev.sh" "load_mojo_template.*project/gitignore.tmpl" "mojo-init uses gitignore template"
assert_file_contains "$PROJECT_ROOT/lib/features/mojo-dev.sh" "load_mojo_template.*src/main.mojo.tmpl" "mojo-init uses main.mojo template"
assert_file_contains "$PROJECT_ROOT/lib/features/mojo-dev.sh" "load_mojo_template.*tests/test_main.mojo.tmpl" "mojo-init uses test template"
echo ""

# Test 5: Function naming
echo "Test: Function naming"
assert_file_contains "$PROJECT_ROOT/lib/features/mojo-dev.sh" "mojo-init" "mojo-init script is created"
echo ""

# Test 6: Simulated template loading
echo "Test: Template loading simulation"
TEMP_DIR=$(mktemp -d)
trap 'command rm -rf "$TEMP_DIR"' EXIT

# Simulate the load_mojo_template function
load_mojo_template_test() {
    local template_path="$1"
    local project_name="${2:-}"
    local template_file="$PROJECT_ROOT/lib/features/templates/mojo/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$project_name" ]; then
        command sed "s/__PROJECT_NAME__/${project_name}/g" "$template_file"
    else
        cat "$template_file"
    fi
}

# Test loading README with substitution
if load_mojo_template_test "project/README.md.tmpl" "my-mojo-app" > "$TEMP_DIR/README.md"; then
    if grep -q "# my-mojo-app" "$TEMP_DIR/README.md"; then
        echo -e "${GREEN}✓${NC} README template substitution works correctly"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Placeholder not substituted in README"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        cat "$TEMP_DIR/README.md"
    fi
else
    echo -e "${RED}✗${NC} README template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify placeholder was removed
if grep -q "__PROJECT_NAME__" "$TEMP_DIR/README.md"; then
    echo -e "${RED}✗${NC} Placeholder still present after substitution"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} All placeholders substituted in README"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Test loading gitignore without substitution
if load_mojo_template_test "project/gitignore.tmpl" > "$TEMP_DIR/.gitignore"; then
    if grep -q '\*.mojopkg' "$TEMP_DIR/.gitignore"; then
        echo -e "${GREEN}✓${NC} Gitignore template loads without substitution"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Gitignore template content invalid"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Gitignore template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test main.mojo structure
if load_mojo_template_test "src/main.mojo.tmpl" > "$TEMP_DIR/main.mojo"; then
    if grep -q "fn main():" "$TEMP_DIR/main.mojo" && grep -q "Hello from Mojo" "$TEMP_DIR/main.mojo"; then
        echo -e "${GREEN}✓${NC} Main.mojo template has valid structure"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Main.mojo template missing required elements"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Main.mojo template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test test file structure
if load_mojo_template_test "tests/test_main.mojo.tmpl" > "$TEMP_DIR/test_main.mojo"; then
    if grep -q "from testing import assert_equal" "$TEMP_DIR/test_main.mojo" && \
       grep -q "fn test_basic():" "$TEMP_DIR/test_main.mojo"; then
        echo -e "${GREEN}✓${NC} Test template has valid structure"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Test template missing required elements"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Test template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify gitignore has Python support
if grep -q "__pycache__" "$TEMP_DIR/.gitignore" && grep -q '\*.pyc' "$TEMP_DIR/.gitignore"; then
    echo -e "${GREEN}✓${NC} Gitignore includes Python interop patterns"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} Gitignore missing Python patterns"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify README has structure section
if grep -q "## Structure" "$TEMP_DIR/README.md" && \
   grep -q "src/.*Source code" "$TEMP_DIR/README.md" && \
   grep -q "tests/.*Test files" "$TEMP_DIR/README.md"; then
    echo -e "${GREEN}✓${NC} README includes project structure"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} README missing structure section"
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
