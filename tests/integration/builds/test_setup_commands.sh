#!/usr/bin/env bash
# Test setup-git, setup-gh, and setup-glab commands functionally
#
# This test builds two images (minimal + dev-tools) and runs the setup
# commands in persistent containers to verify actual configuration:
# git config values, SSH files, bashrc persistence, graceful skips.
#
# Uses the `docker run -d` + `docker exec` pattern for stateful verification.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Setup Commands Functional Tests"

# ---------------------------------------------------------------------------
# Shared image names (built once, reused across tests)
# ---------------------------------------------------------------------------
MINIMAL_IMAGE="test-setup-minimal-$$"
DEVTOOLS_IMAGE="test-setup-devtools-$$"

# ---------------------------------------------------------------------------
# Build images
# ---------------------------------------------------------------------------
test_build_minimal_image() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        MINIMAL_IMAGE="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $MINIMAL_IMAGE"
    else
        echo "Building minimal image: $MINIMAL_IMAGE"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-setup \
            -t "$MINIMAL_IMAGE"
    fi

    assert_executable_in_path "$MINIMAL_IMAGE" "git"
    assert_executable_in_path "$MINIMAL_IMAGE" "setup-git"
}

test_build_devtools_image() {
    if [ -n "${DEVTOOLS_IMAGE_TO_TEST:-}" ]; then
        DEVTOOLS_IMAGE="$DEVTOOLS_IMAGE_TO_TEST"
        echo "Testing pre-built dev-tools image: $DEVTOOLS_IMAGE"
    else
        echo "Building dev-tools image: $DEVTOOLS_IMAGE"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-setup \
            --build-arg INCLUDE_DEV_TOOLS=true \
            -t "$DEVTOOLS_IMAGE"
    fi

    assert_executable_in_path "$DEVTOOLS_IMAGE" "gh"
    assert_executable_in_path "$DEVTOOLS_IMAGE" "glab"
}

# ---------------------------------------------------------------------------
# Helper: start a persistent container and register for cleanup
# ---------------------------------------------------------------------------
_start_container() {
    local name="$1"
    local image="$2"
    shift 2
    docker run -d --name "$name" "$@" "$image" sleep infinity >/dev/null
    TEST_CONTAINERS+=("$name")
}

# ---------------------------------------------------------------------------
# Helper: install a mock gh/glab in ~/.local/bin (which is in PATH and takes
# precedence over /usr/bin). This is needed because gh/glab auth login fails
# with fake tokens against real servers, and set -e kills the script before
# _persist_token runs.
# ---------------------------------------------------------------------------
_install_mock_gh() {
    local container="$1"
    docker exec "$container" bash -c '
        mkdir -p ~/.local/bin
        command cat > ~/.local/bin/gh <<'"'"'MOCK'"'"'
#!/bin/bash
case "$*" in
    *"auth status"*) exit 0 ;;
    *"auth login"*)  exit 0 ;;
    *"auth token"*)  echo "mock-token"; exit 0 ;;
    *)               exit 0 ;;
esac
MOCK
        chmod +x ~/.local/bin/gh
    '
}

_remove_mock_gh() {
    local container="$1"
    docker exec "$container" rm -f ~/.local/bin/gh
}

_install_mock_glab() {
    local container="$1"
    docker exec "$container" bash -c '
        mkdir -p ~/.local/bin
        command cat > ~/.local/bin/glab <<'"'"'MOCK'"'"'
#!/bin/bash
case "$*" in
    *"auth status"*) exit 0 ;;
    *"auth login"*)  exit 0 ;;
    *"config get"*)  echo "mock-token"; exit 0 ;;
    *)               exit 0 ;;
esac
MOCK
        chmod +x ~/.local/bin/glab
    '
}

_remove_mock_glab() {
    local container="$1"
    docker exec "$container" rm -f ~/.local/bin/glab
}

# ===========================================================================
# setup-git tests (minimal image)
# ===========================================================================

test_setup_git_default_identity() {
    local c="setup-git-default-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    docker exec "$c" setup-git 2>&1

    local name email
    name=$(docker exec "$c" git config --global user.name)
    email=$(docker exec "$c" git config --global user.email)
    assert_equals "Devcontainer" "$name" "Default user.name"
    assert_equals "devcontainer@localhost" "$email" "Default user.email"
}

test_setup_git_custom_identity() {
    local c="setup-git-custom-$$"
    _start_container "$c" "$MINIMAL_IMAGE" \
        -e GIT_USER_NAME="Test User" \
        -e GIT_USER_EMAIL="test@example.com"

    docker exec "$c" setup-git 2>&1

    local name email
    name=$(docker exec "$c" git config --global user.name)
    email=$(docker exec "$c" git config --global user.email)
    assert_equals "Test User" "$name" "Custom user.name"
    assert_equals "test@example.com" "$email" "Custom user.email"
}

test_setup_git_invalid_email_fallback() {
    local c="setup-git-bademail-$$"
    _start_container "$c" "$MINIMAL_IMAGE" \
        -e GIT_USER_EMAIL="not-an-email"

    local output
    output=$(docker exec "$c" setup-git 2>&1)

    assert_contains "$output" "WARN" "Output should contain WARN for invalid email"

    local email
    email=$(docker exec "$c" git config --global user.email)
    assert_equals "devcontainer@localhost" "$email" "Fallback email after invalid input"
}

test_setup_git_ssh_agent_started() {
    local c="setup-git-agent-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    docker exec "$c" setup-git 2>&1

    # agent.env should exist
    local rc=0
    docker exec "$c" test -f /home/developer/.ssh/agent.env || rc=$?
    assert_exit_code 0 "$rc" "agent.env should exist"

    # SSH_AUTH_SOCK should be set and point to a real socket
    local sock
    sock=$(docker exec "$c" bash -c 'source ~/.ssh/agent.env >/dev/null 2>&1; echo "$SSH_AUTH_SOCK"')
    assert_not_empty "$sock" "SSH_AUTH_SOCK should be set"

    rc=0
    docker exec "$c" bash -c 'source ~/.ssh/agent.env >/dev/null 2>&1; test -S "$SSH_AUTH_SOCK"' || rc=$?
    assert_exit_code 0 "$rc" "SSH_AUTH_SOCK should point to a socket"
}

test_setup_git_ssh_keepalive() {
    local c="setup-git-keepalive-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    docker exec "$c" setup-git 2>&1

    local config
    config=$(docker exec "$c" bash -c 'cat /home/developer/.ssh/config')
    assert_contains "$config" "github.com" "SSH config should mention github.com"
    assert_contains "$config" "gitlab.com" "SSH config should mention gitlab.com"
    assert_contains "$config" "ServerAliveInterval 60" "SSH config should have keepalive"
}

test_setup_git_ssh_keepalive_idempotent() {
    local c="setup-git-keepalive-idem-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    docker exec "$c" setup-git 2>&1
    docker exec "$c" setup-git 2>&1

    local count
    count=$(docker exec "$c" bash -c "grep -c 'Host github.com' /home/developer/.ssh/config")
    assert_equals "1" "$count" "Only one Host block after two runs"
}

test_setup_git_auth_key() {
    local c="setup-git-authkey-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    # Generate a test key inside the container
    docker exec "$c" ssh-keygen -t ed25519 -f /tmp/testkey -N "" -q

    # Run setup-git with the generated key as GIT_AUTH_SSH_KEY
    docker exec "$c" bash -c 'export GIT_AUTH_SSH_KEY="$(command cat /tmp/testkey)" && setup-git' 2>&1

    # Key should be written with 600 permissions
    local rc=0
    docker exec "$c" test -f /home/developer/.ssh/git_auth_key || rc=$?
    assert_exit_code 0 "$rc" "Auth key file should exist"

    local perms
    perms=$(docker exec "$c" stat -c '%a' /home/developer/.ssh/git_auth_key)
    assert_equals "600" "$perms" "Auth key should have 600 permissions"

    # core.sshCommand should be set for VS Code compatibility
    local ssh_cmd
    ssh_cmd=$(docker exec "$c" git config --global core.sshCommand)
    assert_contains "$ssh_cmd" "git_auth_key" "core.sshCommand should reference auth key"
    assert_contains "$ssh_cmd" "IdentitiesOnly" "core.sshCommand should use IdentitiesOnly"
}

test_setup_git_no_auth_key_no_ssh_command() {
    local c="setup-git-nosshcmd-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    docker exec "$c" setup-git 2>&1

    # core.sshCommand should NOT be set when no auth key is provided
    local rc=0
    docker exec "$c" git config --global core.sshCommand >/dev/null 2>&1 || rc=$?
    assert_exit_code 1 "$rc" "core.sshCommand should not be set without auth key"
}

test_setup_git_signing_key() {
    local c="setup-git-signing-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    # Generate a test key
    docker exec "$c" ssh-keygen -t ed25519 -f /tmp/signkey -N "" -q

    docker exec "$c" bash -c 'export GIT_SIGNING_SSH_KEY="$(command cat /tmp/signkey)" && setup-git' 2>&1

    local format gpgsign
    format=$(docker exec "$c" git config --global gpg.format)
    gpgsign=$(docker exec "$c" git config --global commit.gpgsign)
    assert_equals "ssh" "$format" "gpg.format should be ssh"
    assert_equals "true" "$gpgsign" "commit.gpgsign should be true"
}

test_setup_git_idempotent() {
    local c="setup-git-idem-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    docker exec "$c" setup-git 2>&1

    local output
    output=$(docker exec "$c" setup-git 2>&1)
    assert_contains "$output" "already configured" "Second run should say already configured"

    # Config should still be correct
    local name
    name=$(docker exec "$c" git config --global user.name)
    assert_equals "Devcontainer" "$name" "Identity unchanged after second run"
}

# ===========================================================================
# setup-gh tests
# ===========================================================================

test_setup_gh_skips_not_installed() {
    local c="setup-gh-nobin-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    local output rc=0
    output=$(docker exec "$c" setup-gh 2>&1) || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 when gh not installed"
    assert_contains "$output" "gh CLI not installed" "Should report gh not installed"
}

test_setup_gh_skips_no_token() {
    local c="setup-gh-notoken-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    local output rc=0
    output=$(docker exec "$c" setup-gh 2>&1) || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 with no token"
    assert_contains "$output" "GITHUB_TOKEN not set" "Should report token not set"
}

test_setup_gh_rejects_short_token() {
    local c="setup-gh-short-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    local output rc=0
    output=$(docker exec "$c" bash -c 'export GITHUB_TOKEN="abc" && setup-gh 2>&1') || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 with short token"
    assert_contains "$output" "too short" "Should report token too short"
}

test_setup_gh_rejects_control_chars() {
    local c="setup-gh-ctrl-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    # Use a non-whitespace control character (\x01) to survive tr -d '[:space:]' sanitization
    local output rc=0
    output=$(docker exec "$c" bash -c $'export GITHUB_TOKEN="ghp_abc\x01def1234" && setup-gh 2>&1') || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 with control chars"
    assert_contains "$output" "control characters" "Should report control characters"
}

test_setup_gh_attempts_auth() {
    local c="setup-gh-auth-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    # Verify that setup-gh reaches the auth step with a valid-format token.
    # With a fake token, gh auth login may fail (set -e), so we check output only.
    local output
    output=$(docker exec "$c" bash -c 'export GITHUB_TOKEN="ghp_fake_token_for_testing_1234567890" && setup-gh 2>&1' || true)
    assert_contains "$output" "authenticating gh CLI" "Should attempt authentication"
}

test_setup_gh_persists_bashrc() {
    local c="setup-gh-bashrc-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    # Replace gh with a mock that always succeeds (real gh fails with fake tokens,
    # and set -e kills the script before _persist_token runs)
    _install_mock_gh "$c"

    docker exec "$c" bash -c 'export GITHUB_TOKEN="ghp_fake_token_for_testing_1234567890" && setup-gh' 2>&1

    _remove_mock_gh "$c"

    local bashrc
    bashrc=$(docker exec "$c" bash -c 'cat /home/developer/.bashrc')
    assert_contains "$bashrc" "# setup-gh: GITHUB_TOKEN" "bashrc should contain setup-gh marker"
}

test_setup_gh_bashrc_idempotent() {
    local c="setup-gh-bashrc-idem-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    _install_mock_gh "$c"

    docker exec "$c" bash -c 'export GITHUB_TOKEN="ghp_fake_token_for_testing_1234567890" && setup-gh' 2>&1
    docker exec "$c" bash -c 'export GITHUB_TOKEN="ghp_fake_token_for_testing_1234567890" && setup-gh' 2>&1

    _remove_mock_gh "$c"

    local count
    count=$(docker exec "$c" bash -c "grep -c '# setup-gh: GITHUB_TOKEN' /home/developer/.bashrc")
    assert_equals "1" "$count" "Marker should appear exactly once after two runs"
}

# ===========================================================================
# setup-glab tests
# ===========================================================================

test_setup_glab_skips_not_installed() {
    local c="setup-glab-nobin-$$"
    _start_container "$c" "$MINIMAL_IMAGE"

    local output rc=0
    output=$(docker exec "$c" setup-glab 2>&1) || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 when glab not installed"
    assert_contains "$output" "glab CLI not installed" "Should report glab not installed"
}

test_setup_glab_skips_no_token() {
    local c="setup-glab-notoken-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    local output rc=0
    output=$(docker exec "$c" setup-glab 2>&1) || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 with no token"
    assert_contains "$output" "GITLAB_TOKEN not set" "Should report token not set"
}

test_setup_glab_rejects_short_token() {
    local c="setup-glab-short-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    local output rc=0
    output=$(docker exec "$c" bash -c 'export GITLAB_TOKEN="abc" && setup-glab 2>&1') || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 with short token"
    assert_contains "$output" "too short" "Should report token too short"
}

test_setup_glab_rejects_invalid_hostname() {
    local c="setup-glab-badhost-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    local output rc=0
    output=$(docker exec "$c" bash -c 'export GITLAB_TOKEN="test_fake_gitlab_token_1234" GITLAB_HOST="not a/valid host" && setup-glab 2>&1') || rc=$?
    assert_exit_code 0 "$rc" "Should exit 0 with invalid hostname"
    assert_contains "$output" "does not look like a valid hostname" "Should report invalid hostname"
}

test_setup_glab_uses_default_host() {
    local c="setup-glab-defhost-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE" -e GITLAB_TOKEN="test_fake_gitlab_token_1234"

    local output
    output=$(docker exec "$c" setup-glab 2>&1)
    assert_contains "$output" "gitlab.com" "Output should mention gitlab.com as default host"
}

test_setup_glab_custom_host() {
    local c="setup-glab-custhost-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE" \
        -e GITLAB_TOKEN="test_fake_gitlab_token_1234" \
        -e GITLAB_HOST="gitlab.myco.com"

    local output
    output=$(docker exec "$c" setup-glab 2>&1)
    assert_contains "$output" "gitlab.myco.com" "Output should mention custom host"
}

test_setup_glab_persists_bashrc() {
    local c="setup-glab-bashrc-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    # Replace glab with a mock that always succeeds
    _install_mock_glab "$c"

    docker exec "$c" bash -c 'export GITLAB_TOKEN="test_fake_gitlab_token_1234" && setup-glab' 2>&1

    _remove_mock_glab "$c"

    local bashrc
    bashrc=$(docker exec "$c" bash -c 'cat /home/developer/.bashrc')
    assert_contains "$bashrc" "# setup-glab: GITLAB_TOKEN" "bashrc should contain setup-glab marker"
}

test_setup_glab_bashrc_idempotent() {
    local c="setup-glab-bashrc-idem-$$"
    _start_container "$c" "$DEVTOOLS_IMAGE"

    _install_mock_glab "$c"

    docker exec "$c" bash -c 'export GITLAB_TOKEN="test_fake_gitlab_token_1234" && setup-glab' 2>&1
    docker exec "$c" bash -c 'export GITLAB_TOKEN="test_fake_gitlab_token_1234" && setup-glab' 2>&1

    _remove_mock_glab "$c"

    local count
    count=$(docker exec "$c" bash -c "grep -c '# setup-glab: GITLAB_TOKEN' /home/developer/.bashrc")
    assert_equals "1" "$count" "Marker should appear exactly once after two runs"
}

# ===========================================================================
# Run all tests
# ===========================================================================

# Image builds
run_test test_build_minimal_image "Build minimal image for setup command tests"
run_test test_build_devtools_image "Build dev-tools image for setup command tests"

# setup-git tests (10 tests)
run_test test_setup_git_default_identity "setup-git: default identity (Devcontainer)"
run_test test_setup_git_custom_identity "setup-git: custom identity via env vars"
run_test test_setup_git_invalid_email_fallback "setup-git: invalid email falls back to default"
run_test test_setup_git_ssh_agent_started "setup-git: SSH agent started with socket"
run_test test_setup_git_ssh_keepalive "setup-git: SSH keepalive for github/gitlab"
run_test test_setup_git_ssh_keepalive_idempotent "setup-git: SSH keepalive idempotent"
run_test test_setup_git_auth_key "setup-git: auth key written with 600 perms"
run_test test_setup_git_no_auth_key_no_ssh_command "setup-git: no core.sshCommand without auth key"
run_test test_setup_git_signing_key "setup-git: signing key configures gpg.format=ssh"
run_test test_setup_git_idempotent "setup-git: second run says already configured"

# setup-gh tests (7 tests)
run_test test_setup_gh_skips_not_installed "setup-gh: skips when gh not installed"
run_test test_setup_gh_skips_no_token "setup-gh: skips when no GITHUB_TOKEN"
run_test test_setup_gh_rejects_short_token "setup-gh: rejects short token"
run_test test_setup_gh_rejects_control_chars "setup-gh: rejects control characters"
run_test test_setup_gh_attempts_auth "setup-gh: attempts authentication"
run_test test_setup_gh_persists_bashrc "setup-gh: persists token to bashrc"
run_test test_setup_gh_bashrc_idempotent "setup-gh: bashrc marker idempotent"

# setup-glab tests (8 tests)
run_test test_setup_glab_skips_not_installed "setup-glab: skips when glab not installed"
run_test test_setup_glab_skips_no_token "setup-glab: skips when no GITLAB_TOKEN"
run_test test_setup_glab_rejects_short_token "setup-glab: rejects short token"
run_test test_setup_glab_rejects_invalid_hostname "setup-glab: rejects invalid hostname"
run_test test_setup_glab_uses_default_host "setup-glab: uses gitlab.com as default"
run_test test_setup_glab_custom_host "setup-glab: uses custom GITLAB_HOST"
run_test test_setup_glab_persists_bashrc "setup-glab: persists token to bashrc"
run_test test_setup_glab_bashrc_idempotent "setup-glab: bashrc marker idempotent"

# Generate test report
generate_report
