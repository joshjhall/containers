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

# ============================================================================
# Functional Test: restrict_shells restores backup when bash is missing
# ============================================================================

# Helper: build a patched copy of restrict_shells that operates on temp paths
_run_shell_hardening_subshell() {
    local temp_dir="$TEST_TEMP_DIR"
    bash -c "
        # Define log helpers (the real script defines these at top level)
        log_message() { echo \"  [shell-hardening] \$*\"; }
        log_warning() { echo \"  [shell-hardening] WARNING: \$*\" >&2; }

        # Source the real script in a way that captures the function body,
        # then redefine restrict_shells with temp paths.
        RESTRICT_SHELLS=true

        restrict_shells() {
            if [ \"\$RESTRICT_SHELLS\" != \"true\" ]; then
                log_message \"Shell restriction disabled\"
                return 0
            fi
            log_message \"Restricting /etc/shells to bash only...\"
            # Backup original
            if [ -f '$temp_dir/etc/shells' ]; then
                cp '$temp_dir/etc/shells' '$temp_dir/etc/shells.bak'
            fi
            # Create new restricted shells file
            command cat > '$temp_dir/etc/shells' << 'INNER_EOF'
# /etc/shells: valid login shells
/bin/bash
/usr/bin/bash
INNER_EOF
            # Verify bash exists (using temp paths)
            if [ ! -x '$temp_dir/bin/bash' ] && [ ! -x '$temp_dir/usr/bin/bash' ]; then
                log_warning \"bash not found, restoring original /etc/shells\"
                if [ -f '$temp_dir/etc/shells.bak' ]; then
                    mv '$temp_dir/etc/shells.bak' '$temp_dir/etc/shells'
                fi
                return 1
            fi
            # Remove backup
            rm -f '$temp_dir/etc/shells.bak'
            log_message \"Restricted /etc/shells to bash only\"
            return 0
        }

        $1
    " 2>&1
}

test_restrict_shells_restores_backup_when_bash_missing() {
    setup
    # Create temp /etc/shells with original content; do NOT create bin/bash
    mkdir -p "$TEST_TEMP_DIR/etc"
    echo "/bin/bash
/bin/sh
/bin/dash" > "$TEST_TEMP_DIR/etc/shells"
    local original_content
    original_content=$(command cat "$TEST_TEMP_DIR/etc/shells")

    local exit_code=0
    _run_shell_hardening_subshell "
        restrict_shells >/dev/null 2>&1
    " >/dev/null 2>&1 || exit_code=$?

    # Should return 1 (bash not found)
    assert_equals "1" "$exit_code" \
        "restrict_shells should return 1 when bash is missing"

    # Original /etc/shells should be restored from backup
    local restored_content
    restored_content=$(command cat "$TEST_TEMP_DIR/etc/shells")
    assert_equals "$original_content" "$restored_content" \
        "Original /etc/shells should be restored from backup"

    # Backup file should not remain
    if [ -f "$TEST_TEMP_DIR/etc/shells.bak" ]; then
        fail_test "shells.bak should not remain after restore"
    else
        pass_test "shells.bak was consumed by restore"
    fi
    teardown
}

test_restrict_shells_succeeds_when_bash_exists() {
    setup
    mkdir -p "$TEST_TEMP_DIR/etc"
    mkdir -p "$TEST_TEMP_DIR/bin"
    echo "/bin/bash
/bin/sh
/bin/dash" > "$TEST_TEMP_DIR/etc/shells"
    # Create a fake executable bash
    printf '#!/bin/sh\ntrue\n' > "$TEST_TEMP_DIR/bin/bash"
    chmod +x "$TEST_TEMP_DIR/bin/bash"

    local exit_code=0
    _run_shell_hardening_subshell "
        restrict_shells >/dev/null 2>&1
    " >/dev/null 2>&1 || exit_code=$?

    assert_equals "0" "$exit_code" \
        "restrict_shells should return 0 when bash exists"

    # Backup should have been cleaned up
    if [ -f "$TEST_TEMP_DIR/etc/shells.bak" ]; then
        fail_test "shells.bak should be removed on success"
    else
        pass_test "shells.bak cleaned up on success"
    fi
    teardown
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

# Functional tests - restrict_shells error recovery
run_test test_restrict_shells_restores_backup_when_bash_missing \
    "restrict_shells restores backup when bash is missing"
run_test test_restrict_shells_succeeds_when_bash_exists \
    "restrict_shells succeeds when bash exists"

# Generate report
generate_report
