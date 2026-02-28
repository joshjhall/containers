#!/usr/bin/env bash
# Unit tests for lib/base/shell-hardening.sh
# Tests shell hardening security functions

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Shell Hardening Tests"

# Path to script under test
SHELL_HARDENING="$(dirname "${BASH_SOURCE[0]}")/../../../lib/base/shell-hardening.sh"

# Setup - create temp environment
setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/shell-hardening-test"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# ============================================================================
# Test: Script exists and is executable
# ============================================================================
test_script_exists() {
    assert_file_exists "$SHELL_HARDENING" "shell-hardening.sh should exist"

    if [ -x "$SHELL_HARDENING" ]; then
        pass_test "shell-hardening.sh is executable"
    else
        fail_test "shell-hardening.sh is not executable"
    fi
}

# ============================================================================
# Test: Script has valid syntax
# ============================================================================
test_syntax_valid() {
    if bash -n "$SHELL_HARDENING" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

# ============================================================================
# Test: Required functions are defined
# ============================================================================
test_functions_defined() {
    local script_content
    script_content=$(command cat "$SHELL_HARDENING")

    # Check for key functions
    assert_contains "$script_content" "restrict_shells()" "Should define restrict_shells function"
    assert_contains "$script_content" "harden_service_users()" "Should define harden_service_users function"
    assert_contains "$script_content" "log_message()" "Should define log_message function"
}

# ============================================================================
# Test: Configuration variables have defaults
# ============================================================================
test_config_defaults() {
    local script_content
    script_content=$(command cat "$SHELL_HARDENING")

    assert_contains "$script_content" 'RESTRICT_SHELLS="${RESTRICT_SHELLS:-' "Should have RESTRICT_SHELLS default"
    assert_contains "$script_content" 'PRODUCTION_MODE="${PRODUCTION_MODE:-' "Should have PRODUCTION_MODE default"
}

# ============================================================================
# Test: Service users list is comprehensive
# ============================================================================
test_service_users_list() {
    local script_content
    script_content=$(command cat "$SHELL_HARDENING")

    # Check for common service users
    assert_contains "$script_content" "www-data" "Should include www-data"
    assert_contains "$script_content" "nobody" "Should include nobody"
    assert_contains "$script_content" "_apt" "Should include _apt"
}

# ============================================================================
# Test: Compliance documentation present
# ============================================================================
test_compliance_docs() {
    local script_content
    script_content=$(command cat "$SHELL_HARDENING")

    assert_contains "$script_content" "CIS Docker Benchmark" "Should reference CIS benchmarks"
    assert_contains "$script_content" "NIST 800-53" "Should reference NIST standards"
    assert_contains "$script_content" "PCI DSS" "Should reference PCI DSS"
}

# ============================================================================
# Test: Restricted shells file format
# ============================================================================
test_restricted_shells_format() {
    local script_content
    script_content=$(command cat "$SHELL_HARDENING")

    # Should only allow bash
    assert_contains "$script_content" "/bin/bash" "Should allow /bin/bash"
    assert_contains "$script_content" "/usr/bin/bash" "Should allow /usr/bin/bash"
}

# ============================================================================
# Test: Backup mechanism exists
# ============================================================================
test_backup_mechanism() {
    local script_content
    script_content=$(command cat "$SHELL_HARDENING")

    assert_contains "$script_content" "shells.bak" "Should create backup of /etc/shells"
}

# ============================================================================
# Test: Error handling for missing bash
# ============================================================================
test_bash_verification() {
    local script_content
    script_content=$(command cat "$SHELL_HARDENING")

    assert_contains "$script_content" "bash not found" "Should check for bash existence"
    assert_contains "$script_content" "restoring original" "Should restore on failure"
}

# Run tests
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script syntax is valid"
run_test test_functions_defined "Required functions are defined"
run_test test_config_defaults "Configuration defaults are set"
run_test test_service_users_list "Service users list is comprehensive"
run_test test_compliance_docs "Compliance documentation present"
run_test test_restricted_shells_format "Restricted shells format correct"
run_test test_backup_mechanism "Backup mechanism exists"
run_test test_bash_verification "Bash verification exists"

# Generate report
generate_report
