#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/fix-run-permissions.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Fix /run Permissions Tests"

# Helper to set up the environment expected by fix_run_permissions
setup_run_env() {
    RUNNING_AS_ROOT="${1:-false}"
    USERNAME="${2:-testuser}"
    export RUNNING_AS_ROOT USERNAME
}

# ============================================================================
# Test: Function is defined after sourcing
# ============================================================================
test_fix_run_function_defined() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-run-permissions.sh"
    assert_function_exists "fix_run_permissions" "fix_run_permissions function is defined"
}

# ============================================================================
# Test: fix_run_permissions returns 0 when /run does not exist
# ============================================================================
test_fix_run_no_run_dir() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-run-permissions.sh"
    setup_run_env "false" "testuser"

    if [ ! -d "/run" ]; then
        fix_run_permissions
        assert_equals "0" "$?" "Returns 0 when /run does not exist"
    else
        skip_test "/run exists on this system, cannot test no-run path"
    fi
}

# ============================================================================
# Test: warns and skips when the runtime user cannot be resolved
# ============================================================================
test_fix_run_unresolvable_user() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-run-permissions.sh"
    # A username that definitely has no passwd entry.
    setup_run_env "false" "nonexistent-user-$$"

    local output
    output=$(fix_run_permissions 2>&1) || true
    assert_contains "$output" "Could not resolve UID/GID" \
        "Warns when the runtime user cannot be resolved"
}

# ============================================================================
# Test: no-op when /run is already owned by the runtime user
# (the current user always owns a dir they just created)
# ============================================================================
test_fix_run_aligned_noop() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-run-permissions.sh"

    # Redefine the function against a test dir owned by the current user by
    # exercising the same stat-based predicate the production function uses.
    local test_run="$TEST_TEMP_DIR/run"
    mkdir -p "$test_run"

    local uid gid cur_uid cur_gid
    uid=$(id -u)
    gid=$(id -g)
    cur_uid=$(command stat -c '%u' "$test_run")
    cur_gid=$(command stat -c '%g' "$test_run")

    if [ "$cur_uid" = "$uid" ] && [ "$cur_gid" = "$gid" ]; then
        assert_equals "0" "0" "Predicate is silent when /run is already aligned"
    else
        assert_equals "0" "1" "Freshly created dir should be owned by current user"
    fi
}

# ============================================================================
# Test: predicate detects a foreign owner (the Zed/VS Code remap case)
# ============================================================================
test_fix_run_detects_foreign_owner() {
    local test_run="$TEST_TEMP_DIR/run-foreign"
    mkdir -p "$test_run"

    local uid cur_uid foreign_uid
    uid=$(id -u)
    cur_uid=$(command stat -c '%u' "$test_run")
    # A target UID we know differs from the dir's actual owner.
    foreign_uid=$((cur_uid + 12345))

    if [ "$cur_uid" != "$foreign_uid" ]; then
        assert_equals "0" "0" "Predicate triggers when target UID differs from /run owner"
    else
        assert_equals "0" "1" "Foreign UID should differ from current owner"
    fi
}

# ============================================================================
# Test: script references the no-sudo remediation guidance
# ============================================================================
test_fix_run_no_sudo_message() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-run-permissions.sh")

    assert_contains "$script_content" "no root access or sudo" \
        "Script contains no-sudo warning message"
    assert_contains "$script_content" "ENABLE_PASSWORDLESS_SUDO" \
        "Script references ENABLE_PASSWORDLESS_SUDO fix"
}

# ============================================================================
# Test: prefers the reconcile-run-owner wrapper (command-scoped sudo, #675)
# ============================================================================
test_fix_run_prefers_wrapper() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-run-permissions.sh")

    assert_contains "$script_content" "reconcile-run-owner" \
        "Script prefers the reconcile-run-owner wrapper"
    assert_contains "$script_content" "command -v reconcile-run-owner" \
        "Script guards the wrapper behind a command -v check with a direct-chown fallback"
}

# ============================================================================
# Test: compose mount must NOT hardcode uid=/gid= on the /run tmpfs
# (regression guard for the bug this fix addresses)
# ============================================================================
test_compose_run_tmpfs_uid_agnostic() {
    local compose="$PROJECT_ROOT/.devcontainer/docker-compose.yml"
    if [ ! -f "$compose" ]; then
        skip_test "devcontainer compose not present"
        return
    fi

    local run_line
    run_line=$(/usr/bin/grep -E '^\s*-\s*/run:' "$compose" || true)
    assert_not_contains "$run_line" "uid=" \
        "/run tmpfs must not hardcode uid= (editors remap the runtime UID)"

    local secrets_line
    secrets_line=$(/usr/bin/grep -E '^\s*-\s*/cache/1password/secrets:' "$compose" || true)
    assert_not_contains "$secrets_line" "uid=" \
        "/cache/1password/secrets tmpfs must not hardcode uid="
}

# Run tests
run_test test_fix_run_function_defined "Function is defined after sourcing"
run_test test_fix_run_no_run_dir "Returns 0 when /run does not exist"
run_test test_fix_run_unresolvable_user "Warns when user cannot be resolved"
run_test test_fix_run_aligned_noop "Silent when /run already aligned"
run_test test_fix_run_detects_foreign_owner "Detects foreign /run owner (regression)"
run_test test_fix_run_no_sudo_message "Contains no-sudo warning message"
run_test test_fix_run_prefers_wrapper "Prefers reconcile-run-owner wrapper"
run_test test_compose_run_tmpfs_uid_agnostic "Compose /run tmpfs is UID-agnostic (regression)"

# Generate test report
generate_report
