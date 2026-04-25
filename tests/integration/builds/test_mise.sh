#!/usr/bin/env bash
# Test mise (polyglot runtime version manager) container build
#
# This test verifies that the mise feature:
# - Builds successfully with INCLUDE_MISE=true
# - Installs the mise binary to /usr/local/bin/mise
# - Installs the shell activation fragment at /etc/bashrc.d/70-mise.sh
# - Creates /cache/mise writable by the container user
# - Can install at least one runtime from a .mise.toml
# - Does NOT include mise when the flag is not set

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Mise Container Build"

# Test: Mise builds successfully
test_mise_build() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-mise-$$"
        echo "Building image locally: $image"

        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-mise \
            --build-arg INCLUDE_MISE=true \
            -t "$image"
    fi

    assert_executable_in_path "$image" "mise"
}

# Test: mise --version works
test_mise_version() {
    local image="${IMAGE_TO_TEST:-test-mise-$$}"

    assert_command_in_container "$image" "mise --version" "mise"
}

# Test: Activation fragment installed at expected path
test_mise_bashrc_fragment() {
    local image="${IMAGE_TO_TEST:-test-mise-$$}"

    assert_command_in_container "$image" "test -x /etc/bashrc.d/70-mise.sh && echo exists" "exists"
    assert_command_in_container "$image" "grep -c 'mise activate' /etc/bashrc.d/70-mise.sh" "1"
}

# Test: /cache/mise exists and is writable by the container user
test_mise_cache_dir() {
    local image="${IMAGE_TO_TEST:-test-mise-$$}"

    assert_command_in_container "$image" "test -d /cache/mise && echo exists" "exists"
    # Writable check — touch a file as the default user
    assert_command_in_container "$image" "touch /cache/mise/.write-test && echo writable && rm /cache/mise/.write-test" "writable"
}

# Test: Activation fragment exports MISE_TRUSTED_CONFIG_PATHS
test_mise_trusted_paths() {
    local image="${IMAGE_TO_TEST:-test-mise-$$}"

    assert_command_in_container "$image" "grep -c MISE_TRUSTED_CONFIG_PATHS /etc/bashrc.d/70-mise.sh" "1"
}

# Test: mise can install a runtime from .mise.toml
# Uses deno — single static binary, fastest hermetic install.
test_mise_install_runtime() {
    local image="${IMAGE_TO_TEST:-test-mise-$$}"

    # Interactive shell ensures the 70-mise.sh fragment is sourced and mise
    # activate has set up shims. Use printf for a multi-line .mise.toml.
    assert_command_in_container "$image" \
        "bash -ic 'cd /tmp && mkdir -p mise-test && cd mise-test && printf \"[tools]\\ndeno = \\\"1\\\"\\n\" > .mise.toml && mise install >/dev/null 2>&1 && mise which deno >/dev/null 2>&1 && echo install-ok'" \
        "install-ok"
}

# Test: Build without the mise flag does not include it
test_no_mise_without_flag() {
    local image="test-no-mise-$$"
    echo "Building image without mise: $image"

    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-no-mise \
        -t "$image"

    assert_command_in_container "$image" "which mise 2>/dev/null || echo not-found" "not-found"
    assert_command_in_container "$image" "test -f /etc/bashrc.d/70-mise.sh && echo exists || echo not-found" "not-found"
}

# Run all tests
run_test test_mise_build "Mise builds successfully"
run_test test_mise_version "mise --version works"
run_test test_mise_bashrc_fragment "Activation fragment at 70-mise.sh"
run_test test_mise_cache_dir "/cache/mise exists and is writable"
run_test test_mise_trusted_paths "Fragment exports MISE_TRUSTED_CONFIG_PATHS"
run_test test_mise_install_runtime "mise installs a runtime from .mise.toml"
run_test test_no_mise_without_flag "Build without mise flag excludes it"

# Generate test report
generate_report
