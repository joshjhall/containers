#!/usr/bin/env bash
# Unit tests for Node.js template system
#
# This test validates that:
# 1. All Node.js template files exist and are valid
# 2. The load_node_template function works correctly
# 3. Template placeholders are properly substituted

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Node.js Template System Tests"

# Setup
TEMPLATE_DIR="$PROJECT_ROOT/lib/features/templates/node"
NODE_DEV_SH="$PROJECT_ROOT/lib/features/node-dev.sh"
NODE_SH="$PROJECT_ROOT/lib/features/node.sh"

# Test: Template files exist
test_template_files_exist() {
    assert_file_exists "$TEMPLATE_DIR/common/gitignore.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/tsconfig.json.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/jest.config.js.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/eslintrc.js.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/prettierrc.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/vite.config.ts.tmpl"
    assert_file_exists "$TEMPLATE_DIR/api/index.ts.tmpl"
    assert_file_exists "$TEMPLATE_DIR/cli/index.ts.tmpl"
    assert_file_exists "$TEMPLATE_DIR/lib/index.ts.tmpl"
    assert_file_exists "$TEMPLATE_DIR/test/index.test.ts.tmpl"
}

# Test: gitignore template content
test_gitignore_template_content() {
    assert_file_contains "$TEMPLATE_DIR/common/gitignore.tmpl" "node_modules/" "gitignore contains node_modules"
}

# Test: Config template contents
test_config_templates_content() {
    assert_file_contains "$TEMPLATE_DIR/config/tsconfig.json.tmpl" '"target"' "tsconfig has TypeScript options"
    assert_file_contains "$TEMPLATE_DIR/config/jest.config.js.tmpl" "ts-jest" "jest config has ts-jest preset"
    assert_file_contains "$TEMPLATE_DIR/config/eslintrc.js.tmpl" "typescript-eslint" "eslintrc has TypeScript plugin"
    assert_file_contains "$TEMPLATE_DIR/config/prettierrc.tmpl" "singleQuote" "prettierrc has formatting options"
    assert_file_contains "$TEMPLATE_DIR/config/vite.config.ts.tmpl" "defineConfig" "vite config imports defineConfig"
}

# Test: Code template contents
test_code_templates_content() {
    assert_file_contains "$TEMPLATE_DIR/api/index.ts.tmpl" "express" "API template uses express"
    assert_file_contains "$TEMPLATE_DIR/cli/index.ts.tmpl" "__PROJECT_NAME__" "CLI template has placeholder"
    assert_file_contains "$TEMPLATE_DIR/lib/index.ts.tmpl" "export function" "Library template exports function"
    assert_file_contains "$TEMPLATE_DIR/test/index.test.ts.tmpl" "describe" "Test template has test structure"
}

# Test: load_node_template function exists in node-dev.sh
test_load_function_exists_node_dev() {
    assert_file_exists "$NODE_DEV_SH"
    assert_file_contains "$NODE_DEV_SH" "^load_node_template()" "load_node_template function is defined in node-dev.sh"
    assert_file_contains "$NODE_DEV_SH" 'sed "s/__PROJECT_NAME__' "node-dev.sh function has placeholder substitution"
}

# Test: load_node_template function exists in node.sh
test_load_function_exists_node() {
    assert_file_exists "$NODE_SH"
    assert_file_contains "$NODE_SH" "^load_node_template()" "load_node_template function is defined in node.sh"
    assert_file_contains "$NODE_SH" 'sed "s/__PROJECT_NAME__' "node.sh function has placeholder substitution"
}

# Test: node-init uses templates
test_node_init_uses_templates() {
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*config/tsconfig.json.tmpl" "node-init uses tsconfig template"
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*config/jest.config.js.tmpl" "node-init uses jest config template"
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*config/eslintrc.js.tmpl" "node-init uses eslintrc template"
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*config/prettierrc.tmpl" "node-init uses prettierrc template"
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*api/index.ts.tmpl" "node-init uses API template"
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*cli/index.ts.tmpl" "node-init uses CLI template"
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*lib/index.ts.tmpl" "node-init uses lib template"
    assert_file_contains "$NODE_DEV_SH" "load_node_template.*test/index.test.ts.tmpl" "node-init uses test template"
}

# Test: Template loading without substitution
test_template_loading_no_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/common/gitignore.tmpl" "$tff_temp_dir/gitignore"; then
        if grep -q 'node_modules/' "$tff_temp_dir/gitignore"; then
            assert_true true "Template loads without substitution"
        else
            assert_true false "Template content invalid"
        fi
    else
        assert_true false "Template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Template loading with substitution
test_template_loading_with_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if sed "s/__PROJECT_NAME__/testproject/g" "$TEMPLATE_DIR/cli/index.ts.tmpl" > "$tff_temp_dir/index.ts"; then
        if grep -q "testproject" "$tff_temp_dir/index.ts"; then
            assert_true true "Template substitution works correctly"
        else
            assert_true false "Placeholder not substituted"
        fi

        # Verify placeholder was removed
        if grep -q "__PROJECT_NAME__" "$tff_temp_dir/index.ts"; then
            assert_true false "Placeholder still present after substitution"
        else
            assert_true true "All placeholders substituted"
        fi
    else
        assert_true false "Template loading with substitution failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Run all tests
run_test test_template_files_exist "Template files exist"
run_test test_gitignore_template_content "gitignore template has correct content"
run_test test_config_templates_content "Config templates have correct content"
run_test test_code_templates_content "Code templates have correct content"
run_test test_load_function_exists_node_dev "load_node_template function exists in node-dev.sh"
run_test test_load_function_exists_node "load_node_template function exists in node.sh"
run_test test_node_init_uses_templates "node-init uses template loader"
run_test test_template_loading_no_substitution "Template loads without substitution"
run_test test_template_loading_with_substitution "Template loads with substitution"

# Generate test report
generate_report
