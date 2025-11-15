#!/usr/bin/env bash
# Unit tests for Node.js template system
#
# This test validates that:
# 1. All Node.js template files exist and are valid
# 2. The load_node_template function works correctly
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

echo -e "${YELLOW}Testing Node.js Template System${NC}"
echo "========================================"
echo ""

# Test 1: All template files exist
echo "Test: Template files exist"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/common/gitignore.tmpl" "gitignore template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/config/tsconfig.json.tmpl" "tsconfig template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/config/jest.config.js.tmpl" "jest config template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/config/eslintrc.js.tmpl" "eslintrc template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/config/prettierrc.tmpl" "prettierrc template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/config/vite.config.ts.tmpl" "vite config template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/api/index.ts.tmpl" "API template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/cli/index.ts.tmpl" "CLI template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/lib/index.ts.tmpl" "Library template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/node/test/index.test.ts.tmpl" "Test template exists"
echo ""

# Test 2: Template content validation
echo "Test: Template content is valid"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/common/gitignore.tmpl" "node_modules/" "gitignore contains node_modules"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/config/tsconfig.json.tmpl" '"target"' "tsconfig has TypeScript options"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/config/jest.config.js.tmpl" "ts-jest" "jest config has ts-jest preset"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/config/eslintrc.js.tmpl" "typescript-eslint" "eslintrc has TypeScript plugin"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/config/prettierrc.tmpl" "singleQuote" "prettierrc has formatting options"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/config/vite.config.ts.tmpl" "defineConfig" "vite config imports defineConfig"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/api/index.ts.tmpl" "express" "API template uses express"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/cli/index.ts.tmpl" "__PROJECT_NAME__" "CLI template has placeholder"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/lib/index.ts.tmpl" "export function" "Library template exports function"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/node/test/index.test.ts.tmpl" "describe" "Test template has test structure"
echo ""

# Test 3: load_node_template function exists in both files
echo "Test: load_node_template function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "^load_node_template()" "load_node_template function is defined in node-dev.sh"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "sed \"s/__PROJECT_NAME__" "node-dev.sh function has placeholder substitution"
assert_file_contains "$PROJECT_ROOT/lib/features/node.sh" "^load_node_template()" "load_node_template function is defined in node.sh"
assert_file_contains "$PROJECT_ROOT/lib/features/node.sh" "sed \"s/__PROJECT_NAME__" "node.sh function has placeholder substitution"
echo ""

# Test 4: node-init function uses templates
echo "Test: node-init function uses template loader"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*config/tsconfig.json.tmpl" "node-init uses tsconfig template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*config/jest.config.js.tmpl" "node-init uses jest config template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*config/eslintrc.js.tmpl" "node-init uses eslintrc template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*config/prettierrc.tmpl" "node-init uses prettierrc template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*api/index.ts.tmpl" "node-init uses API template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*cli/index.ts.tmpl" "node-init uses CLI template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*config/vite.config.ts.tmpl" "node-init uses vite config template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*lib/index.ts.tmpl" "node-init uses lib template"
assert_file_contains "$PROJECT_ROOT/lib/features/node-dev.sh" "load_node_template.*test/index.test.ts.tmpl" "node-init uses test template"
echo ""

# Test 5: Simulated template loading
echo "Test: Template loading simulation"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Simulate the load_node_template function
load_node_template_test() {
    local template_path="$1"
    local project_name="${2:-}"
    local template_file="$PROJECT_ROOT/lib/features/templates/node/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$project_name" ]; then
        sed "s/__PROJECT_NAME__/${project_name}/g" "$template_file"
    else
        cat "$template_file"
    fi
}

# Test loading without substitution
if load_node_template_test "common/gitignore.tmpl" > "$TEMP_DIR/gitignore"; then
    if grep -q "node_modules/" "$TEMP_DIR/gitignore"; then
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
if load_node_template_test "cli/index.ts.tmpl" "my-awesome-cli" > "$TEMP_DIR/index.ts"; then
    if grep -q "my-awesome-cli" "$TEMP_DIR/index.ts"; then
        echo -e "${GREEN}✓${NC} Template substitution works correctly"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Placeholder not substituted"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        cat "$TEMP_DIR/index.ts"
    fi
else
    echo -e "${RED}✗${NC} Template loading with substitution failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify placeholder was removed
if grep -q "__PROJECT_NAME__" "$TEMP_DIR/index.ts"; then
    echo -e "${RED}✗${NC} Placeholder still present after substitution"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} All placeholders substituted"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Test tsconfig.json template (JSON validation)
if load_node_template_test "config/tsconfig.json.tmpl" > "$TEMP_DIR/tsconfig.json"; then
    if grep -q '"compilerOptions"' "$TEMP_DIR/tsconfig.json" && grep -q '"target"' "$TEMP_DIR/tsconfig.json"; then
        echo -e "${GREEN}✓${NC} TypeScript config template has valid structure"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} TypeScript config template missing required fields"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} TypeScript config template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test jest.config.js template
if load_node_template_test "config/jest.config.js.tmpl" > "$TEMP_DIR/jest.config.js"; then
    if grep -q "ts-jest" "$TEMP_DIR/jest.config.js" && grep -q "testEnvironment" "$TEMP_DIR/jest.config.js"; then
        echo -e "${GREEN}✓${NC} Jest config template has valid structure"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Jest config template missing required fields"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Jest config template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test API template
if load_node_template_test "api/index.ts.tmpl" > "$TEMP_DIR/api.ts"; then
    if grep -q "express" "$TEMP_DIR/api.ts" && grep -q "app.listen" "$TEMP_DIR/api.ts"; then
        echo -e "${GREEN}✓${NC} API template has valid Express setup"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} API template missing required Express code"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} API template loading failed"
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
