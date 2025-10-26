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
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-minimal-base-$$"
        echo "Building image locally: $image"

        # Build with no features enabled (standalone mode)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-minimal \
            -t "$image"
    fi
    
    # Verify basic functionality
    assert_command_in_container "$image" "echo 'Hello World'" "Hello World"
    assert_command_in_container "$image" "whoami" "developer"
    assert_command_in_container "$image" "pwd" "/workspace/test-minimal"
    
    # Verify base tools
    assert_executable_in_path "$image" "bash"
    assert_executable_in_path "$image" "curl"
    assert_executable_in_path "$image" "wget"
    
    # Check user setup
    assert_dir_in_image "$image" "/home/developer"
    assert_dir_in_image "$image" "/workspace/test-minimal"
}

# Test: Custom username and paths
test_custom_user_configuration() {
    local image="test-custom-user-$$"
    
    # Build with custom user settings
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_NAME=myapp \
        --build-arg USERNAME=myuser \
        --build-arg WORKING_DIR=/app/myapp \
        -t "$image"
    
    # Verify custom configuration
    assert_command_in_container "$image" "whoami" "myuser"
    assert_command_in_container "$image" "pwd" "/app/myapp"
    assert_dir_in_image "$image" "/home/myuser"
    assert_dir_in_image "$image" "/app/myapp"
}

# Test: Python minimal installation
test_python_minimal() {
    local image="test-python-minimal-$$"
    
    # Build with just Python (no dev tools)
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_NAME=test-python \
        --build-arg INCLUDE_PYTHON=true \
        -t "$image"
    
    # Verify Python is installed
    assert_executable_in_path "$image" "python"
    assert_command_in_container "$image" "python --version" "Python 3."
    
    # Verify pip is available
    assert_executable_in_path "$image" "pip"
    
    # Verify dev tools are NOT installed
    assert_command_fails_in_container "$image" "which poetry"
    assert_command_fails_in_container "$image" "which black"
}

# Test: Node.js minimal installation
test_node_minimal() {
    local image="test-node-minimal-$$"
    
    # Build with just Node.js (no dev tools)
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_NAME=test-node \
        --build-arg INCLUDE_NODE=true \
        -t "$image"
    
    # Verify Node.js is installed
    assert_executable_in_path "$image" "node"
    assert_command_in_container "$image" "node --version" "v"
    
    # Verify npm is available
    assert_executable_in_path "$image" "npm"
    
    # Verify dev tools are NOT installed
    assert_command_fails_in_container "$image" "which tsc"
    assert_command_fails_in_container "$image" "which jest"
}

# Run all tests
run_test test_base_container_only "Base container builds with no features"
run_test test_custom_user_configuration "Custom user and paths work correctly"
run_test test_python_minimal "Python minimal installation works"
run_test test_node_minimal "Node.js minimal installation works"

# Generate test report
generate_report