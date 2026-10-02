#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/privileged.sh (can_run_privileged, issue #996)
#
# The regression: every reconcile step probed with `sudo -n true`, which the
# command-scoped sudoers grant (ENABLE_PASSWORDLESS_SUDO=scoped) refuses, so the
# steps warn-and-skipped while the exact commands they needed were allowed.
# These tests drive the probe against a stub `sudo` that implements the scoped
# CONTAINER_STARTUP allowlist from lib/base/sudoers.sh: `-n -l <cmd...>` answers
# 0 only for an allowlisted command line, and `-n true` is refused.

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Privilege Probe Tests"

# Stub sudo implementing the scoped allowlist. Records each invocation to
# $STUB_DIR/calls so tests can tell "answered yes" from "never asked".
# $1 = stub dir
write_scoped_sudo_stub() {
    local stub_dir="$1"
    command cat >"$stub_dir/sudo" <<'STUB_EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$(dirname "$0")/calls"
[ "${1:-}" = "-n" ] || exit 1
shift
if [ "${1:-}" = "-l" ]; then
    shift
    case "$*" in
        "chown root:docker /var/run/docker.sock" | \
            "chmod 660 /var/run/docker.sock" | \
            "groupadd docker" | \
            "reconcile-cache-owner "* | \
            "reconcile-run-owner "* | \
            "bindfs "*)
            exit 0
            ;;
    esac
    exit 1
fi
# Not `-l`: only the allowlist may actually run; `true` is not on it.
exit 1
STUB_EOF
    command chmod +x "$stub_dir/sudo"
}

# Run can_run_privileged in a clean subshell with the stub dir first on PATH.
# BASH_ENV is cleared so /etc/bash_env can't rebuild PATH and hide the stub.
# $1 = stub dir, $2 = RUNNING_AS_ROOT, rest = command to probe
probe() {
    local stub_dir="$1" as_root="$2"
    shift 2
    (
        export BASH_ENV=""
        export PATH="$stub_dir"
        export RUNNING_AS_ROOT="$as_root"
        unset _PRIVILEGED_LOADED
        # shellcheck source=/dev/null
        source "$PROJECT_ROOT/lib/runtime/lib/privileged.sh"
        can_run_privileged "$@"
    )
}

# ============================================================================
# Test: scoped sudo — the exact allowlisted command is reported runnable
# ============================================================================
test_scoped_allows_exact_command() {
    local stub_dir rc=0
    stub_dir=$(command mktemp -d)
    write_scoped_sudo_stub "$stub_dir"

    probe "$stub_dir" false chown root:docker /var/run/docker.sock || rc=$?
    assert_equals "0" "$rc" "scoped sudo permits the pinned socket chown"

    rc=0
    probe "$stub_dir" false reconcile-cache-owner 1000 1000 || rc=$?
    assert_equals "0" "$rc" "scoped sudo permits the cache reconcile wrapper"

    rc=0
    probe "$stub_dir" false bindfs --version || rc=$?
    assert_equals "0" "$rc" "scoped sudo permits bindfs"

    command rm -rf "$stub_dir"
}

# ============================================================================
# Test: the old probe would have failed under the same stub (the #996 bug)
# ============================================================================
test_scoped_refuses_true() {
    local stub_dir rc=0
    stub_dir=$(command mktemp -d)
    write_scoped_sudo_stub "$stub_dir"

    (
        export PATH="$stub_dir"
        sudo -n true
    ) || rc=$?
    assert_not_equals "0" "$rc" "stub refuses \`sudo -n true\` like the scoped grant"

    rc=0
    probe "$stub_dir" false true || rc=$?
    assert_not_equals "0" "$rc" "probe reports a non-allowlisted command as not runnable"

    command rm -rf "$stub_dir"
}

# ============================================================================
# Test: arguments matter — a pinned rule does not cover other operands
# ============================================================================
test_scoped_refuses_other_arguments() {
    local stub_dir rc=0
    stub_dir=$(command mktemp -d)
    write_scoped_sudo_stub "$stub_dir"

    probe "$stub_dir" false chown root:docker /etc/shadow || rc=$?
    assert_not_equals "0" "$rc" "chown on a non-pinned path is not runnable"

    command rm -rf "$stub_dir"
}

# ============================================================================
# Test: root short-circuits without consulting sudo
# ============================================================================
test_root_skips_sudo() {
    local stub_dir rc=0
    stub_dir=$(command mktemp -d)
    write_scoped_sudo_stub "$stub_dir"

    probe "$stub_dir" true true || rc=$?
    assert_equals "0" "$rc" "root can run anything"
    assert_file_not_exists "$stub_dir/calls" "sudo was never invoked when running as root"

    command rm -rf "$stub_dir"
}

# ============================================================================
# Test: no sudo binary at all → not runnable
# ============================================================================
test_no_sudo_not_runnable() {
    local empty_dir rc=0
    empty_dir=$(command mktemp -d)

    probe "$empty_dir" false chown root:docker /var/run/docker.sock || rc=$?
    assert_not_equals "0" "$rc" "without sudo, a non-root probe fails"

    command rm -rf "$empty_dir"
}

# ============================================================================
# Test: every reconcile site uses the per-command probe, none the old one
# ============================================================================
test_no_sudo_true_probe_in_runtime() {
    # Match the probe as code (`&& sudo -n true`), not comments that cite it.
    local hits
    hits=$(command grep -rlE "&&[[:space:]]*sudo -n true" \
        "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh" \
        "$PROJECT_ROOT/lib/runtime/lib/fix-cache-permissions.sh" \
        "$PROJECT_ROOT/lib/runtime/lib/fix-run-permissions.sh" \
        "$PROJECT_ROOT/lib/runtime/lib/setup-bindfs.sh" \
        "$PROJECT_ROOT/lib/runtime/commands/fix-docker-socket" || true)
    assert_equals "" "$hits" "no reconcile step probes with \`sudo -n true\`"
}

# Run tests
run_test test_scoped_allows_exact_command "Scoped sudo: allowlisted command is runnable"
run_test test_scoped_refuses_true "Scoped sudo: \`true\` is refused (#996 regression)"
run_test test_scoped_refuses_other_arguments "Scoped sudo: pinned arguments are enforced"
run_test test_root_skips_sudo "Root short-circuits without sudo"
run_test test_no_sudo_not_runnable "No sudo binary means not runnable"
run_test test_no_sudo_true_probe_in_runtime "No reconcile site uses \`sudo -n true\`"

# Generate test report
generate_report
