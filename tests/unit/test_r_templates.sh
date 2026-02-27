#!/usr/bin/env bash
# Unit tests for R template system
#
# This test validates that:
# 1. All R template files exist and are valid
# 2. The load_r_template function works correctly
# 3. Template content is properly loaded

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "R Template System Tests"

# Setup
TEMPLATE_DIR="$PROJECT_ROOT/lib/features/templates/r"
R_DEV_BASHRC="$PROJECT_ROOT/lib/features/lib/bashrc/r-dev.sh"

# Test: Template file exists
test_template_files_exist() {
    assert_file_exists "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl"
}

# Test: Template content validation
test_template_content() {
    assert_file_contains "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl" 'title: "Analysis"' "Template has YAML front matter"
    assert_file_contains "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl" '{r setup' "Template has R code chunk"
    assert_file_contains "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl" "library(tidyverse)" "Template loads tidyverse"
    assert_file_contains "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl" "## Introduction" "Template has sections"
}

# Test: load_r_template function exists
test_load_function_exists() {
    assert_file_exists "$R_DEV_BASHRC"
    assert_file_contains "$R_DEV_BASHRC" "^load_r_template()" "load_r_template function is defined"
    assert_file_contains "$R_DEV_BASHRC" "templates/r/" "Function references R templates directory"
}

# Test: r-init-analysis function uses template loader
test_init_analysis_uses_templates() {
    assert_file_contains "$R_DEV_BASHRC" "load_r_template.*analysis/analysis.Rmd.tmpl" "r-init-analysis uses template loader"
}

# Test: Function naming convention
test_function_naming() {
    assert_file_contains "$R_DEV_BASHRC" "^r-init-package()" "r-init-package function exists"
    assert_file_contains "$R_DEV_BASHRC" "^r-init-analysis()" "r-init-analysis function exists"
}

# Test: Template loading simulation
test_template_loading() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl" "$tff_temp_dir/analysis.Rmd"; then
        if grep -q 'title: "Analysis"' "$tff_temp_dir/analysis.Rmd"; then
            assert_true true "Template loads successfully"
        else
            assert_true false "Template content invalid"
        fi
    else
        assert_true false "Template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: R Markdown structure
test_rmarkdown_structure() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl" "$tff_temp_dir/analysis.Rmd"; then
        # Note: Using single backticks in grep pattern for R code chunk
        if grep -q '{r setup' "$tff_temp_dir/analysis.Rmd" && grep -q "## Introduction" "$tff_temp_dir/analysis.Rmd"; then
            assert_true true "R Markdown template has valid structure"
        else
            assert_true false "R Markdown template missing required elements"
        fi
    else
        assert_true false "R Markdown template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Inline R evaluation
test_inline_r_evaluation() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/analysis/analysis.Rmd.tmpl" "$tff_temp_dir/analysis.Rmd"; then
        if grep -q "Sys.Date()" "$tff_temp_dir/analysis.Rmd"; then
            assert_true true "Template includes inline R evaluation"
        else
            assert_true false "Template missing inline R evaluation"
        fi
    else
        assert_true false "Template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Run all tests
run_test test_template_files_exist "Template file exists"
run_test test_template_content "Template content is valid"
run_test test_load_function_exists "load_r_template function exists"
run_test test_init_analysis_uses_templates "r-init-analysis uses template loader"
run_test test_function_naming "Function naming convention"
run_test test_template_loading "Template loads successfully"
run_test test_rmarkdown_structure "R Markdown template has valid structure"
run_test test_inline_r_evaluation "Template includes inline R evaluation"

# Generate test report
generate_report
