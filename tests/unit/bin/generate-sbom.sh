#!/usr/bin/env bash
# Unit tests for bin/generate-sbom.sh
# Tests argument parsing, help output, and script content

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Generate SBOM Tests"

# Path to script under test
SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../../bin/generate-sbom.sh"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$SCRIPT" "generate-sbom.sh should exist"

    if [ -x "$SCRIPT" ]; then
        pass_test "generate-sbom.sh is executable"
    else
        fail_test "generate-sbom.sh is not executable"
    fi
}

# ============================================================================
# Test: Script has valid syntax
# ============================================================================
test_syntax_valid() {
    if bash -n "$SCRIPT" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

# ============================================================================
# Test: Help output
# ============================================================================
test_help_output() {
    local output
    output=$("$SCRIPT" --help 2>&1) || true

    assert_contains "$output" "Usage:" "Help should contain Usage:"
    assert_contains "$output" "--format" "Help should mention --format"
    assert_contains "$output" "--scan" "Help should mention --scan"
}

# ============================================================================
# Test: Missing image ref exits with error
# ============================================================================
test_missing_image_ref() {
    local output
    local exit_code=0
    output=$("$SCRIPT" 2>&1) || exit_code=$?

    assert_equals "$exit_code" "1" "Should exit 1 when no image ref provided"
    assert_contains "$output" "Image reference required" "Should report missing image ref"
}

# ============================================================================
# Test: Unknown option exits with error
# ============================================================================
test_unknown_option() {
    local output
    local exit_code=0
    output=$("$SCRIPT" --badopt 2>&1) || exit_code=$?

    assert_equals "$exit_code" "1" "Should exit 1 for unknown option"
    assert_contains "$output" "Unknown option" "Should report unknown option"
}

# ============================================================================
# Test: Script references expected tools
# ============================================================================
test_script_references_tools() {
    local script_content
    script_content=$(command cat "$SCRIPT")

    assert_contains "$script_content" "syft" "Should reference syft"
    assert_contains "$script_content" "grype" "Should reference grype"
}

# ============================================================================
# Test: Script has expected generation functions
# ============================================================================
test_generation_functions() {
    local script_content
    script_content=$(command cat "$SCRIPT")

    assert_contains "$script_content" "generate_spdx" "Should have generate_spdx function"
    assert_contains "$script_content" "generate_cyclonedx" "Should have generate_cyclonedx function"
    assert_contains "$script_content" "generate_table" "Should have generate_table function"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_help_output "Help output is correct"
run_test test_missing_image_ref "Missing image ref exits with error"
run_test test_unknown_option "Unknown option exits with error"
run_test test_script_references_tools "Script references expected tools"
run_test test_generation_functions "Generation functions present"

# Generate report
generate_report
