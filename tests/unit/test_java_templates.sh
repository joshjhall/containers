#!/usr/bin/env bash
# Unit tests for Java template system
#
# This test validates that:
# 1. All Java template files exist and are valid
# 2. The load_java_template function works correctly
# 3. Template placeholders are properly substituted
# 4. Config templates load correctly

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

echo -e "${YELLOW}Testing Java Template System${NC}"
echo "========================================"
echo ""

# Test 1: Template files exist
echo "Test: Template files exist"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/java/benchmark/Benchmark.java.tmpl" "Benchmark template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/java/config/checkstyle.xml.tmpl" "Checkstyle template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/java/config/pmd-ruleset.xml.tmpl" "PMD template exists"
assert_file_exists "$PROJECT_ROOT/lib/features/templates/java/config/spotbugs-exclude.xml.tmpl" "SpotBugs template exists"
echo ""

# Test 2: Template content validation
echo "Test: Template content is valid"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/java/benchmark/Benchmark.java.tmpl" "__CLASS_NAME__" "Benchmark has class name placeholder"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/java/benchmark/Benchmark.java.tmpl" "org.openjdk.jmh.annotations" "Benchmark imports JMH"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/java/benchmark/Benchmark.java.tmpl" "@Benchmark" "Benchmark has annotation"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/java/config/checkstyle.xml.tmpl" "TreeWalker" "Checkstyle has TreeWalker"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/java/config/pmd-ruleset.xml.tmpl" "ruleset" "PMD has ruleset"
assert_file_contains "$PROJECT_ROOT/lib/features/templates/java/config/spotbugs-exclude.xml.tmpl" "FindBugsFilter" "SpotBugs has filter"
echo ""

# Test 3: load_java_template function exists
echo "Test: load_java_template function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/java-dev.sh" "^load_java_template()" "load_java_template function is defined"
assert_file_contains "$PROJECT_ROOT/lib/features/java-dev.sh" "templates/java/" "Function references Java templates directory"
echo ""

# Test 4: java-benchmark uses template loader
echo "Test: java-benchmark uses template loader"
assert_file_contains "$PROJECT_ROOT/lib/features/java-dev.sh" "load_java_template.*benchmark/Benchmark.java.tmpl" "java-benchmark uses template loader"
echo ""

# Test 5: Config templates use loader
echo "Test: Config templates use loader"
assert_file_contains "$PROJECT_ROOT/lib/features/java-dev.sh" "load_java_config_template" "load_java_config_template function exists"
assert_file_contains "$PROJECT_ROOT/lib/features/java-dev.sh" "load_java_config_template.*checkstyle.xml.tmpl" "Uses checkstyle template"
assert_file_contains "$PROJECT_ROOT/lib/features/java-dev.sh" "load_java_config_template.*pmd-ruleset.xml.tmpl" "Uses PMD template"
assert_file_contains "$PROJECT_ROOT/lib/features/java-dev.sh" "load_java_config_template.*spotbugs-exclude.xml.tmpl" "Uses SpotBugs template"
echo ""

# Test 6: Simulated template loading
echo "Test: Template loading simulation"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Simulate the load_java_template function
load_java_template_test() {
    local template_path="$1"
    local class_name="${2:-}"
    local template_file="$PROJECT_ROOT/lib/features/templates/java/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$class_name" ]; then
        sed "s/__CLASS_NAME__/${class_name}/g" "$template_file"
    else
        cat "$template_file"
    fi
}

# Test loading benchmark with substitution
if load_java_template_test "benchmark/Benchmark.java.tmpl" "MyBenchmark" > "$TEMP_DIR/MyBenchmark.java"; then
    if grep -q "public class MyBenchmark" "$TEMP_DIR/MyBenchmark.java"; then
        echo -e "${GREEN}✓${NC} Benchmark template substitution works correctly"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Class name not substituted in benchmark"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Benchmark template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify placeholder was removed
if grep -q "__CLASS_NAME__" "$TEMP_DIR/MyBenchmark.java"; then
    echo -e "${RED}✗${NC} Placeholder still present after substitution"
    TESTS_FAILED=$((TESTS_FAILED + 1))
else
    echo -e "${GREEN}✓${NC} All placeholders substituted in benchmark"
    TESTS_PASSED=$((TESTS_PASSED + 1))
fi

# Test checkstyle config loading
if load_java_template_test "config/checkstyle.xml.tmpl" > "$TEMP_DIR/checkstyle.xml"; then
    if grep -q "TreeWalker" "$TEMP_DIR/checkstyle.xml" && grep -q "LineLength" "$TEMP_DIR/checkstyle.xml"; then
        echo -e "${GREEN}✓${NC} Checkstyle config template has valid structure"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Checkstyle config template missing required elements"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} Checkstyle config template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test PMD ruleset loading
if load_java_template_test "config/pmd-ruleset.xml.tmpl" > "$TEMP_DIR/pmd-ruleset.xml"; then
    if grep -q "category/java/bestpractices.xml" "$TEMP_DIR/pmd-ruleset.xml"; then
        echo -e "${GREEN}✓${NC} PMD ruleset template has valid structure"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} PMD ruleset template missing required elements"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} PMD ruleset template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Test SpotBugs filter loading
if load_java_template_test "config/spotbugs-exclude.xml.tmpl" > "$TEMP_DIR/spotbugs-exclude.xml"; then
    if grep -q "FindBugsFilter" "$TEMP_DIR/spotbugs-exclude.xml"; then
        echo -e "${GREEN}✓${NC} SpotBugs filter template has valid structure"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} SpotBugs filter template missing required elements"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
else
    echo -e "${RED}✗${NC} SpotBugs filter template loading failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
fi

# Verify benchmark has JMH annotations
if grep -q "@BenchmarkMode" "$TEMP_DIR/MyBenchmark.java" && \
   grep -q "@Benchmark" "$TEMP_DIR/MyBenchmark.java" && \
   grep -q "Runner" "$TEMP_DIR/MyBenchmark.java"; then
    echo -e "${GREEN}✓${NC} Benchmark includes required JMH components"
    TESTS_PASSED=$((TESTS_PASSED + 1))
else
    echo -e "${RED}✗${NC} Benchmark missing JMH components"
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
