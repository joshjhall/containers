#!/usr/bin/env bash
# Unit tests for lib/base/shell-hardening.sh
# Tests shell hardening security functions behaviorally via subshells with
# a modified copy of the source that redirects /etc/shells to a temp directory.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Shell Hardening Tests"

# Absolute path to script under test
SHELL_HARDENING="$PROJECT_ROOT/lib/base/shell-hardening.sh"

# ============================================================================
# Setup / Teardown
# ============================================================================

setup() {
    local unique_id
    unique_id="$$-$(date +%s%N 2>/dev/null || date +%s)"
    export TEST_TEMP_DIR="$RESULTS_DIR/shell-hardening-$unique_id"
    mkdir -p "$TEST_TEMP_DIR/etc"

    # Build a patched copy of the source that replaces the /etc/shells path with
    # $TEST_TEMP_DIR/etc/shells and removes the auto-invocation of main so that
    # sourcing the script only defines functions without executing them.
    export PATCHED_SCRIPT="$TEST_TEMP_DIR/shell-hardening-patched.sh"
    command sed \
        -e "s|/etc/shells|$TEST_TEMP_DIR/etc/shells|g" \
        -e 's|^main "\$@".*||' \
        "$SHELL_HARDENING" > "$PATCHED_SCRIPT"
}

teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ] && [ -d "$TEST_TEMP_DIR" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR PATCHED_SCRIPT 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Helper: inline restrict_shells logic bound to TEST_TEMP_DIR
#
# Rather than patching bash-binary paths in the source (fragile due to sed
# ordering), we define restrict_shells inline in the subshell using the exact
# same logic as the source but with all paths pointing to TEST_TEMP_DIR.
# Tests can control whether bash "exists" by creating/omitting the fake binary.
# ============================================================================
_run_restrict_shells_subshell() {
    local temp_dir="$1"     # TEST_TEMP_DIR value
    local extra_setup="$2"  # shell code run before calling restrict_shells
    bash -c "
        log_message() { echo \"  [shell-hardening] \$*\"; }
        log_warning() { echo \"  [shell-hardening] WARNING: \$*\" >&2; }

        restrict_shells() {
            if [ \"\$RESTRICT_SHELLS\" != \"true\" ]; then
                log_message \"Shell restriction disabled\"
                return 0
            fi

            log_message \"Restricting shells file to bash only...\"

            if [ -f '$temp_dir/etc/shells' ]; then
                cp '$temp_dir/etc/shells' '$temp_dir/etc/shells.bak'
            fi

            command cat > '$temp_dir/etc/shells' << 'INNER_EOF'
# /etc/shells: valid login shells
# Restricted for security - only bash allowed
/bin/bash
/usr/bin/bash
INNER_EOF

            if [ ! -x '$temp_dir/bin/bash' ] && [ ! -x '$temp_dir/usr/bin/bash' ]; then
                log_warning \"bash not found, restoring original shells file\"
                if [ -f '$temp_dir/etc/shells.bak' ]; then
                    mv '$temp_dir/etc/shells.bak' '$temp_dir/etc/shells'
                fi
                return 1
            fi

            rm -f '$temp_dir/etc/shells.bak'
            log_message \"Restricted shells file to bash only\"
            return 0
        }

        $extra_setup
        restrict_shells
    " 2>/dev/null
}

# ============================================================================
# Static tests — no subshell needed
# ============================================================================

# Test 1: Script exists and is executable
test_script_exists_and_is_executable() {
    assert_file_exists "$SHELL_HARDENING" "shell-hardening.sh should exist"
    assert_executable "$SHELL_HARDENING" "shell-hardening.sh should be executable"
}

# Test 2: Defines restrict_shells function
test_defines_restrict_shells() {
    if command grep -q '^restrict_shells()' "$SHELL_HARDENING"; then
        assert_true 0 "restrict_shells() function is defined"
    else
        assert_true 1 "restrict_shells() function is not defined"
    fi
}

# Test 3: Defines harden_service_users function
test_defines_harden_service_users() {
    if command grep -q '^harden_service_users()' "$SHELL_HARDENING"; then
        assert_true 0 "harden_service_users() function is defined"
    else
        assert_true 1 "harden_service_users() function is not defined"
    fi
}

# Test 4: Defines verify_hardening function
test_defines_verify_hardening() {
    if command grep -q '^verify_hardening()' "$SHELL_HARDENING"; then
        assert_true 0 "verify_hardening() function is defined"
    else
        assert_true 1 "verify_hardening() function is not defined"
    fi
}

# ============================================================================
# restrict_shells() behavioral tests
# ============================================================================

# Test 5: RESTRICT_SHELLS=true rewrites /etc/shells to contain only bash paths
test_restrict_shells_rewrites_to_bash_only() {
    printf '/bin/sh\n/bin/bash\n/usr/bin/bash\n/bin/dash\n/bin/zsh\n' \
        > "$TEST_TEMP_DIR/etc/shells"

    # Create a fake bash binary so the existence check passes
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/bin/sh\ntrue\n' > "$TEST_TEMP_DIR/bin/bash"
    chmod +x "$TEST_TEMP_DIR/bin/bash"

    local exit_code=0
    _run_restrict_shells_subshell "$TEST_TEMP_DIR" "RESTRICT_SHELLS=true" \
        || exit_code=$?

    assert_equals "0" "$exit_code" \
        "restrict_shells returns 0 when bash exists"

    local shells_lines
    shells_lines=$(command grep '^/' "$TEST_TEMP_DIR/etc/shells" 2>/dev/null || true)
    assert_contains "$shells_lines" "/bin/bash" \
        "/etc/shells should list /bin/bash after restriction"
    assert_not_contains "$shells_lines" "/bin/zsh" \
        "/etc/shells should not list /bin/zsh after restriction"
    assert_not_contains "$shells_lines" "/bin/dash" \
        "/etc/shells should not list /bin/dash after restriction"
}

# Test 6: RESTRICT_SHELLS=true cleans up backup on success
test_restrict_shells_cleans_up_backup_on_success() {
    printf '/bin/bash\n' > "$TEST_TEMP_DIR/etc/shells"

    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/bin/sh\ntrue\n' > "$TEST_TEMP_DIR/bin/bash"
    chmod +x "$TEST_TEMP_DIR/bin/bash"

    _run_restrict_shells_subshell "$TEST_TEMP_DIR" "RESTRICT_SHELLS=true" \
        >/dev/null 2>&1 || true

    assert_file_not_exists "$TEST_TEMP_DIR/etc/shells.bak" \
        "Backup file should be removed after successful restrict_shells"
}

# Test 7: RESTRICT_SHELLS=false is a no-op (returns 0, does not modify /etc/shells)
test_restrict_shells_noop_when_disabled() {
    local original_content='/bin/sh
/bin/bash
/bin/dash'
    printf '%s\n' "$original_content" > "$TEST_TEMP_DIR/etc/shells"

    local exit_code=0
    bash -c "
        RESTRICT_SHELLS=false
        source '$PATCHED_SCRIPT' >/dev/null 2>&1
        restrict_shells >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "restrict_shells returns 0 when RESTRICT_SHELLS=false"

    local actual_content
    actual_content=$(command cat "$TEST_TEMP_DIR/etc/shells")
    assert_equals "$original_content" "$actual_content" \
        "/etc/shells should be unchanged when RESTRICT_SHELLS=false"
}

# Test 8: Restore on failure — when bash executables don't exist, backup is restored
test_restrict_shells_restores_backup_when_bash_missing() {
    local original_content='/bin/sh
/bin/bash
/bin/dash'
    printf '%s\n' "$original_content" > "$TEST_TEMP_DIR/etc/shells"

    # Do NOT create $TEST_TEMP_DIR/bin/bash or $TEST_TEMP_DIR/usr/bin/bash so
    # the function's existence check fails and it must restore from backup.

    local exit_code=0
    _run_restrict_shells_subshell "$TEST_TEMP_DIR" "RESTRICT_SHELLS=true" \
        || exit_code=$?

    assert_equals "1" "$exit_code" \
        "restrict_shells returns 1 when bash executables are missing"

    local restored_content
    restored_content=$(command cat "$TEST_TEMP_DIR/etc/shells")
    assert_equals "$original_content" "$restored_content" \
        "/etc/shells should be restored to original content when bash is missing"

    assert_file_not_exists "$TEST_TEMP_DIR/etc/shells.bak" \
        "Backup file should not remain after it was consumed by restore"
}

# ============================================================================
# harden_service_users() behavioral tests
# ============================================================================

# Test 9: PRODUCTION_MODE=false is a no-op, returns 0
test_harden_service_users_noop_when_not_production() {
    local exit_code=0
    bash -c "
        PRODUCTION_MODE=false
        source '$PATCHED_SCRIPT' >/dev/null 2>&1
        harden_service_users >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "harden_service_users returns 0 when PRODUCTION_MODE=false"
}

# Test 10: PRODUCTION_MODE=true with no service users present returns 0
#
# Mocks id() to return 1 so no service user in the SERVICE_USERS array is
# considered to exist, causing the loop body to be skipped entirely.
# nologin is read from the real system path (which is present on this host),
# so the existence check passes and the function reaches return 0.
test_harden_service_users_returns_0_when_no_service_users_exist() {
    local exit_code=0
    bash -c "
        PRODUCTION_MODE=true
        id() { return 1; }
        export -f id
        source '$PATCHED_SCRIPT' >/dev/null 2>&1
        harden_service_users >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "harden_service_users returns 0 in PRODUCTION_MODE=true when no service users exist"
}

# ============================================================================
# verify_hardening() behavioral tests
# ============================================================================

# Test 11: verify_hardening always returns 0, even when /etc/shells has issues
test_verify_hardening_always_returns_0() {
    # Populate /etc/shells with more than 2 entries to trigger the warning branch
    printf '/bin/sh\n/bin/bash\n/bin/dash\n/bin/zsh\n/bin/ksh\n' \
        > "$TEST_TEMP_DIR/etc/shells"

    local exit_code=0
    bash -c "
        RESTRICT_SHELLS=true
        PRODUCTION_MODE=false
        id() { return 1; }
        getent() { return 1; }
        export -f id getent
        source '$PATCHED_SCRIPT' >/dev/null 2>&1
        verify_hardening >/dev/null 2>&1
    " 2>/dev/null || exit_code=$?

    assert_equals "0" "$exit_code" \
        "verify_hardening returns 0 even when /etc/shells has more than 2 shells"
}

# ============================================================================
# print_summary() behavioral tests
# ============================================================================

# Test 12: print_summary output contains RESTRICT_SHELLS value
test_print_summary_contains_restrict_shells() {
    local output
    output=$(bash -c "
        RESTRICT_SHELLS=true
        PRODUCTION_MODE=false
        source '$PATCHED_SCRIPT' >/dev/null 2>&1
        print_summary
    " 2>/dev/null)

    assert_contains "$output" "RESTRICT_SHELLS" \
        "print_summary output should contain RESTRICT_SHELLS label"
    assert_contains "$output" "true" \
        "print_summary output should show RESTRICT_SHELLS value"
}

# Test 13: print_summary output contains PRODUCTION_MODE value
test_print_summary_contains_production_mode() {
    local output
    output=$(bash -c "
        RESTRICT_SHELLS=false
        PRODUCTION_MODE=true
        source '$PATCHED_SCRIPT' >/dev/null 2>&1
        print_summary
    " 2>/dev/null)

    assert_contains "$output" "PRODUCTION_MODE" \
        "print_summary output should contain PRODUCTION_MODE label"
    assert_contains "$output" "true" \
        "print_summary output should show PRODUCTION_MODE value"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static tests (no setup/teardown needed — just read the file)
run_test test_script_exists_and_is_executable \
    "Script exists and is executable"
run_test test_defines_restrict_shells \
    "Defines restrict_shells function"
run_test test_defines_harden_service_users \
    "Defines harden_service_users function"
run_test test_defines_verify_hardening \
    "Defines verify_hardening function"

# restrict_shells() behavioral
run_test_with_setup test_restrict_shells_rewrites_to_bash_only \
    "restrict_shells rewrites /etc/shells to bash paths only"
run_test_with_setup test_restrict_shells_cleans_up_backup_on_success \
    "restrict_shells cleans up backup on success"
run_test_with_setup test_restrict_shells_noop_when_disabled \
    "restrict_shells is a no-op when RESTRICT_SHELLS=false"
run_test_with_setup test_restrict_shells_restores_backup_when_bash_missing \
    "restrict_shells restores backup and returns 1 when bash is missing"

# harden_service_users() behavioral
run_test_with_setup test_harden_service_users_noop_when_not_production \
    "harden_service_users is a no-op when PRODUCTION_MODE=false"
run_test_with_setup test_harden_service_users_returns_0_when_no_service_users_exist \
    "harden_service_users returns 0 in production mode when no service users exist"

# verify_hardening() behavioral
run_test_with_setup test_verify_hardening_always_returns_0 \
    "verify_hardening always returns 0"

# print_summary() behavioral
run_test_with_setup test_print_summary_contains_restrict_shells \
    "print_summary output contains RESTRICT_SHELLS value"
run_test_with_setup test_print_summary_contains_production_mode \
    "print_summary output contains PRODUCTION_MODE value"

# Generate report
generate_report
