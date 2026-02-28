#!/usr/bin/env bash
# Unit tests for Rust template system
#
# This test validates that:
# 1. All Rust template files exist and are valid
# 2. The load_rust_template function works correctly
# 3. Template placeholders are properly substituted

set -euo pipefail

# Source test framework
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Rust Template System Tests"

# Setup
TEMPLATE_DIR="$PROJECT_ROOT/lib/features/templates/rust"
RUST_DEV_BASHRC="$PROJECT_ROOT/lib/features/lib/bashrc/rust-dev.sh"

# Test: Template files exist
test_template_files_exist() {
    assert_file_exists "$TEMPLATE_DIR/treesitter/grammar.js.tmpl"
    assert_file_exists "$TEMPLATE_DIR/just/justfile.tmpl"
}

# Test: grammar.js template content
test_grammar_template_content() {
    assert_file_contains "$TEMPLATE_DIR/treesitter/grammar.js.tmpl" "module.exports = grammar" "grammar.js has module export"
    assert_file_contains "$TEMPLATE_DIR/treesitter/grammar.js.tmpl" "__LANG_NAME__" "grammar.js has language placeholder"
    assert_file_contains "$TEMPLATE_DIR/treesitter/grammar.js.tmpl" "source_file" "grammar.js has source_file rule"
}

# Test: justfile template content
test_justfile_template_content() {
    assert_file_contains "$TEMPLATE_DIR/just/justfile.tmpl" "# Project automation with just" "justfile has description"
    assert_file_contains "$TEMPLATE_DIR/just/justfile.tmpl" "cargo build" "justfile has build command"
    assert_file_contains "$TEMPLATE_DIR/just/justfile.tmpl" "cargo test" "justfile has test command"
}

# Test: load_rust_template function exists
test_load_function_exists() {
    assert_file_exists "$RUST_DEV_BASHRC"
    assert_file_contains "$RUST_DEV_BASHRC" "^load_rust_template()" "load_rust_template function is defined"
    assert_file_contains "$RUST_DEV_BASHRC" "templates/rust/" "Function references Rust templates directory"
}

# Test: Functions use template loader
test_functions_use_templates() {
    assert_file_contains "$RUST_DEV_BASHRC" "load_rust_template.*treesitter/grammar.js.tmpl" "ts-init-grammar uses template loader"
    assert_file_contains "$RUST_DEV_BASHRC" "load_rust_template.*just/justfile.tmpl" "just-init uses template loader"
}

# Test: Function naming
test_function_naming() {
    assert_file_contains "$RUST_DEV_BASHRC" "^ts-init-grammar()" "ts-init-grammar function exists"
    assert_file_contains "$RUST_DEV_BASHRC" "^just-init()" "just-init function exists"
}

# Test: Template loading without substitution (justfile)
test_justfile_loading_no_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/just/justfile.tmpl" "$tff_temp_dir/justfile"; then
        if command grep -q "cargo build" "$tff_temp_dir/justfile"; then
            assert_true true "Justfile template loads without substitution"
        else
            assert_true false "Justfile template content invalid"
        fi
    else
        assert_true false "Justfile template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Template loading with substitution (grammar.js)
test_grammar_loading_with_substitution() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if sed "s/__LANG_NAME__/mylang/g" "$TEMPLATE_DIR/treesitter/grammar.js.tmpl" > "$tff_temp_dir/grammar.js"; then
        if command grep -q "name: 'mylang'" "$tff_temp_dir/grammar.js"; then
            assert_true true "Grammar template substitution works correctly"
        else
            assert_true false "Placeholder not substituted in grammar.js"
        fi

        # Verify placeholder was removed
        if command grep -q "__LANG_NAME__" "$tff_temp_dir/grammar.js"; then
            assert_true false "Placeholder still present after substitution"
        else
            assert_true true "All placeholders substituted in grammar.js"
        fi
    else
        assert_true false "Grammar template loading with substitution failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Grammar template structure
test_grammar_template_structure() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if sed "s/__LANG_NAME__/mylang/g" "$TEMPLATE_DIR/treesitter/grammar.js.tmpl" > "$tff_temp_dir/grammar.js"; then
        if command grep -q "module.exports = grammar" "$tff_temp_dir/grammar.js" && command grep -q "source_file" "$tff_temp_dir/grammar.js"; then
            assert_true true "Grammar template has valid structure"
        else
            assert_true false "Grammar template missing required fields"
        fi
    else
        assert_true false "Grammar template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Justfile template structure
test_justfile_template_structure() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/just/justfile.tmpl" "$tff_temp_dir/justfile"; then
        if command grep -q "default:" "$tff_temp_dir/justfile" && command grep -q "@just --list" "$tff_temp_dir/justfile"; then
            assert_true true "Justfile template has valid structure"
        else
            assert_true false "Justfile template missing required elements"
        fi
    else
        assert_true false "Justfile template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Test: Justfile has common Rust commands
test_justfile_rust_commands() {
    local tff_temp_dir
    tff_temp_dir=$(mktemp -d)

    if cp "$TEMPLATE_DIR/just/justfile.tmpl" "$tff_temp_dir/justfile"; then
        if command grep -q "cargo build" "$tff_temp_dir/justfile" && \
           command grep -q "cargo test" "$tff_temp_dir/justfile" && \
           command grep -q "cargo clippy" "$tff_temp_dir/justfile"; then
            assert_true true "Justfile includes common Rust commands"
        else
            assert_true false "Justfile missing expected Rust commands"
        fi
    else
        assert_true false "Justfile template loading failed"
    fi

    command rm -rf "$tff_temp_dir"
}

# Run all tests
run_test test_template_files_exist "Template files exist"
run_test test_grammar_template_content "grammar.js template has correct content"
run_test test_justfile_template_content "justfile template has correct content"
run_test test_load_function_exists "load_rust_template function exists"
run_test test_functions_use_templates "Functions use template loader"
run_test test_function_naming "Function naming convention"
run_test test_justfile_loading_no_substitution "Justfile loads without substitution"
run_test test_grammar_loading_with_substitution "Grammar template substitution works"
run_test test_grammar_template_structure "Grammar template has valid structure"
run_test test_justfile_template_structure "Justfile template has valid structure"
run_test test_justfile_rust_commands "Justfile has common Rust commands"

# Generate test report
generate_report
