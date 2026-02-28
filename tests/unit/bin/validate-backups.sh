#!/usr/bin/env bash
# Unit tests for bin/validate-backups.sh
# Tests backup validation functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Validate Backups Tests"

# Path to script under test
VALIDATE_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../../../bin/validate-backups.sh"

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$VALIDATE_SCRIPT" "validate-backups.sh should exist"

    if [ -x "$VALIDATE_SCRIPT" ]; then
        pass_test "validate-backups.sh is executable"
    else
        fail_test "validate-backups.sh is not executable"
    fi
}

# ============================================================================
# Test: Script has valid syntax
# ============================================================================
test_syntax_valid() {
    if bash -n "$VALIDATE_SCRIPT" 2>&1; then
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
    output=$("$VALIDATE_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "Usage:" "Help should contain usage"
}

# ============================================================================
# Test: Configuration variables
# ============================================================================
test_config_variables() {
    local script_content
    script_content=$(command cat "$VALIDATE_SCRIPT")

    # Should have configurable options
    assert_contains "$script_content" "BACKUP" "Should reference backup operations"
}

# ============================================================================
# Test: Backup validation functions
# ============================================================================
test_backup_validation() {
    local script_content
    script_content=$(command cat "$VALIDATE_SCRIPT")

    assert_contains "$script_content" "validate" "Should have validation functionality"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_help_output "Help output is correct"
run_test test_config_variables "Configuration variables present"
run_test test_backup_validation "Backup validation present"

# Generate report
generate_report
