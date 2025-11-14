#!/usr/bin/env bash
# Test production container builds
#
# This test verifies that production-optimized containers build successfully
# with the correct security and size optimizations.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Production Container Builds"

# Test: Minimal production base
test_minimal_production_base() {
    local image="test-prod-minimal-$$"
    echo "Building minimal production base: $image"

    # Build minimal production container
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-prod \
        --build-arg BASE_IMAGE=debian:bookworm-slim \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        --build-arg INCLUDE_DEV_TOOLS=false \
        --build-arg INCLUDE_PYTHON=false \
        --build-arg INCLUDE_NODE=false \
        -t "$image"

    # Verify basic functionality
    assert_command_in_container "$image" "whoami" "developer"
    assert_command_in_container "$image" "pwd" "/workspace/test-prod"

    # Verify NO passwordless sudo (should fail)
    assert_command_fails_in_container "$image" "sudo -n echo test"

    # Verify dev tools are NOT installed
    assert_executable_not_in_path "$image" "vim"
    assert_executable_not_in_path "$image" "tmux"

    # Verify base tools ARE available
    assert_executable_in_path "$image" "bash"
    assert_executable_in_path "$image" "curl"

    # Clean up
    docker rmi -f "$image" > /dev/null 2>&1 || true
}

# Test: Python production runtime
test_python_production_runtime() {
    local image="test-prod-python-$$"
    echo "Building Python production runtime: $image"

    # Build Python production container (runtime only, no dev tools)
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-prod \
        --build-arg BASE_IMAGE=debian:bookworm-slim \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        --build-arg INCLUDE_PYTHON=true \
        --build-arg INCLUDE_PYTHON_DEV=false \
        --build-arg PYTHON_VERSION=3.12.0 \
        --build-arg INCLUDE_DEV_TOOLS=false \
        -t "$image"

    # Verify Python runtime IS installed
    assert_executable_in_path "$image" "python3"
    assert_executable_in_path "$image" "pip3"

    # Verify Python works
    assert_command_in_container "$image" "python3 --version" "Python 3.12.0"

    # Verify Python dev tools are NOT installed
    assert_executable_not_in_path "$image" "ipython"
    assert_executable_not_in_path "$image" "black"
    assert_executable_not_in_path "$image" "mypy"
    assert_executable_not_in_path "$image" "pytest"

    # Verify pip works but pip-tools is not installed
    assert_command_in_container "$image" "pip3 --version" "pip"
    assert_executable_not_in_path "$image" "pip-compile"
    assert_executable_not_in_path "$image" "pip-sync"

    # Clean up
    docker rmi -f "$image" > /dev/null 2>&1 || true
}

# Test: Node production runtime
test_node_production_runtime() {
    local image="test-prod-node-$$"
    echo "Building Node production runtime: $image"

    # Build Node production container (runtime only, no dev tools)
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-prod \
        --build-arg BASE_IMAGE=debian:bookworm-slim \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        --build-arg INCLUDE_NODE=true \
        --build-arg INCLUDE_NODE_DEV=false \
        --build-arg NODE_VERSION=20 \
        --build-arg INCLUDE_DEV_TOOLS=false \
        -t "$image"

    # Verify Node runtime IS installed
    assert_executable_in_path "$image" "node"
    assert_executable_in_path "$image" "npm"

    # Verify Node works
    assert_command_in_container "$image" "node --version" "v20"

    # Verify Node dev tools are NOT installed
    assert_executable_not_in_path "$image" "tsc"  # typescript
    assert_executable_not_in_path "$image" "eslint"
    assert_executable_not_in_path "$image" "prettier"
    assert_executable_not_in_path "$image" "nodemon"
    assert_executable_not_in_path "$image" "ts-node"

    # Clean up
    docker rmi -f "$image" > /dev/null 2>&1 || true
}

# Test: Multi-runtime production (Python + Ruby + Node)
test_multi_runtime_production() {
    local image="test-prod-multi-$$"
    echo "Building multi-runtime production: $image"

    # Build production container with Python, Ruby, and Node (no dev tools)
    # This tests:
    # 1. Multiple runtimes work together in production
    # 2. Ruby coverage (not tested elsewhere in integration tests)
    # 3. All runtime-only, no dev tools
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-prod \
        --build-arg BASE_IMAGE=debian:bookworm-slim \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        --build-arg INCLUDE_PYTHON=true \
        --build-arg INCLUDE_PYTHON_DEV=false \
        --build-arg PYTHON_VERSION=3.12.0 \
        --build-arg INCLUDE_RUBY=true \
        --build-arg INCLUDE_RUBY_DEV=false \
        --build-arg RUBY_VERSION=3.4.7 \
        --build-arg INCLUDE_NODE=true \
        --build-arg INCLUDE_NODE_DEV=false \
        --build-arg NODE_VERSION=20.18.0 \
        --build-arg INCLUDE_DEV_TOOLS=false \
        -t "$image"

    # Verify Python runtime IS installed
    assert_executable_in_path "$image" "python3"
    assert_executable_in_path "$image" "pip3"
    assert_command_in_container "$image" "python3 --version" "Python 3.12.0"

    # Verify Ruby runtime IS installed
    assert_executable_in_path "$image" "ruby"
    assert_executable_in_path "$image" "gem"
    assert_command_in_container "$image" "ruby --version" "ruby 3.4.7"

    # Verify Node runtime IS installed
    assert_executable_in_path "$image" "node"
    assert_executable_in_path "$image" "npm"
    assert_command_in_container "$image" "node --version" "v20"

    # Verify Python dev tools are NOT installed
    assert_executable_not_in_path "$image" "ipython"
    assert_executable_not_in_path "$image" "black"

    # Verify Ruby dev tools are NOT installed
    assert_executable_not_in_path "$image" "rubocop"
    assert_executable_not_in_path "$image" "solargraph"

    # Verify Node dev tools are NOT installed
    assert_executable_not_in_path "$image" "tsc"
    assert_executable_not_in_path "$image" "eslint"

    # Verify general dev tools are NOT installed
    assert_executable_not_in_path "$image" "vim"
    assert_executable_not_in_path "$image" "tmux"

    # Clean up
    docker rmi -f "$image" > /dev/null 2>&1 || true
}

# Test: Production security configuration
test_production_security() {
    local image="test-prod-security-$$"
    echo "Building production container for security test: $image"

    # Build production container
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-prod \
        --build-arg BASE_IMAGE=debian:bookworm-slim \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        --build-arg INCLUDE_DEV_TOOLS=false \
        -t "$image"

    # Verify NO passwordless sudo
    assert_command_fails_in_container "$image" "sudo -n whoami"

    # Verify user is non-root
    local uid
    uid=$(docker run --rm "$image" id -u 2>/dev/null | tail -1)
    if [ "$uid" -eq 0 ]; then
        fail_test "Container should run as non-root user (uid: $uid)"
    fi

    # Clean up
    docker rmi -f "$image" > /dev/null 2>&1 || true
}

# Test: Production image size is reasonable
test_production_image_size() {
    local image="test-prod-size-$$"
    echo "Building production container for size test: $image"

    # Build minimal production container
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-prod \
        --build-arg BASE_IMAGE=debian:bookworm-slim \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        --build-arg INCLUDE_DEV_TOOLS=false \
        --build-arg INCLUDE_PYTHON=false \
        --build-arg INCLUDE_NODE=false \
        -t "$image"

    # Get image size in bytes
    local size_bytes
    size_bytes=$(docker inspect --format='{{.Size}}' "$image")
    local size_mb=$((size_bytes / 1024 / 1024))

    echo "Production minimal image size: ${size_mb}MB"

    # Minimal production should be under 500MB (typically ~200-300MB)
    if [ "$size_mb" -gt 500 ]; then
        fail_test "Production minimal image too large: ${size_mb}MB (expected < 500MB)"
    fi

    # Clean up
    docker rmi -f "$image" > /dev/null 2>&1 || true
}

# Test: Healthcheck script is available in production
test_production_healthcheck() {
    local image="test-prod-health-$$"
    echo "Building production container for healthcheck test: $image"

    # Build production container
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-prod \
        --build-arg BASE_IMAGE=debian:bookworm-slim \
        --build-arg ENABLE_PASSWORDLESS_SUDO=false \
        -t "$image"

    # Verify healthcheck script exists and is executable
    assert_executable_in_path "$image" "healthcheck"

    # Verify healthcheck runs successfully
    assert_command_in_container "$image" "/usr/local/bin/healthcheck --quick" ""

    # Clean up
    docker rmi -f "$image" > /dev/null 2>&1 || true
}

# Helper function to check if executable is NOT in path
assert_executable_not_in_path() {
    local image="$1"
    local executable="$2"

    if docker run --rm "$image" which "$executable" > /dev/null 2>&1; then
        fail_test "Executable '$executable' should NOT be in PATH for production image"
    fi
}

# Helper function to test command failure
assert_command_fails_in_container() {
    local image="$1"
    local command="$2"

    if docker run --rm "$image" bash -c "$command" > /dev/null 2>&1; then
        fail_test "Command '$command' should fail in production image"
    fi
}

# Run all tests
run_test test_minimal_production_base "Minimal production base builds successfully"
run_test test_python_production_runtime "Python production runtime builds with correct packages"
run_test test_node_production_runtime "Node production runtime builds with correct packages"
run_test test_multi_runtime_production "Multi-runtime production (Python+Ruby+Node) builds correctly"
run_test test_production_security "Production security configuration is correct"
run_test test_production_image_size "Production image size is reasonable"
run_test test_production_healthcheck "Production healthcheck script is available"

# Generate test report
generate_report
