#!/usr/bin/env bash
# Unit tests for bin/baseline-runtime-behavior.sh
# Tests runtime behavior baseline collection for anomaly detection

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Baseline Runtime Behavior Tests"

# Path to script under test
BASELINE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../../bin/baseline-runtime-behavior.sh"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$BASELINE_SCRIPT" "baseline-runtime-behavior.sh should exist"

    if [ -x "$BASELINE_SCRIPT" ]; then
        pass_test "baseline-runtime-behavior.sh is executable"
    else
        fail_test "baseline-runtime-behavior.sh is not executable"
    fi
}

# ============================================================================
# Test: Script has valid syntax
# ============================================================================
test_syntax_valid() {
    if bash -n "$BASELINE_SCRIPT" 2>&1; then
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
    output=$("$BASELINE_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "Usage:" "Help should contain usage"
    assert_contains "$output" "--duration" "Help should mention duration option"
    assert_contains "$output" "--namespace" "Help should mention namespace option"
    assert_contains "$output" "--analyze" "Help should mention analyze option"
}

# ============================================================================
# Test: Configuration defaults
# ============================================================================
test_config_defaults() {
    local script_content
    script_content=$(command cat "$BASELINE_SCRIPT")

    assert_contains "$script_content" 'BASELINE_DURATION=' "Should have BASELINE_DURATION"
    assert_contains "$script_content" 'OUTPUT_DIR=' "Should have OUTPUT_DIR"
    assert_contains "$script_content" 'PROMETHEUS_URL=' "Should have PROMETHEUS_URL"
}

# ============================================================================
# Test: Compliance documentation
# ============================================================================
test_compliance_docs() {
    local script_content
    script_content=$(command cat "$BASELINE_SCRIPT")

    assert_contains "$script_content" "FedRAMP" "Should reference FedRAMP"
    assert_contains "$script_content" "CMMC" "Should reference CMMC"
    assert_contains "$script_content" "CIS Control" "Should reference CIS Controls"
}

# ============================================================================
# Test: Required functions
# ============================================================================
test_required_functions() {
    local script_content
    script_content=$(command cat "$BASELINE_SCRIPT")

    assert_contains "$script_content" "usage()" "Should define usage function"
    assert_contains "$script_content" "log_info()" "Should define log_info function"
    assert_contains "$script_content" "log_error()" "Should define log_error function"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_help_output "Help output is correct"
run_test test_config_defaults "Configuration defaults present"
run_test test_compliance_docs "Compliance documentation present"
run_test test_required_functions "Required functions defined"

# Generate report
generate_report
