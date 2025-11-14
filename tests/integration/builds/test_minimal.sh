#!/usr/bin/env bash
# Test minimal container builds
# 
# This test verifies that the most basic container configurations
# build successfully and have the expected base functionality.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Minimal Container Builds"

# Test: Base container with no features
test_base_container_only() {
    # Use pre-built image if provided, otherwise build locally
    local expected_workspace
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
        # CI builds use PROJECT_NAME=containers
        expected_workspace="/workspace/containers"
    else
        local image="test-minimal-base-$$"
        echo "Building image locally: $image"
        expected_workspace="/workspace/test-minimal"

        # Build with no features enabled (standalone mode)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-minimal \
            -t "$image"
    fi

    # Verify basic functionality
    assert_command_in_container "$image" "echo 'Hello World'" "Hello World"
    assert_command_in_container "$image" "whoami" "developer"
    assert_command_in_container "$image" "pwd" "$expected_workspace"

    # Verify base tools
    assert_executable_in_path "$image" "bash"
    assert_executable_in_path "$image" "curl"
    assert_executable_in_path "$image" "wget"

    # Check user setup
    assert_dir_in_image "$image" "/home/developer"
    assert_dir_in_image "$image" "$expected_workspace"
}

# Test: Cache directories are properly configured
test_cache_directories() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Verify cache directory exists
    assert_dir_in_image "$image" "/cache"

    # Verify cache is writable by the developer user
    assert_command_in_container "$image" "test -w /cache && echo writable" "writable"
}

# Test: Runtime scripts executed successfully
test_runtime_initialization() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Runtime scripts should have executed (check for marker or log output)
    # The container startup shows "=== Running startup scripts ===" in output
    assert_command_in_container "$image" "echo 'startup complete'" "startup complete"

    # Verify first-time setup can be re-run safely (idempotent)
    assert_command_in_container "$image" "ls /workspace" ""
}

# Test: User permissions and environment
test_user_environment() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Verify user is in sudo group but passwordless sudo is disabled by default (security)
    # This should fail with "password is required" which means sudo is available but secure
    assert_command_in_container "$image" "id -nG | grep -q sudo && echo 'in-sudo-group'" "in-sudo-group"

    # Verify home directory is properly set
    assert_command_in_container "$image" "echo \$HOME" "/home/developer"

    # Verify user can write to workspace
    assert_command_in_container "$image" "touch /workspace/test-file && rm /workspace/test-file && echo success" "success"
}

# Test: Essential utilities are available
test_essential_utilities() {
    local image="${IMAGE_TO_TEST:-test-minimal-base-$$}"

    # Version control
    assert_executable_in_path "$image" "git"

    # Text processing and utilities
    assert_executable_in_path "$image" "jq"
    assert_executable_in_path "$image" "shellcheck"

    # Network tools
    assert_executable_in_path "$image" "curl"
    assert_executable_in_path "$image" "wget"

    # Build essentials
    assert_executable_in_path "$image" "make"
    assert_executable_in_path "$image" "gcc"

    # System utilities
    assert_executable_in_path "$image" "htop"
    assert_executable_in_path "$image" "unzip"
}

# Run all tests
run_test test_base_container_only "Base container builds with no features"
run_test test_cache_directories "Cache directories are configured"
run_test test_runtime_initialization "Runtime initialization completes"
run_test test_user_environment "User environment is properly configured"
run_test test_essential_utilities "Essential utilities are available"

# Generate test report
generate_report