#!/usr/bin/env bash
# Shared fixtures for the lib/runtime/commands/setup-git test suites.
#
# SOURCE-ONLY — this file defines no tests and must never be executed directly.
# It lives under tests/framework/ rather than tests/unit/ because
# run_unit_tests.sh runs every *.sh beneath tests/unit as a suite (same reason
# as tests/framework/helpers/workspace-fs-health.sh).
#
# Sourced by:
#   tests/unit/runtime/setup-git.sh          (static checks, keys, #1711/#1723)
#   tests/unit/runtime/setup-git-identity.sh (#1533 identity shadowing)
#
# Source it AFTER framework.sh + init_test_framework — SETUP_GIT_SCRIPT reads
# PROJECT_ROOT, which the framework establishes.
#
# Split out of setup-git.sh in issue #1733; the seam was identified by the
# decomposition dimension of the PR #1732 adversarial review.

# Path to the script under test
SETUP_GIT_SCRIPT="$PROJECT_ROOT/lib/runtime/commands/setup-git"

# Setup function - runs before each test (overrides framework setup)
# Uses /tmp for temp files because /workspace may have a bindfs overlay
# that forces permissions (e.g. 644), breaking chmod 600 assertions.
setup() {
    local unique_id
    unique_id="$$-$(date +%s%N)"
    export TEST_TEMP_DIR="/tmp/test-setup-git-$unique_id"
    mkdir -p "$TEST_TEMP_DIR"

    export TEST_HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$TEST_HOME/.ssh"
}

# Teardown function - runs after each test (overrides framework teardown)
teardown() {
    command rm -rf "${TEST_TEMP_DIR:-}" 2>/dev/null || true
    unset TEST_TEMP_DIR TEST_HOME 2>/dev/null || true
    unset GIT_USER_NAME GIT_USER_EMAIL GIT_AUTH_SSH_KEY GIT_SIGNING_SSH_KEY 2>/dev/null || true
}

# Wrapper for running tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}
# Record-only ssh-agent / ssh-add stubs on a private PATH (#1711).
_stub_ssh_tools() {
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/bin/bash\necho "ssh-agent $*" >>"%s/ssh.calls"\necho "SSH_AUTH_SOCK=/tmp/fake.sock; export SSH_AUTH_SOCK;"\necho "SSH_AGENT_PID=1; export SSH_AGENT_PID;"\n' \
        "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/ssh-agent"
    # Key adds succeed unless $TEST_TEMP_DIR/ssh-add.fail exists (#1723).
    printf '#!/bin/bash\necho "ssh-add $*" >>"%s/ssh.calls"\ncase "$1" in -l|-L) exit 1 ;; esac\n[ -e "%s/ssh-add.fail" ] && exit 1\nexit 0\n' \
        "$TEST_TEMP_DIR" "$TEST_TEMP_DIR" >"$TEST_TEMP_DIR/bin/ssh-add"
    chmod +x "$TEST_TEMP_DIR/bin/ssh-agent" "$TEST_TEMP_DIR/bin/ssh-add"
    : >"$TEST_TEMP_DIR/ssh.calls"
}

# Run setup-git sandboxed; extra NAME=value args go into its env.
_run_setup_git() {
    _stub_ssh_tools
    command env -i BASH_ENV= HOME="$TEST_HOME" \
        PATH="$TEST_TEMP_DIR/bin:/usr/bin:/bin" \
        GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" \
        _ENV_SECRETS_LOADED=1 _OP_CACHE_LOADED=1 \
        WORKSPACE_ROOT="$TEST_TEMP_DIR/ws" \
        GIT_USER_NAME="Test User" GIT_USER_EMAIL="test@example.com" \
        "$@" bash "$SETUP_GIT_SCRIPT" 2>&1
}

_gitcfg() {
    command env -i BASH_ENV= HOME="$TEST_HOME" PATH="/usr/bin:/bin" \
        GIT_CONFIG_GLOBAL="$TEST_HOME/.gitconfig" git config --global --get "$1" 2>/dev/null || true
}
