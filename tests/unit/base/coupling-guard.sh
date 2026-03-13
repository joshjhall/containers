#!/usr/bin/env bash
# Fan-in coupling guard for god modules
# Monitors the number of dependents of feature-header.sh and logging.sh.
# Acts as an early warning when coupling grows unexpectedly.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Coupling Guard Tests"

# ============================================================================
# Fan-In Counting
# ============================================================================

test_feature_header_fan_in() {
    local count
    count=$(command grep -rl 'feature-header\.sh' "$PROJECT_ROOT/lib/" | command wc -l)
    count=$(echo "$count" | command tr -d '[:space:]')

    # Expected range: 30-55 dependents (currently ~42)
    assert_true [ "$count" -ge 30 ] \
        "feature-header.sh fan-in ($count) should be >= 30"
    assert_true [ "$count" -le 55 ] \
        "feature-header.sh fan-in ($count) should be <= 55 (coupling growing?)"
}

test_logging_fan_in() {
    local count
    count=$(command grep -rl 'logging\.sh' "$PROJECT_ROOT/lib/" | command wc -l)
    count=$(echo "$count" | command tr -d '[:space:]')

    # Expected range: 25-45 dependents (currently ~32)
    assert_true [ "$count" -ge 25 ] \
        "logging.sh fan-in ($count) should be >= 25"
    assert_true [ "$count" -le 45 ] \
        "logging.sh fan-in ($count) should be <= 45 (coupling growing?)"
}

# ============================================================================
# Module Structure Guard
# ============================================================================

test_logging_submodules_exist() {
    # Verify that logging.sh is properly split into sub-modules
    assert_file_exists "$PROJECT_ROOT/lib/base/feature-logging.sh"
    assert_file_exists "$PROJECT_ROOT/lib/base/message-logging.sh"
    assert_file_exists "$PROJECT_ROOT/lib/base/json-logging.sh"
    assert_file_exists "$PROJECT_ROOT/lib/base/secret-scrubbing.sh"
    assert_file_exists "$PROJECT_ROOT/lib/shared/logging.sh"
}

test_feature_header_submodules_exist() {
    # Verify that feature-header.sh sources its sub-modules
    assert_file_exists "$PROJECT_ROOT/lib/base/arch-utils.sh"
    assert_file_exists "$PROJECT_ROOT/lib/base/cleanup-handler.sh"
}

# Run all tests
run_test test_feature_header_fan_in "feature-header.sh fan-in within expected range"
run_test test_logging_fan_in "logging.sh fan-in within expected range"
run_test test_logging_submodules_exist "logging.sh sub-modules all exist"
run_test test_feature_header_submodules_exist "feature-header.sh sub-modules all exist"

# Generate test report
generate_report
