#!/usr/bin/env bash
# Test python-dev container build
#
# This test verifies the python-dev configuration that includes:
# - Python with development tools
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
test_suite "Python Dev Container Build"

# Test: Python dev environment builds successfully
test_python_dev_build() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-python-dev-$$"
        echo "Building image locally: $image"

        # Build with python-dev configuration (matches CI)
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-python-dev \
            --build-arg INCLUDE_PYTHON_DEV=true \
            --build-arg INCLUDE_OP=true \
            --build-arg INCLUDE_DEV_TOOLS=true \
            --build-arg INCLUDE_POSTGRES_CLIENT=true \
            --build-arg INCLUDE_REDIS_CLIENT=true \
            --build-arg INCLUDE_SQLITE_CLIENT=true \
            --build-arg INCLUDE_DOCKER=true \
            -t "$image"
    fi

    # Verify Python development tools
    assert_executable_in_path "$image" "python"
    assert_executable_in_path "$image" "poetry"
    assert_executable_in_path "$image" "black"
    assert_executable_in_path "$image" "ruff"
    assert_executable_in_path "$image" "mypy"
    assert_executable_in_path "$image" "pytest"
    assert_executable_in_path "$image" "pip-audit"

    # Verify Python LSP (for IDE support)
    assert_executable_in_path "$image" "pylsp"
    assert_executable_in_path "$image" "pyright"

    # Verify dev tools
    assert_executable_in_path "$image" "git"
    assert_executable_in_path "$image" "gh"
    assert_executable_in_path "$image" "fzf"

    # Verify database clients
    assert_executable_in_path "$image" "psql"
    assert_executable_in_path "$image" "redis-cli"
    assert_executable_in_path "$image" "sqlite3"

    # Verify Docker CLI
    assert_executable_in_path "$image" "docker"

    # Verify 1Password CLI
    assert_executable_in_path "$image" "op"
}

# Test: Python can import standard libraries
test_python_stdlib() {
    local image="${IMAGE_TO_TEST:-test-python-dev-$$}"

    # Test common stdlib imports
    assert_command_in_container "$image" "python -c 'import json, os, sys, sqlite3'" ""
    assert_command_in_container "$image" "python -c 'import urllib.request'" ""
}

# Test: Poetry creates virtualenvs in project
test_poetry_configuration() {
    local image="${IMAGE_TO_TEST:-test-python-dev-$$}"

    # Check poetry config
    assert_command_in_container "$image" "poetry config virtualenvs.in-project" "true"
}

# Test: Database clients can show version
test_database_clients() {
    local image="${IMAGE_TO_TEST:-test-python-dev-$$}"

    # PostgreSQL client
    assert_command_in_container "$image" "psql --version" "psql"

    # Redis client
    assert_command_in_container "$image" "redis-cli --version" "redis-cli"

    # SQLite
    assert_command_in_container "$image" "sqlite3 --version" "3."
}

# Test: Python development tools actually work
test_python_tools_work() {
    local image="${IMAGE_TO_TEST:-test-python-dev-$$}"

    # Black can format code
    assert_command_in_container "$image" "echo 'x=1' | black -" ""

    # Ruff can check valid code (should pass with no issues)
    assert_command_in_container "$image" "echo 'print(\"hello\")' | ruff check --stdin-filename=test.py -" ""

    # Pytest can run (with no tests, exits 5)
    assert_command_in_container "$image" "cd /tmp && pytest --collect-only 2>&1 || test \$? -eq 5 && echo ok" "ok"

    # IPython can show version
    assert_command_in_container "$image" "ipython --version" ""

    # pip-audit can run (with no packages or vulnerabilities, exits 0)
    assert_command_in_container "$image" "pip-audit --version" "pip-audit"
}

# Test: Package installation works
test_pip_install() {
    local image="${IMAGE_TO_TEST:-test-python-dev-$$}"

    # Pip can install a simple package
    assert_command_in_container "$image" "pip install --user --no-warn-script-location requests && python -c 'import requests; print(requests.__version__)'" ""
}

# Test: Cache directories are configured
test_python_cache() {
    local image="${IMAGE_TO_TEST:-test-python-dev-$$}"

    # Pip cache directory exists and is writable
    assert_command_in_container "$image" "test -w /cache/pip && echo writable" "writable"

    # Poetry cache is configured
    assert_command_in_container "$image" "poetry config cache-dir" "/cache/poetry"
}

# Run all tests
run_test test_python_dev_build "Python dev environment builds successfully"
run_test test_python_stdlib "Python can import standard libraries"
run_test test_poetry_configuration "Poetry is configured correctly"
run_test test_database_clients "Database clients are functional"
run_test test_python_tools_work "Python development tools work correctly"
run_test test_pip_install "Pip can install packages"
run_test test_python_cache "Python cache directories are configured"

# Generate test report
generate_report
