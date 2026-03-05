#!/usr/bin/env bash
# Unit tests for lib/runtime/commands/_wait-for-op-cache
# Tests xtrace protection, ownership check, timeout, preconditions, idempotency

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Wait-For-OP-Cache Helper Tests"

# Path to the script under test
WAIT_SCRIPT="$PROJECT_ROOT/lib/runtime/commands/_wait-for-op-cache"

# ---------------------------------------------------------------------------
# Static analysis tests
# ---------------------------------------------------------------------------

# Test: Idempotency guard via _OP_CACHE_LOADED
test_idempotency_guard() {
    assert_file_contains "$WAIT_SCRIPT" '_OP_CACHE_LOADED' \
        "Should have _OP_CACHE_LOADED idempotency guard"
}

# Test: Xtrace protection on cache sourcing
test_xtrace_protection() {
    assert_file_contains "$WAIT_SCRIPT" 'set +o | command grep xtrace' \
        "Should save xtrace state before sourcing cache"
    assert_file_contains "$WAIT_SCRIPT" '{ set +x; } 2>/dev/null' \
        "Should disable xtrace before sourcing cache"
}

# Test: Ownership check with -O flag
test_ownership_check() {
    assert_file_contains "$WAIT_SCRIPT" '[ -O "$_OP_CACHE" ]' \
        "Should verify file ownership with -O flag"
}

# Test: Timeout value is 60 seconds
test_timeout_value() {
    assert_file_contains "$WAIT_SCRIPT" '_woc_timeout=60' \
        "Should use 60 second timeout"
}

# Test: Uses command -v op to check for op CLI
test_checks_op_installed() {
    assert_file_contains "$WAIT_SCRIPT" 'command -v op' \
        "Should check if op CLI is installed"
}

# Test: Uses compgen -v to detect OP_*_REF variables
test_checks_op_ref_vars() {
    assert_file_contains "$WAIT_SCRIPT" 'compgen -v' \
        "Should use compgen -v to detect OP_*_REF variables"
    assert_file_contains "$WAIT_SCRIPT" 'OP_.\+_REF' \
        "Should grep for OP_*_REF pattern"
}

# Test: Uses full path /usr/bin/sleep
test_full_path_sleep() {
    assert_file_contains "$WAIT_SCRIPT" '/usr/bin/sleep' \
        "Should use full path /usr/bin/sleep"
}

# Test: Checks OP_SERVICE_ACCOUNT_TOKEN before waiting
test_checks_sa_token() {
    assert_file_contains "$WAIT_SCRIPT" 'OP_SERVICE_ACCOUNT_TOKEN' \
        "Should check OP_SERVICE_ACCOUNT_TOKEN before waiting"
}

# Test: Cache path is /dev/shm/op-secrets-cache
test_cache_path() {
    assert_file_contains "$WAIT_SCRIPT" '/dev/shm/op-secrets-cache' \
        "Should use /dev/shm/op-secrets-cache path"
}

# Test: Cleans up internal variables
test_cleanup() {
    assert_file_contains "$WAIT_SCRIPT" 'unset _woc_should_wait _OP_CACHE' \
        "Should clean up internal variables"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
run_test test_idempotency_guard "Idempotency guard via _OP_CACHE_LOADED"
run_test test_xtrace_protection "Xtrace protection on cache sourcing"
run_test test_ownership_check "Ownership check with -O flag"
run_test test_timeout_value "Timeout value is 60 seconds"
run_test test_checks_op_installed "Checks op CLI is installed"
run_test test_checks_op_ref_vars "Detects OP_*_REF variables with compgen"
run_test test_full_path_sleep "Uses full path /usr/bin/sleep"
run_test test_checks_sa_token "Checks OP_SERVICE_ACCOUNT_TOKEN"
run_test test_cache_path "Cache path is /dev/shm/op-secrets-cache"
run_test test_cleanup "Cleans up internal variables"

# Generate test report
generate_report
