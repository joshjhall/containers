#!/usr/bin/env bash
# Unit tests for Ruby template system
#
# This test validates that:
# 1. All Ruby template files exist and are valid
# 2. The load_ruby_config_template function works correctly
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

    if grep -q -- "$pattern" "$file"; then
        echo -e "${GREEN}✓${NC} $desc"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $desc - pattern not found: $pattern"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

echo -e "${YELLOW}Testing Ruby Template System${NC}"
echo "========================================"
echo ""

# Test 1: Template files exist
echo "Test: Template files exist"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/ruby/config/rspec.tmpl" "RSpec template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/ruby/config/rubocop.yml.tmpl" "Rubocop template exists"
echo ""

# Test 2: Template content validation
echo "Test: Template content is valid"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/ruby/config/rspec.tmpl" "--require spec_helper" "RSpec has spec_helper"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/ruby/config/rspec.tmpl" "--format documentation" "RSpec has documentation format"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/ruby/config/rubocop.yml.tmpl" "AllCops:" "Rubocop has AllCops"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/ruby/config/rubocop.yml.tmpl" "TargetRubyVersion" "Rubocop has target version"
echo ""

# Test 3: load_ruby_config_template function exists
echo "Test: load_ruby_config_template function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/ruby-dev.sh" "load_ruby_config_template()" "load_ruby_config_template function is defined"
assert_file_contains "$PROJECT_ROOT/lib/features/ruby-dev.sh" "templates/ruby/" "Function references Ruby templates directory"
echo ""

# Test 4: Config templates use loader
echo "Test: Config templates use loader"
assert_file_contains "$PROJECT_ROOT/lib/features/ruby-dev.sh" "load_ruby_config_template.*rspec.tmpl" "Uses RSpec template"
assert_file_contains "$PROJECT_ROOT/lib/features/ruby-dev.sh" "load_ruby_config_template.*rubocop.yml.tmpl" "Uses Rubocop template"
echo ""

# Test 5: Simulated template loading
echo "Test: Template loading simulation"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Simulate the load_ruby_config_template function
load_ruby_config_template_test() {
    local template_path="$1"
    local template_file="$PROJECT_ROOT/lib/features/templates/ruby/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    cat "$template_file"
}

# Test loading RSpec config
if load_ruby_config_template_test "config/rspec.tmpl" > "$TEMP_DIR/.rspec"; then
    if grep -q -- "--require spec_helper" "$TEMP_DIR/.rspec" && grep -q -- "--color" "$TEMP_DIR/.rspec"; then
        echo -e "${GREEN}✓${NC} RSpec config template loads correctly"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} RSpec config template content invalid"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} RSpec config template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test loading Rubocop config
if load_ruby_config_template_test "config/rubocop.yml.tmpl" > "$TEMP_DIR/.rubocop.yml"; then
    if grep -q "AllCops:" "$TEMP_DIR/.rubocop.yml" && grep -q "Metrics/MethodLength" "$TEMP_DIR/.rubocop.yml"; then
        echo -e "${GREEN}✓${NC} Rubocop config template loads correctly"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Rubocop config template content invalid"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Rubocop config template loading failed"
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
