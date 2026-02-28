#!/usr/bin/env bash
# Unit tests for Java template system
#
# This test validates that:
# 1. All Java template files exist and are valid
# 2. The load_java_template function works correctly
# 3. Template placeholders are properly substituted
# 4. Config templates load correctly

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Java Template System Tests"

# Setup
TEMPLATE_DIR="$PROJECT_ROOT/lib/features/templates/java"
JAVA_DEV_SH="$PROJECT_ROOT/lib/features/java-dev.sh"
JAVA_DEV_BASHRC="$PROJECT_ROOT/lib/features/lib/bashrc/java-dev.sh"

# Test: Template files exist
test_template_files_exist() {
    assert_file_exists "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/checkstyle.xml.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/pmd-ruleset.xml.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/spotbugs-exclude.xml.tmpl"
}

# Test: Benchmark template content
test_benchmark_template_content() {
    assert_file_contains "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl" "__CLASS_NAME__" "Benchmark has class name placeholder"
    assert_file_contains "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl" "org.openjdk.jmh.annotations" "Benchmark imports JMH"
    assert_file_contains "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl" "@Benchmark" "Benchmark has annotation"
}

# Test: Checkstyle template content
test_checkstyle_template_content() {
    assert_file_contains "$TEMPLATE_DIR/config/checkstyle.xml.tmpl" "TreeWalker" "Checkstyle has TreeWalker"
}

# Test: PMD template content
test_pmd_template_content() {
    assert_file_contains "$TEMPLATE_DIR/config/pmd-ruleset.xml.tmpl" "ruleset" "PMD has ruleset"
}

# Test: SpotBugs template content
test_spotbugs_template_content() {
    assert_file_contains "$TEMPLATE_DIR/config/spotbugs-exclude.xml.tmpl" "FindBugsFilter" "SpotBugs has filter"
}

# Test: load_java_template function exists
test_load_function_exists() {
    assert_file_exists "$JAVA_DEV_BASHRC"
    assert_file_contains "$JAVA_DEV_BASHRC" "^load_java_template()" "load_java_template function is defined"
    assert_file_contains "$JAVA_DEV_BASHRC" "templates/java/" "Function references Java templates directory"
}

# Test: java-benchmark uses template loader
test_benchmark_uses_templates() {
    assert_file_contains "$JAVA_DEV_BASHRC" "load_java_template.*benchmark/Benchmark.java.tmpl" "java-benchmark uses template loader"
}

# Test: Config templates use loader
test_config_templates_use_loader() {
    assert_file_contains "$JAVA_DEV_SH" "load_java_config_template" "load_java_config_template function exists"
    assert_file_contains "$JAVA_DEV_SH" "load_java_config_template.*checkstyle.xml.tmpl" "Uses checkstyle template"
    assert_file_contains "$JAVA_DEV_SH" "load_java_config_template.*pmd-ruleset.xml.tmpl" "Uses PMD template"
    assert_file_contains "$JAVA_DEV_SH" "load_java_config_template.*spotbugs-exclude.xml.tmpl" "Uses SpotBugs template"
}

# Test: Benchmark template substitution
test_benchmark_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if sed "s/__CLASS_NAME__/MyBenchmark/g" "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl" > "$tff_temp_dir/MyBenchmark.java"; then
        if command grep -q "public class MyBenchmark" "$tff_temp_dir/MyBenchmark.java"; then
            assert_true true "Benchmark template substitution works correctly"
        else
            assert_true false "Class name not substituted in benchmark"
        fi

        # Verify placeholder was removed
        if command grep -q "__CLASS_NAME__" "$tff_temp_dir/MyBenchmark.java"; then
            assert_true false "Placeholder still present after substitution"
        else
            assert_true true "All placeholders substituted in benchmark"
        fi
    else
        assert_true false "Benchmark template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Config templates have valid structure
test_config_templates_structure() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    # Test checkstyle config
    if cp "$TEMPLATE_DIR/config/checkstyle.xml.tmpl" "$tff_temp_dir/checkstyle.xml"; then
        if command grep -q "TreeWalker" "$tff_temp_dir/checkstyle.xml" && grep -q "LineLength" "$tff_temp_dir/checkstyle.xml"; then
            assert_true true "Checkstyle config template has valid structure"
        else
            assert_true false "Checkstyle config template missing required elements"
        fi
    else
        assert_true false "Checkstyle config template loading failed"
    fi

    # Test PMD ruleset
    if cp "$TEMPLATE_DIR/config/pmd-ruleset.xml.tmpl" "$tff_temp_dir/pmd-ruleset.xml"; then
        if command grep -q "category/java/bestpractices.xml" "$tff_temp_dir/pmd-ruleset.xml"; then
            assert_true true "PMD ruleset template has valid structure"
        else
            assert_true false "PMD ruleset template missing required elements"
        fi
    else
        assert_true false "PMD ruleset template loading failed"
    fi

    # Test SpotBugs filter
    if cp "$TEMPLATE_DIR/config/spotbugs-exclude.xml.tmpl" "$tff_temp_dir/spotbugs-exclude.xml"; then
        if command grep -q "FindBugsFilter" "$tff_temp_dir/spotbugs-exclude.xml"; then
            assert_true true "SpotBugs filter template has valid structure"
        else
            assert_true false "SpotBugs filter template missing required elements"
        fi
    else
        assert_true false "SpotBugs filter template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Benchmark has JMH components
test_benchmark_jmh_components() {
    assert_file_contains "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl" "@BenchmarkMode" "Benchmark has BenchmarkMode annotation"
    assert_file_contains "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl" "@Benchmark" "Benchmark has Benchmark annotation"
    assert_file_contains "$TEMPLATE_DIR/benchmark/Benchmark.java.tmpl" "Runner" "Benchmark has Runner"
}

# Run all tests
run_test test_template_files_exist "Template files exist"
run_test test_benchmark_template_content "Benchmark template has correct content"
run_test test_checkstyle_template_content "Checkstyle template has correct content"
run_test test_pmd_template_content "PMD template has correct content"
run_test test_spotbugs_template_content "SpotBugs template has correct content"
run_test test_load_function_exists "load_java_template function exists"
run_test test_benchmark_uses_templates "java-benchmark uses template loader"
run_test test_config_templates_use_loader "Config templates use loader"
run_test test_benchmark_substitution "Benchmark template substitution works"
run_test test_config_templates_structure "Config templates have valid structure"
run_test test_benchmark_jmh_components "Benchmark has JMH components"

# Generate test report
generate_report
