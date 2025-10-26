#!/usr/bin/env bash
# Test polyglot container build
#
# This test verifies the polyglot configuration that includes:
# - Python with development tools
# - Node.js with development tools
# - Development tools (git, gh, etc.)
# - Docker CLI
# - 1Password CLI
# - Database clients

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Polyglot Container Build"

# Test: Polyglot environment builds successfully
test_polyglot_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-polyglot-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-polyglot \
            --build-arg INCLUDE_PYTHON_DEV=true \
            --build-arg INCLUDE_NODE_DEV=true \
            --build-arg INCLUDE_DEV_TOOLS=true \
            --build-arg INCLUDE_DOCKER=true \
            --build-arg INCLUDE_OP=true \
            --build-arg INCLUDE_POSTGRES_CLIENT=true \
            --build-arg INCLUDE_REDIS_CLIENT=true \
            --build-arg INCLUDE_SQLITE_CLIENT=true \
            -t "$image"
    fi

    # Verify Python tools
    assert_executable_in_path "$image" "python"
    assert_executable_in_path "$image" "poetry"
    assert_executable_in_path "$image" "black"

    # Verify Node.js tools
    assert_executable_in_path "$image" "node"
    assert_executable_in_path "$image" "npm"
    assert_executable_in_path "$image" "tsc"

    # Verify dev tools
    assert_executable_in_path "$image" "git"
    assert_executable_in_path "$image" "docker"

    # Verify database clients
    assert_executable_in_path "$image" "psql"
    assert_executable_in_path "$image" "redis-cli"
}

# Test: Python and Node.js can coexist
test_language_coexistence() {
    local image="test-polyglot-$$"

    # Test Python
    assert_command_in_container "$image" "python --version" "Python 3."

    # Test Node.js
    assert_command_in_container "$image" "node --version" "v"

    # Test both can execute simple commands
    assert_command_in_container "$image" "python -c 'print(2+2)'" "4"
    assert_command_in_container "$image" "node -e 'console.log(2+2)'" "4"
}

# Test: Package managers work for both languages
test_polyglot_package_managers() {
    local image="test-polyglot-$$"

    # Python: poetry
    assert_command_in_container "$image" "poetry --version" "Poetry"

    # Node.js: npm
    assert_command_in_container "$image" "npm --version" ""
}

# Run all tests
run_test test_polyglot_build "Polyglot environment builds successfully"
run_test test_language_coexistence "Python and Node.js coexist properly"
run_test test_polyglot_package_managers "Package managers work for both languages"

# Generate test report
generate_report
