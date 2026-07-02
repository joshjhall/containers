#!/usr/bin/env bash
# Unit tests for the fixed-purpose chown wrappers used by command-scoped sudo
# (lib/runtime/commands/reconcile-cache-owner and reconcile-run-owner, issue
# #675). These wrappers are what make the scoped sudoers grant safe: the sudoers
# rule allows the wrapper with a wildcard (`reconcile-cache-owner *`), so the
# wrapper itself MUST reject anything that isn't a bare numeric <uid> <gid> —
# otherwise a caller could smuggle extra chown operands/options through it.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Reconcile Owner Wrapper Tests"

CACHE_WRAPPER="$PROJECT_ROOT/lib/runtime/commands/reconcile-cache-owner"
RUN_WRAPPER="$PROJECT_ROOT/lib/runtime/commands/reconcile-run-owner"

# ============================================================================
# Test: wrappers exist and are executable
# ============================================================================
test_wrappers_exist() {
    assert_file_exists "$CACHE_WRAPPER"
    assert_executable "$CACHE_WRAPPER"
    assert_file_exists "$RUN_WRAPPER"
    assert_executable "$RUN_WRAPPER"
}

# ============================================================================
# Test: wrappers hardcode their target path and never accept it as an argument
# ============================================================================
test_wrappers_hardcode_target() {
    assert_file_contains "$CACHE_WRAPPER" 'TARGET="/cache"' \
        "cache wrapper hardcodes /cache"
    assert_file_contains "$RUN_WRAPPER" 'TARGET="/run"' \
        "run wrapper hardcodes /run"
    # The path must not be interpolated from a positional argument.
    assert_file_not_contains "$CACHE_WRAPPER" 'TARGET="$3"' \
        "cache wrapper does not take target from args"
}

# ============================================================================
# Helper: run a wrapper and capture only its exit code (never actually chowns
# because /cache//run either don't exist in CI or aren't ours — the arg gate
# fires before the privileged chown regardless).
# ============================================================================
wrapper_rc() {
    local wrapper="$1"
    shift
    "$wrapper" "$@" >/dev/null 2>&1
    echo "$?"
}

# ============================================================================
# Test: extra arguments are rejected (can't smuggle a second chown operand)
# ============================================================================
test_reject_extra_args() {
    assert_equals "2" "$(wrapper_rc "$CACHE_WRAPPER" 1000 1000 /etc/passwd)" \
        "cache wrapper rejects a third argument"
    assert_equals "2" "$(wrapper_rc "$RUN_WRAPPER" 1000 1000 extra)" \
        "run wrapper rejects a third argument"
}

# ============================================================================
# Test: missing arguments are rejected
# ============================================================================
test_reject_missing_args() {
    assert_equals "2" "$(wrapper_rc "$CACHE_WRAPPER" 1000)" \
        "cache wrapper rejects a single argument"
    assert_equals "2" "$(wrapper_rc "$RUN_WRAPPER")" \
        "run wrapper rejects no arguments"
}

# ============================================================================
# Test: non-numeric uid/gid are rejected — this is the core injection guard.
# An option like -R or a path like /etc must never reach chown.
# ============================================================================
test_reject_non_numeric() {
    assert_equals "2" "$(wrapper_rc "$CACHE_WRAPPER" -R 1000)" \
        "cache wrapper rejects an option in place of uid"
    assert_equals "2" "$(wrapper_rc "$CACHE_WRAPPER" 1000 /etc)" \
        "cache wrapper rejects a path in place of gid"
    assert_equals "2" "$(wrapper_rc "$CACHE_WRAPPER" "1000 /etc/passwd" 1000)" \
        "cache wrapper rejects a smuggled operand in uid"
    assert_equals "2" "$(wrapper_rc "$RUN_WRAPPER" root root)" \
        "run wrapper rejects symbolic names"
    assert_equals "2" "$(wrapper_rc "$RUN_WRAPPER" 1000 --)" \
        "run wrapper rejects an option in place of gid"
}

# ============================================================================
# Test: valid numeric args pass the gate (exit 0 when target absent, or the
# chown's own rc). We assert the arg gate did NOT reject them (rc != 2).
# ============================================================================
test_accept_numeric_args() {
    local rc
    rc="$(wrapper_rc "$CACHE_WRAPPER" 1000 1000)"
    if [ "$rc" = "2" ]; then
        assert_true false "cache wrapper wrongly rejected valid numeric uid:gid"
    else
        assert_true true "cache wrapper accepts numeric uid:gid (rc=$rc)"
    fi
}

# Run tests
run_test test_wrappers_exist "Wrappers exist and are executable"
run_test test_wrappers_hardcode_target "Wrappers hardcode their target path"
run_test test_reject_extra_args "Reject extra arguments"
run_test test_reject_missing_args "Reject missing arguments"
run_test test_reject_non_numeric "Reject non-numeric uid/gid (injection guard)"
run_test test_accept_numeric_args "Accept valid numeric uid:gid"

# Generate test report
generate_report
