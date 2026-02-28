#!/usr/bin/env bash
# Unit tests for Ruby template system
#
# This test validates that:
# 1. All Ruby template files exist and are valid
# 2. The load_ruby_config_template function works correctly
# 3. Template content is properly loaded

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Ruby Template System Tests"

# Setup
TEMPLATE_DIR="$PROJECT_ROOT/lib/features/templates/ruby"
RUBY_DEV_SH="$PROJECT_ROOT/lib/features/ruby-dev.sh"

# Test: Template files exist
test_template_files_exist() {
    assert_file_exists "$TEMPLATE_DIR/config/rspec.tmpl"
    assert_file_exists "$TEMPLATE_DIR/config/rubocop.yml.tmpl"
}

# Test: RSpec template content
test_rspec_template_content() {
    assert_file_contains "$TEMPLATE_DIR/config/rspec.tmpl" "--require spec_helper" "RSpec has spec_helper"
    assert_file_contains "$TEMPLATE_DIR/config/rspec.tmpl" "--format documentation" "RSpec has documentation format"
}

# Test: Rubocop template content
test_rubocop_template_content() {
    assert_file_contains "$TEMPLATE_DIR/config/rubocop.yml.tmpl" "AllCops:" "Rubocop has AllCops"
    assert_file_contains "$TEMPLATE_DIR/config/rubocop.yml.tmpl" "TargetRubyVersion" "Rubocop has target version"
}

# Test: load_ruby_config_template function exists
test_load_function_exists() {
    assert_file_exists "$RUBY_DEV_SH"
    assert_file_contains "$RUBY_DEV_SH" "load_ruby_config_template()" "load_ruby_config_template function is defined"
    assert_file_contains "$RUBY_DEV_SH" "templates/ruby/" "Function references Ruby templates directory"
}

# Test: Config templates use loader
test_config_templates_use_loader() {
    assert_file_contains "$RUBY_DEV_SH" "load_ruby_config_template.*rspec.tmpl" "Uses RSpec template"
    assert_file_contains "$RUBY_DEV_SH" "load_ruby_config_template.*rubocop.yml.tmpl" "Uses Rubocop template"
}

# Test: RSpec config template loading
test_rspec_config_loading() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/config/rspec.tmpl" "$tff_temp_dir/.rspec"; then
        if command grep -q -- "--require spec_helper" "$tff_temp_dir/.rspec" && grep -q -- "--color" "$tff_temp_dir/.rspec"; then
            assert_true true "RSpec config template loads correctly"
        else
            assert_true false "RSpec config template content invalid"
        fi
    else
        assert_true false "RSpec config template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Rubocop config template loading
test_rubocop_config_loading() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/config/rubocop.yml.tmpl" "$tff_temp_dir/.rubocop.yml"; then
        if command grep -q "AllCops:" "$tff_temp_dir/.rubocop.yml" && grep -q "Metrics/MethodLength" "$tff_temp_dir/.rubocop.yml"; then
            assert_true true "Rubocop config template loads correctly"
        else
            assert_true false "Rubocop config template content invalid"
        fi
    else
        assert_true false "Rubocop config template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Run all tests
run_test test_template_files_exist "Template files exist"
run_test test_rspec_template_content "RSpec template has correct content"
run_test test_rubocop_template_content "Rubocop template has correct content"
run_test test_load_function_exists "load_ruby_config_template function exists"
run_test test_config_templates_use_loader "Config templates use loader"
run_test test_rspec_config_loading "RSpec config template loads correctly"
run_test test_rubocop_config_loading "Rubocop config template loads correctly"

# Generate test report
generate_report
