#!/usr/bin/env bash
# Unit tests for lib/runtime/lib/fix-docker-socket.sh

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Runtime Fix Docker Socket Tests"

# Helper to set up the environment expected by configure_docker_socket
setup_docker_env() {
    RUNNING_AS_ROOT="${1:-false}"
    USERNAME="${2:-testuser}"
    export RUNNING_AS_ROOT USERNAME
}

# ============================================================================
# Test: configure_docker_socket when no socket exists
# ============================================================================
test_docker_socket_no_socket() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh"

    setup_docker_env "false" "testuser"

    # The function checks [ -S /var/run/docker.sock ] || return 0
    # If no socket exists, it returns 0 immediately
    if [ ! -S /var/run/docker.sock ]; then
        configure_docker_socket
        assert_equals "0" "$?" "Returns 0 when no docker socket exists"
    else
        skip_test "Docker socket exists on this system"
    fi
}

# ============================================================================
# Test: Function is defined after sourcing
# ============================================================================
test_docker_socket_function_defined() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh"
    assert_function_exists "configure_docker_socket" "configure_docker_socket function is defined"
}

# ============================================================================
# Test: Script contains expected messages
# ============================================================================
test_docker_socket_warning_messages() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh")

    assert_contains "$script_content" "Configuring Docker socket access" \
        "Script contains setup message"
    assert_contains "$script_content" "Cannot configure Docker socket" \
        "Script contains no-sudo warning"
    assert_contains "$script_content" "Docker socket access configured" \
        "Script contains success message"
}

# ============================================================================
# Test: Script creates docker group
# ============================================================================
test_docker_socket_creates_group() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh")

    assert_contains "$script_content" "groupadd docker" \
        "Script creates docker group"
}

# ============================================================================
# Test: Script calls chown and chmod on socket
# ============================================================================
test_docker_socket_chowns_and_chmods() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh")

    assert_contains "$script_content" "chown root:docker /var/run/docker.sock" \
        "Script chowns socket to root:docker"
    assert_contains "$script_content" "chmod 660 /var/run/docker.sock" \
        "Script sets 660 permissions on socket"
}

# ============================================================================
# Test: Script adds user to docker group
# ============================================================================
test_docker_socket_adds_user() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh")

    assert_contains "$script_content" 'usermod -aG docker' \
        "Script adds user to docker group"
}

# ============================================================================
# Test: Script sets DOCKER_SOCKET_CONFIGURED flag
# ============================================================================
test_docker_socket_sets_configured_flag() {
    local script_content
    script_content=$(/usr/bin/cat "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh")

    assert_contains "$script_content" "DOCKER_SOCKET_CONFIGURED=true" \
        "Script exports DOCKER_SOCKET_CONFIGURED flag"
}

# ============================================================================
# Test: configure_docker_socket with mocked socket (already accessible)
# ============================================================================
test_docker_socket_already_accessible() {
    source "$PROJECT_ROOT/lib/runtime/lib/fix-docker-socket.sh"

    setup_docker_env "false" "testuser"

    # If docker socket doesn't exist, the function returns 0
    # (which is the same as "already accessible" from a no-op perspective)
    if [ ! -S /var/run/docker.sock ]; then
        configure_docker_socket >/dev/null 2>&1
        # Should return 0 with no output (no socket = early exit)
        assert_equals "0" "$?" "Returns 0 when socket doesn't exist"
    else
        # Socket exists — check if it's already accessible
        if test -r /var/run/docker.sock -a -w /var/run/docker.sock 2>/dev/null; then
            configure_docker_socket >/dev/null 2>&1
            assert_equals "0" "$?" "Returns 0 when socket already accessible"
        else
            skip_test "Docker socket exists but is not accessible"
        fi
    fi
}

# ============================================================================
# Durable reconcile command: lib/runtime/commands/fix-docker-socket (issue #674)
# ============================================================================
FIX_CMD="$PROJECT_ROOT/lib/runtime/commands/fix-docker-socket"

# True when the environment can perform the privileged reconcile (root, or
# passwordless sudo, AND a docker group exists to chown to).
_can_reconcile() {
    getent group docker >/dev/null 2>&1 || return 1
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null
}

# Run a privileged command the same way the tests stage sockets.
_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# Stage a socket on a chown-capable filesystem with a given owner:group. Echoes
# the socket path on success; echoes nothing when staging is impossible (e.g.
# the results dir lives on a bind mount that silently ignores chown, as the
# git worktree volume does — a real container's /var/run is tmpfs where chown
# takes effect). Callers skip when the return is empty.
_stage_socket() {
    local ownergroup="$1"
    local dir sock
    dir=$(mktemp -d -t fix-sock-XXXXXX) || return 0
    sock="$dir/docker.sock"
    /usr/bin/python3 - "$sock" <<'PY' 2>/dev/null
import socket, sys
socket.socket(socket.AF_UNIX).bind(sys.argv[1])
PY
    [ -S "$sock" ] || {
        /bin/rm -rf "$dir"
        return 0
    }
    _priv chown "$ownergroup" "$sock" 2>/dev/null
    _priv chmod 660 "$sock" 2>/dev/null
    # Verify the chown actually took — skip silently if the FS ignored it.
    local got="${ownergroup#*:}"
    if [ "$(/usr/bin/stat -c '%G' "$sock" 2>/dev/null)" != "$got" ]; then
        _priv /bin/rm -rf "$dir" 2>/dev/null
        return 0
    fi
    echo "$sock"
}

# --- Command exists and is executable ---
test_fix_cmd_executable() {
    assert_file_exists "$FIX_CMD" "fix-docker-socket command exists"
    assert_file_executable "$FIX_CMD" "fix-docker-socket command is executable"
}

# --- Reconcile is keyed on GROUP ownership, not the caller's own access ---
# This is the crux of the fix: root passes a read/write test even when the
# socket is root:root, so the durable path must inspect group ownership.
test_fix_cmd_checks_group_ownership() {
    local content
    content=$(/usr/bin/cat "$FIX_CMD")
    assert_contains "$content" "stat -c '%G'" \
        "Command inspects socket group ownership (not just r/w access)"
    assert_contains "$content" 'chown "root:$DOCKER_GROUP"' \
        "Command chowns socket to root:docker"
    assert_contains "$content" 'chmod 660' \
        "Command sets 660 permissions on socket"
}

# --- Honors DOCKER_SOCK_PATH override (needed for testability) ---
test_fix_cmd_honors_sock_override() {
    local content
    content=$(/usr/bin/cat "$FIX_CMD")
    assert_contains "$content" 'DOCKER_SOCK_PATH' \
        "Command honors DOCKER_SOCK_PATH override"
}

# --- No-op when the socket is absent (exit 0, no reconcile) ---
test_fix_cmd_noop_when_absent() {
    local missing="$RESULTS_DIR/674-absent.sock"
    /bin/rm -f "$missing" 2>/dev/null || true
    local out rc
    out=$(DOCKER_SOCK_PATH="$missing" "$FIX_CMD" 2>&1)
    rc=$?
    assert_equals "0" "$rc" "Exits 0 when socket is absent"
    assert_empty "$out" "Produces no output when socket is absent"
}

# --- Idempotent: no-op when already root:docker with group rw ---
test_fix_cmd_idempotent_when_correct() {
    if ! _can_reconcile; then
        skip_test "No privilege/docker-group to stage a root:docker socket"
        return 0
    fi
    local sock
    sock=$(_stage_socket "root:docker")
    if [ -z "$sock" ]; then
        skip_test "Could not stage a root:docker socket (chown-capable FS unavailable)"
        return 0
    fi

    local out rc
    out=$(DOCKER_SOCK_PATH="$sock" "$FIX_CMD" 2>&1)
    rc=$?
    assert_equals "0" "$rc" "Exits 0 when already correct"
    assert_empty "$out" "No reconcile output when already root:docker 660"

    _priv /bin/rm -rf "$(dirname "$sock")" 2>/dev/null || true
}

# --- Applies fix when group ownership is wrong ---
test_fix_cmd_reconciles_wrong_group() {
    if ! _can_reconcile; then
        skip_test "No privilege/docker-group to reconcile a socket"
        return 0
    fi
    # Stage the broken state Docker Desktop leaves behind: root:root.
    local sock
    sock=$(_stage_socket "root:root")
    if [ -z "$sock" ]; then
        skip_test "Could not stage a root:root socket (chown-capable FS unavailable)"
        return 0
    fi

    local rc
    DOCKER_SOCK_PATH="$sock" "$FIX_CMD" >/dev/null 2>&1
    rc=$?
    assert_equals "0" "$rc" "Exits 0 after reconciling"

    local group
    group=$(/usr/bin/stat -c '%G' "$sock" 2>/dev/null || echo "")
    assert_equals "docker" "$group" "Socket group reconciled to docker"

    _priv /bin/rm -rf "$(dirname "$sock")" 2>/dev/null || true
}

# --- Every-boot startup wrapper is wired correctly ---
test_startup_wrapper_invokes_command() {
    local wrapper="$PROJECT_ROOT/lib/runtime/10-fix-docker-socket.sh"
    assert_file_exists "$wrapper" "Every-boot startup wrapper exists"
    assert_file_executable "$wrapper" "Startup wrapper is executable"
    local content
    content=$(/usr/bin/cat "$wrapper")
    assert_contains "$content" "fix-docker-socket" \
        "Startup wrapper invokes the fix-docker-socket command"
}

# Run tests
run_test test_docker_socket_no_socket "Returns 0 when no docker socket"
run_test test_docker_socket_function_defined "Function is defined after sourcing"
run_test test_docker_socket_warning_messages "Contains expected warning messages"
run_test test_docker_socket_creates_group "Script creates docker group"
run_test test_docker_socket_chowns_and_chmods "Script calls chown and chmod"
run_test test_docker_socket_adds_user "Script adds user to docker group"
run_test test_docker_socket_sets_configured_flag "Script sets DOCKER_SOCKET_CONFIGURED flag"
run_test test_docker_socket_already_accessible "Returns 0 when socket already accessible"

# Durable reconcile command (issue #674)
run_test test_fix_cmd_executable "fix-docker-socket command exists and is executable"
run_test test_fix_cmd_checks_group_ownership "Reconcile keyed on group ownership"
run_test test_fix_cmd_honors_sock_override "Command honors DOCKER_SOCK_PATH override"
run_test test_fix_cmd_noop_when_absent "No-op when socket is absent"
run_test test_fix_cmd_idempotent_when_correct "Idempotent when already root:docker"
run_test test_fix_cmd_reconciles_wrong_group "Reconciles a root:root socket to docker"
run_test test_startup_wrapper_invokes_command "Every-boot wrapper invokes the command"

# Generate test report
generate_report
