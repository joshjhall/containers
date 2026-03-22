#!/usr/bin/env bash
# Unit tests for lib/features/lib/op-cli/45-op-secrets.sh
# Tests error paths and graceful failure behavior

set -euo pipefail

# Source test framework (4 levels up)
source "$(dirname "${BASH_SOURCE[0]}")/../../../../framework.sh"
init_test_framework
test_suite "45-op-secrets Error Path Tests"

# Path to script under test
SOURCE_FILE="$PROJECT_ROOT/lib/features/lib/op-cli/45-op-secrets.sh"

# ============================================================================
# Script Structure Tests
# ============================================================================

test_script_exists_and_executable() {
    assert_file_exists "$SOURCE_FILE"
    [ -x "$SOURCE_FILE" ] \
        && assert_true 0 "45-op-secrets.sh is executable" \
        || assert_true 1 "45-op-secrets.sh should be executable"
}

test_uses_set_plus_e() {
    # This script intentionally uses set +e for graceful failure
    assert_file_contains "$SOURCE_FILE" "set +e" \
        "45-op-secrets.sh uses set +e (graceful failure by design)"
}

# ============================================================================
# Error Path 1: No op binary
# ============================================================================

test_op_binary_guard() {
    # Must check for op binary and exit 0 if not found
    assert_file_contains "$SOURCE_FILE" "command -v op" \
        "45-op-secrets.sh checks for op binary via command -v"
}

test_op_binary_guard_exits_zero() {
    # The guard should exit 0 (not fail) when op is missing
    if command grep -q 'command -v op.*exit 0' "$SOURCE_FILE"; then
        pass_test "op binary guard exits 0 when op not found"
    else
        fail_test "op binary guard should exit 0 when op not found"
    fi
}

# ============================================================================
# Error Path 2: No service account token
# ============================================================================

test_service_account_token_guard() {
    # Must check OP_SERVICE_ACCOUNT_TOKEN and exit 0 if empty
    assert_file_contains "$SOURCE_FILE" "OP_SERVICE_ACCOUNT_TOKEN" \
        "45-op-secrets.sh checks OP_SERVICE_ACCOUNT_TOKEN"
}

test_service_account_token_exits_zero() {
    # The guard should exit 0 (not fail) when token is empty
    if command grep -q 'OP_SERVICE_ACCOUNT_TOKEN.*exit 0' "$SOURCE_FILE"; then
        pass_test "Service account token guard exits 0 when token empty"
    else
        fail_test "Service account token guard should exit 0 when token empty"
    fi
}

# ============================================================================
# Error Path 3: op read failure handled gracefully
# ============================================================================

test_op_read_in_conditional() {
    # op read must be inside an if conditional, not bare (failure handled)
    if command grep -q 'if _secret_value=\$(op read' "$SOURCE_FILE"; then
        pass_test "op read is inside if conditional (failure handled gracefully)"
    else
        fail_test "op read should be inside if conditional, not bare"
    fi
}

test_op_read_stderr_suppressed() {
    # op read stderr must be suppressed to avoid noisy errors
    assert_file_contains "$SOURCE_FILE" 'op read.*2>/dev/null' \
        "op read stderr is suppressed (2>/dev/null)"
}

test_file_ref_op_read_in_conditional() {
    # FILE_REF loop also uses conditional op read
    # There should be at least 2 'if _secret_value=$(op read' lines (REF + FILE_REF)
    local count
    count=$(command grep -c 'if _secret_value=\$(op read' "$SOURCE_FILE" || true)
    [ "$count" -ge 2 ] \
        && assert_true 0 "Both REF and FILE_REF loops use conditional op read (found $count)" \
        || assert_true 1 "Expected at least 2 conditional op read patterns, found $count"
}

# ============================================================================
# Security: xtrace protection
# ============================================================================

test_xtrace_disabled_during_processing() {
    assert_file_contains "$SOURCE_FILE" "set +x" \
        "Xtrace disabled during secret processing"
}

test_xtrace_restored_after_processing() {
    # Must restore xtrace state via boolean flag (no eval)
    assert_file_contains "$SOURCE_FILE" '_xtrace_was_on=false' \
        "Xtrace state captured via boolean flag"
    assert_file_contains "$SOURCE_FILE" 'if \[ "\$_xtrace_was_on" = true \]; then set -x; fi' \
        "Xtrace state restored via boolean flag"
}

# ============================================================================
# Cache: atomic write
# ============================================================================

test_cache_atomic_write() {
    # Cache must be written atomically via .tmp.$$ + mv
    if command grep -Fq '.tmp.$$' "$SOURCE_FILE"; then
        pass_test "Cache uses .tmp.\$\$ for atomic write"
    else
        fail_test "Cache should use .tmp.\$\$ for atomic write"
    fi
    if command grep -q 'mv .*_cache_tmp.*_cache_file' "$SOURCE_FILE"; then
        pass_test "Cache uses mv for atomic rename"
    else
        fail_test "Cache should use mv for atomic rename"
    fi
}

# ============================================================================
# Exit behavior
# ============================================================================

test_exits_zero_on_completion() {
    # Script must end with exit 0
    local last_code_line
    last_code_line=$(command grep -n '^exit' "$SOURCE_FILE" | command tail -1)
    echo "$last_code_line" | command grep -q 'exit 0' \
        && assert_true 0 "Script ends with exit 0" \
        || assert_true 1 "Script should end with exit 0"
}

run_test test_script_exists_and_executable "Script exists and is executable"
run_test test_uses_set_plus_e "Uses set +e (graceful failure by design)"
run_test test_op_binary_guard "Error path 1: checks for op binary"
run_test test_op_binary_guard_exits_zero "Error path 1: exits 0 when op not found"
run_test test_service_account_token_guard "Error path 2: checks OP_SERVICE_ACCOUNT_TOKEN"
run_test test_service_account_token_exits_zero "Error path 2: exits 0 when token empty"
run_test test_op_read_in_conditional "Error path 3: op read in if conditional"
run_test test_op_read_stderr_suppressed "Error path 3: op read stderr suppressed"
run_test test_file_ref_op_read_in_conditional "Error path 3: FILE_REF loop also uses conditional op read"
run_test test_xtrace_disabled_during_processing "Xtrace disabled during secret processing"
run_test test_xtrace_restored_after_processing "Xtrace restored after processing"
run_test test_cache_atomic_write "Cache written atomically (.tmp + mv)"
run_test test_exits_zero_on_completion "Exit 0 on completion"

generate_report
