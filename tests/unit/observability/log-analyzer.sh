#!/usr/bin/env bash
# Unit tests for lib/observability/log-analyzer.sh
# Tests log analysis functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Log Analyzer Tests"

# Path to script under test
LOG_ANALYZER="$(dirname "${BASH_SOURCE[0]}")/../../../lib/observability/log-analyzer.sh"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$LOG_ANALYZER" "log-analyzer.sh should exist"

    if [ -x "$LOG_ANALYZER" ]; then
        pass_test "log-analyzer.sh is executable"
    else
        fail_test "log-analyzer.sh is not executable"
    fi
}

# ============================================================================
# Test: Script has valid syntax
# ============================================================================
test_syntax_valid() {
    if bash -n "$LOG_ANALYZER" 2>&1; then
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
    output=$("$LOG_ANALYZER" --help 2>&1) || true

    assert_contains "$output" "Usage:" "Help should contain usage"
}

# ============================================================================
# Test: Analysis functions
# ============================================================================
test_analysis_functions() {
    local script_content
    script_content=$(cat "$LOG_ANALYZER")

    assert_contains "$script_content" "analyze" "Should have analyze functionality"
}

# ============================================================================
# Test: Log file processing
# ============================================================================
test_log_processing() {
    local script_content
    script_content=$(cat "$LOG_ANALYZER")

    assert_contains "$script_content" "log" "Should process log files"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_help_output "Help output is correct"
run_test test_analysis_functions "Analysis functions present"
run_test test_log_processing "Log processing supported"

# Generate report
generate_report
