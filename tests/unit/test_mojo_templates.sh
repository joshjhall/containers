#!/usr/bin/env bash
# Unit tests for Mojo template system
#
# This test validates that:
# 1. All Mojo template files exist and are valid
# 2. The load_mojo_template function works correctly
# 3. Template placeholders are properly substituted

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Mojo Template System Tests"

# Setup
TEMPLATE_DIR="$PROJECT_ROOT/lib/features/templates/mojo"
MOJO_DEV_SH="$PROJECT_ROOT/lib/features/mojo-dev.sh"

# Test: Template files exist
test_template_files_exist() {
    assert_file_exists "$TEMPLATE_DIR/project/README.md.tmpl"
    assert_file_exists "$TEMPLATE_DIR/project/gitignore.tmpl"
    assert_file_exists "$TEMPLATE_DIR/src/main.mojo.tmpl"
    assert_file_exists "$TEMPLATE_DIR/tests/test_main.mojo.tmpl"
}

# Test: README template content
test_readme_template_content() {
    assert_file_contains "$TEMPLATE_DIR/project/README.md.tmpl" "__PROJECT_NAME__" "README has project name placeholder"
    assert_file_contains "$TEMPLATE_DIR/project/README.md.tmpl" "mojo run src/main.mojo" "README has run command"
}

# Test: gitignore template content
test_gitignore_template_content() {
    assert_file_contains "$TEMPLATE_DIR/project/gitignore.tmpl" '*.mojopkg' "gitignore has Mojo artifacts"
    assert_file_contains "$TEMPLATE_DIR/project/gitignore.tmpl" "__pycache__" "gitignore has Python cache"
}

# Test: main.mojo template content
test_main_template_content() {
    assert_file_contains "$TEMPLATE_DIR/src/main.mojo.tmpl" "fn main()" "main.mojo has main function"
    assert_file_contains "$TEMPLATE_DIR/src/main.mojo.tmpl" "Hello from Mojo" "main.mojo has greeting"
}

# Test: test template content
test_test_template_content() {
    assert_file_contains "$TEMPLATE_DIR/tests/test_main.mojo.tmpl" "from testing import assert_equal" "test has assert import"
    assert_file_contains "$TEMPLATE_DIR/tests/test_main.mojo.tmpl" "fn test_basic()" "test has test function"
}

# Test: load_mojo_template function exists
test_load_function_exists() {
    assert_file_exists "$MOJO_DEV_SH"
    assert_file_contains "$MOJO_DEV_SH" "load_mojo_template()" "load_mojo_template function is defined"
    assert_file_contains "$MOJO_DEV_SH" "templates/mojo/" "Function references Mojo templates directory"
}

# Test: mojo-init uses template loader
test_mojo_init_uses_templates() {
    assert_file_contains "$MOJO_DEV_SH" "load_mojo_template.*project/README.md.tmpl" "mojo-init uses README template"
    assert_file_contains "$MOJO_DEV_SH" "load_mojo_template.*project/gitignore.tmpl" "mojo-init uses gitignore template"
    assert_file_contains "$MOJO_DEV_SH" "load_mojo_template.*src/main.mojo.tmpl" "mojo-init uses main.mojo template"
    assert_file_contains "$MOJO_DEV_SH" "load_mojo_template.*tests/test_main.mojo.tmpl" "mojo-init uses test template"
}

# Test: Function naming
test_function_naming() {
    assert_file_contains "$MOJO_DEV_SH" "mojo-init" "mojo-init script is created"
}

# Test: README template loading with substitution
test_readme_loading_with_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if sed "s/__PROJECT_NAME__/my-mojo-app/g" "$TEMPLATE_DIR/project/README.md.tmpl" > "$tff_temp_dir/README.md"; then
        if command grep -q "# my-mojo-app" "$tff_temp_dir/README.md"; then
            assert_true true "README template substitution works correctly"
        else
            assert_true false "Placeholder not substituted in README"
        fi

        # Verify placeholder was removed
        if command grep -q "__PROJECT_NAME__" "$tff_temp_dir/README.md"; then
            assert_true false "Placeholder still present after substitution"
        else
            assert_true true "All placeholders substituted in README"
        fi
    else
        assert_true false "README template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: gitignore loading without substitution
test_gitignore_loading_no_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/project/gitignore.tmpl" "$tff_temp_dir/.gitignore"; then
        if command grep -q '\*.mojopkg' "$tff_temp_dir/.gitignore"; then
            assert_true true "Gitignore template loads without substitution"
        else
            assert_true false "Gitignore template content invalid"
        fi
    else
        assert_true false "Gitignore template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: main.mojo template structure
test_main_template_structure() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/src/main.mojo.tmpl" "$tff_temp_dir/main.mojo"; then
        if command grep -q "fn main():" "$tff_temp_dir/main.mojo" && grep -q "Hello from Mojo" "$tff_temp_dir/main.mojo"; then
            assert_true true "Main.mojo template has valid structure"
        else
            assert_true false "Main.mojo template missing required elements"
        fi
    else
        assert_true false "Main.mojo template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: test template structure
test_test_template_structure() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/tests/test_main.mojo.tmpl" "$tff_temp_dir/test_main.mojo"; then
        if command grep -q "from testing import assert_equal" "$tff_temp_dir/test_main.mojo" && \
           command grep -q "fn test_basic():" "$tff_temp_dir/test_main.mojo"; then
            assert_true true "Test template has valid structure"
        else
            assert_true false "Test template missing required elements"
        fi
    else
        assert_true false "Test template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: gitignore has Python support
test_gitignore_python_support() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/project/gitignore.tmpl" "$tff_temp_dir/.gitignore"; then
        if command grep -q "__pycache__" "$tff_temp_dir/.gitignore" && grep -q '\*.pyc' "$tff_temp_dir/.gitignore"; then
            assert_true true "Gitignore includes Python interop patterns"
        else
            assert_true false "Gitignore missing Python patterns"
        fi
    else
        assert_true false "Gitignore template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: README has project structure
test_readme_project_structure() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if sed "s/__PROJECT_NAME__/my-mojo-app/g" "$TEMPLATE_DIR/project/README.md.tmpl" > "$tff_temp_dir/README.md"; then
        if command grep -q "## Structure" "$tff_temp_dir/README.md" && \
           command grep -q "src/.*Source code" "$tff_temp_dir/README.md" && \
           command grep -q "tests/.*Test files" "$tff_temp_dir/README.md"; then
            assert_true true "README includes project structure"
        else
            assert_true false "README missing structure section"
        fi
    else
        assert_true false "README template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Run all tests
run_test test_template_files_exist "Template files exist"
run_test test_readme_template_content "README template has correct content"
run_test test_gitignore_template_content "gitignore template has correct content"
run_test test_main_template_content "main.mojo template has correct content"
run_test test_test_template_content "test template has correct content"
run_test test_load_function_exists "load_mojo_template function exists"
run_test test_mojo_init_uses_templates "mojo-init uses template loader"
run_test test_function_naming "Function naming convention"
run_test test_readme_loading_with_substitution "README template substitution works"
run_test test_gitignore_loading_no_substitution "gitignore loads without substitution"
run_test test_main_template_structure "main.mojo template has valid structure"
run_test test_test_template_structure "test template has valid structure"
run_test test_gitignore_python_support "gitignore includes Python interop patterns"
run_test test_readme_project_structure "README includes project structure"

# Generate test report
generate_report
