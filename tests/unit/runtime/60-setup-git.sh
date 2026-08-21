#!/usr/bin/env bash
# Unit tests for lib/runtime/60-setup-git.sh
# Tests the every-boot git identity startup script (issue #785)

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "60-setup-git Startup Script Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/runtime/60-setup-git.sh"

# Setup function
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$RESULTS_DIR/test-setup-git-startup-$unique_id"
    command mkdir -p "$TEST_TEMP_DIR/bin"

    # Stub setup-git so tests never touch the real git config. The stub records
    # each invocation so we can assert on call count.
    command cat >"$TEST_TEMP_DIR/bin/setup-git" <<'STUB'
#!/bin/bash
echo "invoked" >>"${STUB_CALL_LOG}"
exit "${STUB_EXIT_CODE:-0}"
STUB
    command chmod 755 "$TEST_TEMP_DIR/bin/setup-git"

    export STUB_CALL_LOG="$TEST_TEMP_DIR/calls.log"
    : >"$STUB_CALL_LOG"

    # BASH_ENV rebuilds PATH on non-interactive bash and would defeat the stub
    # (see .claude/memory/bash-env-breaks-path-stubs.md).
    unset BASH_ENV 2>/dev/null || true
}

# Teardown function
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR STUB_CALL_LOG STUB_EXIT_CODE SKIP_GIT_SETUP 2>/dev/null || true
}

run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"
    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run the script under test with only the stub dir on PATH.
_run_script() {
    env -u BASH_ENV PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        STUB_CALL_LOG="$STUB_CALL_LOG" \
        ${STUB_EXIT_CODE:+STUB_EXIT_CODE="$STUB_EXIT_CODE"} \
        ${SKIP_GIT_SETUP:+SKIP_GIT_SETUP="$SKIP_GIT_SETUP"} \
        bash "$SOURCE_FILE"
}

_call_count() {
    # grep -c prints 0 AND exits non-zero when there are no matches, so a
    # `|| echo 0` fallback would emit a second line. Count lines instead.
    command grep -c 'invoked' "$STUB_CALL_LOG" 2>/dev/null | command head -1
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "60-setup-git.sh should exist"

    if [ -x "$SOURCE_FILE" ]; then
        pass_test "60-setup-git.sh is executable"
    else
        fail_test "60-setup-git.sh is not executable"
    fi
}

test_syntax_valid() {
    if bash -n "$SOURCE_FILE" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

test_has_skip_gate() {
    assert_file_contains "$SOURCE_FILE" "SKIP_GIT_SETUP" \
        "Script checks SKIP_GIT_SETUP variable"
}

test_documents_ordering_rationale() {
    # The 60- prefix must stay after 45-op-secrets.sh; the comment is the only
    # thing stopping a future renumber from silently reintroducing the race.
    assert_file_contains "$SOURCE_FILE" "45-op-secrets" \
        "Script documents its ordering dependency on 45-op-secrets.sh"
}

test_installed_after_op_secrets() {
    # Guard the actual ordering invariant, not just the prose: the numeric
    # prefix must sort after 45-op-secrets.sh.
    local prefix="${SOURCE_FILE##*/}"
    prefix="${prefix%%-*}"
    if [ "$prefix" -gt 45 ]; then
        pass_test "Startup prefix ($prefix) sorts after 45-op-secrets.sh"
    else
        fail_test "Startup prefix ($prefix) must be > 45 to run after op secrets"
    fi
}

test_dockerfile_installs_script() {
    assert_file_contains "$PROJECT_ROOT/Dockerfile" \
        "/etc/container/startup/60-setup-git.sh" \
        "Dockerfile installs 60-setup-git.sh into the startup directory"
}

# ============================================================================
# Behavioral Tests
# ============================================================================

test_invokes_setup_git() {
    _run_script >/dev/null 2>&1
    local rc=$?
    local calls
    calls=$(_call_count)

    if [ "$rc" -eq 0 ] && [ "$calls" -eq 1 ]; then
        pass_test "Invokes setup-git once and exits 0"
    else
        fail_test "Expected exit 0 and 1 call, got exit $rc and $calls call(s)"
    fi
}

test_skip_gate_works() {
    export SKIP_GIT_SETUP=true
    _run_script >/dev/null 2>&1
    local rc=$?
    local calls
    calls=$(_call_count)

    if [ "$rc" -eq 0 ] && [ "$calls" -eq 0 ]; then
        pass_test "SKIP_GIT_SETUP=true skips setup-git"
    else
        fail_test "Expected exit 0 and 0 calls, got exit $rc and $calls call(s)"
    fi
}

test_missing_setup_git_clean_exit() {
    # setup-git absent from PATH → exit 0, no error
    env -u BASH_ENV PATH="/usr/bin:/bin" bash "$SOURCE_FILE" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        pass_test "Clean exit when setup-git is not installed"
    else
        fail_test "Expected exit 0 when setup-git missing, got $rc"
    fi
}

test_setup_git_failure_non_fatal() {
    # A failing setup-git must not abort container startup.
    export STUB_EXIT_CODE=1
    _run_script >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        pass_test "Exits 0 even when setup-git fails (non-fatal)"
    else
        fail_test "Expected exit 0 on setup-git failure, got $rc"
    fi
}

test_setup_git_failure_warns() {
    export STUB_EXIT_CODE=1
    local err
    err=$(_run_script 2>&1 >/dev/null) || true
    if printf '%s' "$err" | command grep -q 'WARNING'; then
        pass_test "Warns on stderr when setup-git fails"
    else
        fail_test "Expected a WARNING on stderr, got: $err"
    fi
}

test_idempotent() {
    _run_script >/dev/null 2>&1
    local rc1=$?
    _run_script >/dev/null 2>&1
    local rc2=$?
    local calls
    calls=$(_call_count)

    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$calls" -eq 2 ]; then
        pass_test "Idempotent — safe to run on every boot"
    else
        fail_test "Expected exit 0 twice and 2 calls, got $rc1/$rc2 and $calls call(s)"
    fi
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists and is executable"
run_test test_syntax_valid "Script has valid bash syntax"
run_test test_has_skip_gate "Has skip gate for SKIP_GIT_SETUP"
run_test test_documents_ordering_rationale "Documents 45-op-secrets ordering"
run_test test_installed_after_op_secrets "Prefix sorts after op secrets"
run_test test_dockerfile_installs_script "Dockerfile installs the script"

# Behavioral tests
run_test_with_setup test_invokes_setup_git "Invokes setup-git"
run_test_with_setup test_skip_gate_works "Skip gate works"
run_test_with_setup test_missing_setup_git_clean_exit "Missing setup-git → clean exit"
run_test_with_setup test_setup_git_failure_non_fatal "setup-git failure is non-fatal"
run_test_with_setup test_setup_git_failure_warns "setup-git failure warns"
run_test_with_setup test_idempotent "Idempotent (run twice)"

# Generate test report
generate_report
