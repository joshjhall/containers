#!/usr/bin/env bash
# Unit tests for bin/healthcheck.sh
# Tests container health check script functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Healthcheck Script Tests"

# Path to the script under test
SOURCE_FILE="$PROJECT_ROOT/bin/healthcheck.sh"

# Setup function - runs before each test (overrides framework setup)
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="$TEST_SCRATCH_BASE/test-healthcheck-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test (overrides framework teardown)
teardown() {
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Wrapper for running tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# ============================================================================
# Static analysis tests
# ============================================================================

# Test: Script exists and is executable
test_script_exists() {
    assert_file_exists "$SOURCE_FILE" "healthcheck.sh should exist"

    if [ -x "$SOURCE_FILE" ]; then
        pass_test "healthcheck.sh is executable"
    else
        fail_test "healthcheck.sh is not executable"
    fi
}

# Test: Script has valid bash syntax
test_syntax_valid() {
    if bash -n "$SOURCE_FILE" 2>&1; then
        pass_test "Script has valid bash syntax"
    else
        fail_test "Script has syntax errors"
    fi
}

# Test: Script uses strict mode
test_strict_mode() {
    assert_file_contains "$SOURCE_FILE" "set -euo pipefail" \
        "healthcheck.sh should use strict mode"
}

# Test: Defines check_core function
test_defines_check_core() {
    assert_file_contains "$SOURCE_FILE" "check_core()" \
        "Should define check_core function"
}

# Test: Defines check_python function
test_defines_check_python() {
    assert_file_contains "$SOURCE_FILE" "check_python()" \
        "Should define check_python function"
}

# Test: Defines check_node function
test_defines_check_node() {
    assert_file_contains "$SOURCE_FILE" "check_node()" \
        "Should define check_node function"
}

# Test: Defines check_rust function
test_defines_check_rust() {
    assert_file_contains "$SOURCE_FILE" "check_rust()" \
        "Should define check_rust function"
}

# Test: Defines check_golang function
test_defines_check_golang() {
    assert_file_contains "$SOURCE_FILE" "check_golang()" \
        "Should define check_golang function"
}

# Test: Defines check_ruby function
test_defines_check_ruby() {
    assert_file_contains "$SOURCE_FILE" "check_ruby()" \
        "Should define check_ruby function"
}

# Test: Defines check_r function
test_defines_check_r() {
    assert_file_contains "$SOURCE_FILE" "check_r()" \
        "Should define check_r function"
}

# Test: Defines check_java function
test_defines_check_java() {
    assert_file_contains "$SOURCE_FILE" "check_java()" \
        "Should define check_java function"
}

# Test: Defines check_docker function
test_defines_check_docker() {
    assert_file_contains "$SOURCE_FILE" "check_docker()" \
        "Should define check_docker function"
}

# Test: Defines check_kubernetes function
test_defines_check_kubernetes() {
    assert_file_contains "$SOURCE_FILE" "check_kubernetes()" \
        "Should define check_kubernetes function"
}

# Test: Defines run_custom_checks function
test_defines_run_custom_checks() {
    assert_file_contains "$SOURCE_FILE" "run_custom_checks()" \
        "Should define run_custom_checks function"
}

# Test: Defines auto_detect_features function
test_defines_auto_detect_features() {
    assert_file_contains "$SOURCE_FILE" "auto_detect_features()" \
        "Should define auto_detect_features function"
}

# Test: Defines log_check function
test_defines_log_check() {
    assert_file_contains "$SOURCE_FILE" "log_check()" \
        "Should define log_check function"
}

# Test: Defines log_pass function
test_defines_log_pass() {
    assert_file_contains "$SOURCE_FILE" "log_pass()" \
        "Should define log_pass function"
}

# Test: Defines log_fail function
test_defines_log_fail() {
    assert_file_contains "$SOURCE_FILE" "log_fail()" \
        "Should define log_fail function"
}

# Test: Defines log_warn function
test_defines_log_warn() {
    assert_file_contains "$SOURCE_FILE" "log_warn()" \
        "Should define log_warn function"
}

# Test: Supports --quick mode parsing
test_quick_mode_parsing() {
    assert_file_contains "$SOURCE_FILE" -- "--quick)" \
        "Should handle --quick argument"
    assert_file_contains "$SOURCE_FILE" "QUICK_MODE=true" \
        "Should set QUICK_MODE to true"
}

# Test: Supports --verbose mode parsing
test_verbose_mode_parsing() {
    assert_file_contains "$SOURCE_FILE" -- "--verbose)" \
        "Should handle --verbose argument"
    assert_file_contains "$SOURCE_FILE" "VERBOSE=true" \
        "Should set VERBOSE to true"
}

# Test: Supports --feature mode parsing
test_feature_mode_parsing() {
    assert_file_contains "$SOURCE_FILE" -- "--feature)" \
        "Should handle --feature argument"
    assert_file_contains "$SOURCE_FILE" "SPECIFIC_FEATURE=" \
        "Should set SPECIFIC_FEATURE variable"
}

# Test: CUSTOM_CHECKS_DIR variable is defined
test_custom_checks_dir_defined() {
    assert_file_contains "$SOURCE_FILE" "CUSTOM_CHECKS_DIR=" \
        "Should define CUSTOM_CHECKS_DIR variable"
    assert_file_contains "$SOURCE_FILE" "HEALTHCHECK_CUSTOM_DIR" \
        "Should reference HEALTHCHECK_CUSTOM_DIR env variable"
}

# Test: EXIT_CODE variable is used for tracking failures
test_exit_code_variable() {
    assert_file_contains "$SOURCE_FILE" "EXIT_CODE=0" \
        "Should initialize EXIT_CODE to 0"
    assert_file_contains "$SOURCE_FILE" "EXIT_CODE=1" \
        "Should set EXIT_CODE to 1 on failures"
}

# ============================================================================
# Functional tests
# ============================================================================

# Test: --help flag outputs usage information
test_help_flag_output() {
    local output
    output=$(bash "$SOURCE_FILE" --help 2>&1) || true

    assert_contains "$output" "Usage:" "Help flag should show usage"
    assert_contains "$output" "--quick" "Help should mention --quick option"
    assert_contains "$output" "--verbose" "Help should mention --verbose option"
    assert_contains "$output" "--feature" "Help should mention --feature option"
}

# Test: --help flag exits with code 0
test_help_flag_exit_code() {
    local exit_code=0
    bash "$SOURCE_FILE" --help >/dev/null 2>&1 || exit_code=$?
    assert_equals "0" "$exit_code" "Help flag should exit with code 0"
}

# Test: Unknown option returns exit 1
test_unknown_option_exits_1() {
    local exit_code=0
    bash "$SOURCE_FILE" --nonexistent-option 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Unknown option should exit with code 1"
}

# Test: Unknown feature returns exit 1
test_unknown_feature_exits_1() {
    local exit_code=0
    bash "$SOURCE_FILE" --feature nonexistent_feature 2>/dev/null || exit_code=$?
    assert_equals "1" "$exit_code" "Unknown feature should exit with code 1"
}

# ============================================================================
# Container-user resolution (issue #995)
# ============================================================================

# Stub getent/id for a passwd whose only regular user is vscode at UID 501
# (Zed's host-UID remap on macOS), then run `healthcheck --feature core
# --verbose`. Echoes the output. $1 = uid the stub `id -u` reports; $2 = the
# user's passwd home (the resolver's shape rule only accepts a /home/ home).
run_core_with_uid501_passwd() {
    local as_uid="$1"
    local home="${2:-$TEST_TEMP_DIR/home/vscode}"
    local stub_dir="$TEST_TEMP_DIR/stubs"
    command mkdir -p "$stub_dir" "$TEST_TEMP_DIR/home/vscode"
    command cat >"$TEST_TEMP_DIR/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
vscode:x:501:20::$home:/bin/bash
EOF
    command touch "$TEST_TEMP_DIR/home/vscode/.container-initialized"
    command cat >"$stub_dir/getent" <<EOF
#!/bin/bash
[ "\${1:-}" = "passwd" ] || exit 2
if [ -n "\${2:-}" ]; then
    /usr/bin/awk -F: -v k="\$2" '\$1 == k || \$3 == k { print; f=1 } END { exit !f }' "$TEST_TEMP_DIR/passwd"
else
    /usr/bin/cat "$TEST_TEMP_DIR/passwd"
fi
EOF
    command cat >"$stub_dir/id" <<EOF
#!/bin/bash
case "\${1:-}" in
    -u) echo $as_uid ;;
    -un) echo vscode ;;
    *) exec /usr/bin/id "\$@" ;;
esac
EOF
    command chmod +x "$stub_dir/getent" "$stub_dir/id"
    (
        export BASH_ENV=""
        export PATH="$stub_dir:$PATH"
        unset CONTAINER_UID
        export HEALTHCHECK_RUNTIME_LIB="$PROJECT_ROOT/lib/runtime/lib"
        bash "$SOURCE_FILE" --feature core --verbose 2>&1
    ) || true
}

# Test: root invocation resolves a non-1000 user via the shared resolver
test_core_resolves_uid501_as_root() {
    local output
    output=$(run_core_with_uid501_passwd 0 /home/vscode)
    assert_contains "$output" "Container user: vscode" \
        "Resolves the UID-501 user by shape (no hardcoded 1000)"
    assert_not_contains "$output" "No user with UID 1000" \
        "Does not fail on the old hardcoded UID 1000 lookup"
}

# Test: non-root invocation (the Docker HEALTHCHECK) uses the running user
test_core_resolves_uid501_as_user() {
    local output
    output=$(run_core_with_uid501_passwd 501)
    assert_contains "$output" "Container user: vscode" \
        "Non-root healthcheck identifies the running user"
    assert_contains "$output" "Container initialized" \
        "Finds the init marker in the user's passwd home dir"
}

# Root, no resolver lib (script run outside the image). $1 = CONTAINER_UID
# value or "" for unset. Reuses the UID-501 passwd stubs above.
run_core_root_without_lib() {
    local cuid="$1"
    run_core_with_uid501_passwd 0 /home/vscode >/dev/null
    (
        export BASH_ENV=""
        export PATH="$TEST_TEMP_DIR/stubs:$PATH"
        export HEALTHCHECK_RUNTIME_LIB="$TEST_TEMP_DIR/no-such-lib"
        if [ -n "$cuid" ]; then export CONTAINER_UID="$cuid"; else unset CONTAINER_UID; fi
        bash "$SOURCE_FILE" --feature core --verbose 2>&1
    ) || true
}

# Test: without the resolver, an explicit CONTAINER_UID is honored
test_core_no_lib_honors_container_uid() {
    local output
    output=$(run_core_root_without_lib 501)
    assert_contains "$output" "Container user: vscode" \
        "No-lib fallback resolves the explicit CONTAINER_UID"
}

# Test: without the resolver and without CONTAINER_UID, fail loudly rather
# than defaulting to UID 1000 (the #995 bug). A 1000 user exists in this
# fixture precisely so a silent default would resolve and mask the failure.
test_core_no_lib_no_uid_fails() {
    local output rc=0
    run_core_with_uid501_passwd 0 /home/vscode >/dev/null
    command printf 'olduser:x:1000:1000::/home/olduser:/bin/bash\n' >>"$TEST_TEMP_DIR/passwd"
    output=$(
        export BASH_ENV=""
        export PATH="$TEST_TEMP_DIR/stubs:$PATH"
        export HEALTHCHECK_RUNTIME_LIB="$TEST_TEMP_DIR/no-such-lib"
        unset CONTAINER_UID
        bash "$SOURCE_FILE" --feature core --verbose 2>&1
    ) || rc=$?
    assert_not_equals "0" "$rc" "Unresolvable user makes the healthcheck fail"
    assert_contains "$output" "Could not determine the container user" \
        "Reports the resolution failure"
    assert_not_contains "$output" "Container user: olduser" \
        "Does not silently default to UID 1000"
}

# ============================================================================
# Run all tests
# ============================================================================
run_test_with_setup test_script_exists "Script exists and is executable"
run_test_with_setup test_syntax_valid "Script syntax is valid"
run_test_with_setup test_strict_mode "Script uses set -euo pipefail"
run_test_with_setup test_defines_check_core "Defines check_core function"
run_test_with_setup test_defines_check_python "Defines check_python function"
run_test_with_setup test_defines_check_node "Defines check_node function"
run_test_with_setup test_defines_check_rust "Defines check_rust function"
run_test_with_setup test_defines_check_golang "Defines check_golang function"
run_test_with_setup test_defines_check_ruby "Defines check_ruby function"
run_test_with_setup test_defines_check_r "Defines check_r function"
run_test_with_setup test_defines_check_java "Defines check_java function"
run_test_with_setup test_defines_check_docker "Defines check_docker function"
run_test_with_setup test_defines_check_kubernetes "Defines check_kubernetes function"
run_test_with_setup test_defines_run_custom_checks "Defines run_custom_checks function"
run_test_with_setup test_defines_auto_detect_features "Defines auto_detect_features function"
run_test_with_setup test_defines_log_check "Defines log_check function"
run_test_with_setup test_defines_log_pass "Defines log_pass function"
run_test_with_setup test_defines_log_fail "Defines log_fail function"
run_test_with_setup test_defines_log_warn "Defines log_warn function"
run_test_with_setup test_quick_mode_parsing "Supports --quick mode parsing"
run_test_with_setup test_verbose_mode_parsing "Supports --verbose mode parsing"
run_test_with_setup test_feature_mode_parsing "Supports --feature mode parsing"
run_test_with_setup test_custom_checks_dir_defined "CUSTOM_CHECKS_DIR is defined"
run_test_with_setup test_exit_code_variable "EXIT_CODE variable tracks failures"
run_test_with_setup test_help_flag_output "Help flag outputs usage information"
run_test_with_setup test_help_flag_exit_code "Help flag exits with code 0"
run_test_with_setup test_unknown_option_exits_1 "Unknown option returns exit 1"
run_test_with_setup test_unknown_feature_exits_1 "Unknown feature returns exit 1"
run_test_with_setup test_core_resolves_uid501_as_root "Root: resolves UID-501 user via shared resolver (#995)"
run_test_with_setup test_core_resolves_uid501_as_user "Non-root: uses the running user (#995)"
run_test_with_setup test_core_no_lib_honors_container_uid "No resolver lib: honors CONTAINER_UID"
run_test_with_setup test_core_no_lib_no_uid_fails "No resolver lib, no CONTAINER_UID: fails, no 1000 default (#995)"

# Generate test report
generate_report
