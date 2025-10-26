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
    local image="${IMAGE_TO_TEST:-test-polyglot-$$}"

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
    local image="${IMAGE_TO_TEST:-test-polyglot-$$}"

    # Python: poetry
    assert_command_in_container "$image" "poetry --version" "Poetry"

    # Node.js: npm
    assert_command_in_container "$image" "npm --version" ""
}

# Test: Python development tools work
test_python_dev_tools() {
    local image="${IMAGE_TO_TEST:-test-polyglot-$$}"

    # Black can format
    assert_command_in_container "$image" "echo 'x=1' | black -" ""

    # Pytest exists
    assert_command_in_container "$image" "pytest --version" ""

    # Python can import packages
    assert_command_in_container "$image" "python -c 'import json, sys; print(sys.version_info.major)'" "3"
}

# Test: Node development tools work
test_node_dev_tools() {
    local image="${IMAGE_TO_TEST:-test-polyglot-$$}"

    # TypeScript can compile
    assert_command_in_container "$image" "cd /tmp && echo 'const x: number = 1; console.log(x);' > test.ts && tsc test.ts && test -f test.js && echo ok" "ok"

    # ESLint exists
    assert_command_in_container "$image" "eslint --version" ""

    # Jest exists
    assert_command_in_container "$image" "jest --version" ""
}

# Test: Cross-language interop scenario
test_cross_language_workflow() {
    local image="${IMAGE_TO_TEST:-test-polyglot-$$}"

    # Python can call Node script
    assert_command_in_container "$image" "cd /tmp && echo 'console.log(JSON.stringify({result: 42}))' > script.js && python -c \"import subprocess, json; r = subprocess.run(['node', 'script.js'], capture_output=True, text=True); print(json.loads(r.stdout)['result'])\"" "42"
}

# Test: Database clients work
test_polyglot_database_clients() {
    local image="${IMAGE_TO_TEST:-test-polyglot-$$}"

    # PostgreSQL client
    assert_command_in_container "$image" "psql --version" "psql"

    # Redis client
    assert_command_in_container "$image" "redis-cli --version" "redis-cli"

    # SQLite
    assert_command_in_container "$image" "sqlite3 --version" "3."
}

# Test: Cache directories configured
test_polyglot_cache() {
    local image="${IMAGE_TO_TEST:-test-polyglot-$$}"

    # Python cache
    assert_command_in_container "$image" "test -w /cache/pip && echo writable" "writable"

    # Node cache
    assert_command_in_container "$image" "test -w /cache/npm && echo writable" "writable"
}

# Run all tests
run_test test_polyglot_build "Polyglot environment builds successfully"
run_test test_language_coexistence "Python and Node.js coexist properly"
run_test test_polyglot_package_managers "Package managers work for both languages"
run_test test_python_dev_tools "Python development tools work"
run_test test_node_dev_tools "Node development tools work"
run_test test_cross_language_workflow "Cross-language workflow works"
run_test test_polyglot_database_clients "Database clients are functional"
run_test test_polyglot_cache "Cache directories are configured"

# Generate test report
generate_report
