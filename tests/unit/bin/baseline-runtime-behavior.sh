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

# ============================================================================
# Test: Sources extracted library modules
# ============================================================================
test_sources_rule_generators() {
    local script_content
    script_content=$(command cat "$BASELINE_SCRIPT")

    assert_contains "$script_content" "lib/baseline/rule-generators.sh" \
        "Should source rule-generators.sh library"
}

test_sources_anomaly_detection() {
    local script_content
    script_content=$(command cat "$BASELINE_SCRIPT")

    assert_contains "$script_content" "lib/baseline/anomaly-detection.sh" \
        "Should source anomaly-detection.sh library"
}

test_rule_generators_has_functions() {
    local lib_file
    lib_file="$(dirname "${BASH_SOURCE[0]}")/../../../bin/lib/baseline/rule-generators.sh"

    assert_file_exists "$lib_file" "rule-generators.sh should exist"

    local lib_content
    lib_content=$(command cat "$lib_file")

    assert_contains "$lib_content" "generate_falco_tuning()" \
        "rule-generators.sh should define generate_falco_tuning"
    assert_contains "$lib_content" "generate_alert_rules()" \
        "rule-generators.sh should define generate_alert_rules"
}

test_anomaly_detection_has_functions() {
    local lib_file
    lib_file="$(dirname "${BASH_SOURCE[0]}")/../../../bin/lib/baseline/anomaly-detection.sh"

    assert_file_exists "$lib_file" "anomaly-detection.sh should exist"

    local lib_content
    lib_content=$(command cat "$lib_file")

    assert_contains "$lib_content" "compare_to_baseline()" \
        "anomaly-detection.sh should define compare_to_baseline"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_help_output "Help output is correct"
run_test test_config_defaults "Configuration defaults present"
run_test test_compliance_docs "Compliance documentation present"
run_test test_required_functions "Required functions defined"
run_test test_sources_rule_generators "Sources rule-generators.sh library"
run_test test_sources_anomaly_detection "Sources anomaly-detection.sh library"
run_test test_rule_generators_has_functions "Rule generators library defines expected functions"
run_test test_anomaly_detection_has_functions "Anomaly detection library defines expected functions"

# Generate report
generate_report
