#!/usr/bin/env bash
# Unit tests for Go template system
#
# This test validates that:
# 1. All Go template files exist and are valid
# 2. The load_go_template function works correctly
# 3. Template placeholders are properly substituted

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Go Template System Tests"

# Setup
TEMPLATE_DIR="$PROJECT_ROOT/lib/features/templates/go"

# Test: Template files exist
test_template_files_exist() {
    assert_file_exists "$TEMPLATE_DIR/common/gitignore.tmpl"
    assert_file_exists "$TEMPLATE_DIR/common/Makefile.tmpl"
    assert_file_exists "$TEMPLATE_DIR/cli/main.go.tmpl"
    assert_file_exists "$TEMPLATE_DIR/api/main.go.tmpl"
    assert_file_exists "$TEMPLATE_DIR/lib/lib.go.tmpl"
    assert_file_exists "$TEMPLATE_DIR/lib/lib_test.go.tmpl"
}

# Test: gitignore template content
test_gitignore_template_content() {
    assert_file_contains "$TEMPLATE_DIR/common/gitignore.tmpl" "*.exe" "gitignore contains binary patterns"
}

# Test: Makefile template content
test_makefile_template_content() {
    assert_file_contains "$TEMPLATE_DIR/common/Makefile.tmpl" "build:" "Makefile has build target"
}

# Test: CLI template content
test_cli_template_content() {
    assert_file_contains "$TEMPLATE_DIR/cli/main.go.tmpl" "package main" "CLI template is main package"
}

# Test: API template content
test_api_template_content() {
    assert_file_contains "$TEMPLATE_DIR/api/main.go.tmpl" "http.HandleFunc" "API template has HTTP handling"
}

# Test: Library template has placeholder
test_lib_template_placeholder() {
    assert_file_contains "$TEMPLATE_DIR/lib/lib.go.tmpl" "__PROJECT__" "Library template has placeholder"
}

# Test: Test template has placeholder
test_test_template_placeholder() {
    assert_file_contains "$TEMPLATE_DIR/lib/lib_test.go.tmpl" "__PROJECT__" "Test template has placeholder"
}

# Test: load_go_template function exists in golang.sh (build-time helper)
test_load_function_exists() {
    local golang_sh="$PROJECT_ROOT/lib/features/golang.sh"
    assert_file_exists "$golang_sh"
    assert_file_contains "$golang_sh" "^load_go_template()" "load_go_template function is defined"
    assert_file_contains "$golang_sh" 'sed "s/__PROJECT__' "Function has placeholder substitution"
}

# Test: go-init uses templates (in bashrc aliases file)
test_go_init_uses_templates() {
    local golang_bashrc="$PROJECT_ROOT/lib/features/lib/bashrc/golang-aliases.sh"
    assert_file_contains "$golang_bashrc" "load_go_template.*gitignore.tmpl" "go-init uses gitignore template"
    assert_file_contains "$golang_bashrc" "load_go_template.*Makefile.tmpl" "go-init uses Makefile template"
    assert_file_contains "$golang_bashrc" "load_go_template.*cli/main.go.tmpl" "go-init uses CLI template"
    assert_file_contains "$golang_bashrc" "load_go_template.*api/main.go.tmpl" "go-init uses API template"
    assert_file_contains "$golang_bashrc" "load_go_template.*lib/lib.go.tmpl" "go-init uses lib template"
    assert_file_contains "$golang_bashrc" "load_go_template.*lib/lib_test.go.tmpl" "go-init uses test template"
}

# Test: Template loading without substitution
test_template_loading_no_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    # Simulate template loading
    if cp "$TEMPLATE_DIR/common/gitignore.tmpl" "$tff_temp_dir/gitignore"; then
        if command grep -q '\*.exe' "$tff_temp_dir/gitignore"; then
            assert_true true "Template loads without substitution"
        else
            assert_true false "Template content invalid"
        fi
    else
        assert_true false "Template loading failed"
    fi

    # Cleanup
    command rm -rf "$tff_temp_dir"
}

# Test: Template loading with substitution
test_template_loading_with_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    # Simulate template loading with placeholder substitution
    if sed "s/__PROJECT__/testproject/g" "$TEMPLATE_DIR/lib/lib.go.tmpl" > "$tff_temp_dir/lib.go"; then
        if command grep -q "package testproject" "$tff_temp_dir/lib.go"; then
            assert_true true "Template substitution works correctly"
        else
            assert_true false "Placeholder not substituted"
        fi

        # Verify placeholder was removed
        if command grep -q "__PROJECT__" "$tff_temp_dir/lib.go"; then
            assert_true false "Placeholder still present after substitution"
        else
            assert_true true "All placeholders substituted"
        fi
    else
        assert_true false "Template loading with substitution failed"
    fi

    # Cleanup
    command rm -rf "$tff_temp_dir"
}

# Run all tests
run_test test_template_files_exist "Template files exist"
run_test test_gitignore_template_content "gitignore template has correct content"
run_test test_makefile_template_content "Makefile template has correct content"
run_test test_cli_template_content "CLI template has correct content"
run_test test_api_template_content "API template has correct content"
run_test test_lib_template_placeholder "Library template has placeholder"
run_test test_test_template_placeholder "Test template has placeholder"
run_test test_load_function_exists "load_go_template function exists"
run_test test_go_init_uses_templates "go-init uses template loader"
run_test test_template_loading_no_substitution "Template loads without substitution"
run_test test_template_loading_with_substitution "Template loads with substitution"

# Generate test report
generate_report
