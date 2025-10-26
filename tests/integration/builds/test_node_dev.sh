#!/usr/bin/env bash
# Test node-dev container build
#
# This test verifies the node-dev configuration that includes:
# - Node.js with development tools
# - 1Password CLI
# - Development tools (git, gh, fzf, etc.)
# - Database clients (PostgreSQL, Redis, SQLite)
# - Docker CLI

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Node Dev Container Build"

# Test: Node dev environment builds successfully
test_node_dev_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-node-dev-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-node-dev \
            --build-arg INCLUDE_NODE_DEV=true \
            --build-arg INCLUDE_OP=true \
            --build-arg INCLUDE_DEV_TOOLS=true \
            --build-arg INCLUDE_POSTGRES_CLIENT=true \
            --build-arg INCLUDE_REDIS_CLIENT=true \
            --build-arg INCLUDE_SQLITE_CLIENT=true \
            --build-arg INCLUDE_DOCKER=true \
            -t "$image"
    fi

    # Verify Node.js and package managers
    assert_executable_in_path "$image" "node"
    assert_executable_in_path "$image" "npm"
    assert_executable_in_path "$image" "yarn"
    assert_executable_in_path "$image" "pnpm"

    # Verify Node.js development tools
    assert_executable_in_path "$image" "tsc"
    assert_executable_in_path "$image" "eslint"
    assert_executable_in_path "$image" "jest"

    # Verify dev tools
    assert_executable_in_path "$image" "git"
    assert_executable_in_path "$image" "gh"

    # Verify database clients
    assert_executable_in_path "$image" "psql"
    assert_executable_in_path "$image" "redis-cli"

    # Verify Docker CLI
    assert_executable_in_path "$image" "docker"
}

# Test: TypeScript compiler works
test_typescript() {
    local image="test-node-dev-$$"

    # Test TypeScript version
    assert_command_in_container "$image" "tsc --version" "Version"
}

# Test: Node package managers work
test_package_managers() {
    local image="test-node-dev-$$"

    # Test npm
    assert_command_in_container "$image" "npm --version" ""

    # Test yarn
    assert_command_in_container "$image" "yarn --version" ""

    # Test pnpm
    assert_command_in_container "$image" "pnpm --version" ""
}

# Run all tests
run_test test_node_dev_build "Node dev environment builds successfully"
run_test test_typescript "TypeScript compiler is functional"
run_test test_package_managers "Node package managers work"

# Generate test report
generate_report
