#!/usr/bin/env bash
# Unit tests for Rust template system
#
# This test validates that:
# 1. All Rust template files exist and are valid
# 2. The load_rust_template function works correctly
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

echo -e "${YELLOW}Testing Rust Template System${NC}"
echo "========================================"
echo ""

# Test 1: Template files exist
echo "Test: Template files exist"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/rust/treesitter/grammar.js.tmpl" "grammar.js template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/rust/just/justfile.tmpl" "justfile template exists"
echo ""

# Test 2: Template content validation
echo "Test: Template content is valid"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/rust/treesitter/grammar.js.tmpl" "module.exports = grammar" "grammar.js has module export"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/rust/treesitter/grammar.js.tmpl" "__LANG_NAME__" "grammar.js has language placeholder"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/rust/treesitter/grammar.js.tmpl" "source_file" "grammar.js has source_file rule"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/rust/just/justfile.tmpl" "# Project automation with just" "justfile has description"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/rust/just/justfile.tmpl" "cargo build" "justfile has build command"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/rust/just/justfile.tmpl" "cargo test" "justfile has test command"
echo ""

# Test 3: load_rust_template function exists
echo "Test: load_rust_template function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/rust-dev.sh" "^load_rust_template()" "load_rust_template function is defined"
assert_file_contains "$PROJECT_ROOT/lib/features/rust-dev.sh" "templates/rust/" "Function references Rust templates directory"
echo ""

# Test 4: Functions use template loader
echo "Test: Functions use template loader"
assert_file_contains "$PROJECT_ROOT/lib/features/rust-dev.sh" "load_rust_template.*treesitter/grammar.js.tmpl" "ts-init-grammar uses template loader"
assert_file_contains "$PROJECT_ROOT/lib/features/rust-dev.sh" "load_rust_template.*just/justfile.tmpl" "just-init uses template loader"
echo ""

# Test 5: Function naming
echo "Test: Function naming"
assert_file_contains "$PROJECT_ROOT/lib/features/rust-dev.sh" "^ts-init-grammar()" "ts-init-grammar function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/rust-dev.sh" "^just-init()" "just-init function exists"
echo ""

# Test 6: Simulated template loading
echo "Test: Template loading simulation"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Simulate the load_rust_template function
load_rust_template_test() {
    local template_path="$1"
    local lang_name="${2:-}"
    local template_file="$PROJECT_ROOT/lib/features/templates/rust/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$lang_name" ]; then
        sed "s/__LANG_NAME__/${lang_name}/g" "$template_file"
    else
        cat "$template_file"
    fi
}

# Test loading justfile without substitution
if load_rust_template_test "just/justfile.tmpl" > "$TEMP_DIR/justfile"; then
    if grep -q "cargo build" "$TEMP_DIR/justfile"; then
        echo -e "${GREEN}✓${NC} Justfile template loads without substitution"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Justfile template content invalid"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Justfile template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test loading grammar.js with substitution
if load_rust_template_test "treesitter/grammar.js.tmpl" "mylang" > "$TEMP_DIR/grammar.js"; then
    if grep -q "name: 'mylang'" "$TEMP_DIR/grammar.js"; then
        echo -e "${GREEN}✓${NC} Grammar template substitution works correctly"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Placeholder not substituted in grammar.js"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        cat "$TEMP_DIR/grammar.js"
    fi
else
    echo -e "${RED}✗${NC} Grammar template loading with substitution failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify placeholder was removed
if grep -q "__LANG_NAME__" "$TEMP_DIR/grammar.js"; then
    echo -e "${RED}✗${NC} Placeholder still present after substitution"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} All placeholders substituted in grammar.js"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Test grammar.js structure
if grep -q "module.exports = grammar" "$TEMP_DIR/grammar.js" && grep -q "source_file" "$TEMP_DIR/grammar.js"; then
    echo -e "${GREEN}✓${NC} Grammar template has valid structure"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} Grammar template missing required fields"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test justfile structure
if grep -q "default:" "$TEMP_DIR/justfile" && grep -q "@just --list" "$TEMP_DIR/justfile"; then
    echo -e "${GREEN}✓${NC} Justfile template has valid structure"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} Justfile template missing required elements"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify justfile has common Rust commands
if grep -q "cargo build" "$TEMP_DIR/justfile" && \
   grep -q "cargo test" "$TEMP_DIR/justfile" && \
   grep -q "cargo clippy" "$TEMP_DIR/justfile"; then
    echo -e "${GREEN}✓${NC} Justfile includes common Rust commands"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} Justfile missing expected Rust commands"
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
