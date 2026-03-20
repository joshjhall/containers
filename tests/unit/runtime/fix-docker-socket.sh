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

# Run tests
run_test test_docker_socket_no_socket "Returns 0 when no docker socket"
run_test test_docker_socket_function_defined "Function is defined after sourcing"
run_test test_docker_socket_warning_messages "Contains expected warning messages"
run_test test_docker_socket_creates_group "Script creates docker group"
run_test test_docker_socket_chowns_and_chmods "Script calls chown and chmod"
run_test test_docker_socket_adds_user "Script adds user to docker group"
run_test test_docker_socket_sets_configured_flag "Script sets DOCKER_SOCKET_CONFIGURED flag"
run_test test_docker_socket_already_accessible "Returns 0 when socket already accessible"

# Generate test report
generate_report
