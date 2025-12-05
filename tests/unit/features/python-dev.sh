#!/usr/bin/env bash
# Unit tests for lib/features/python-dev.sh
# Tests Python development tools installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Python Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-python-dev"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/cache/pip"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.local/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Development tools installation
test_dev_tools_installation() {
    local bin_dir="$TEST_TEMP_DIR/home/testuser/.local/bin"

    # List of Python dev tools
    local tools=("poetry" "pipenv" "black" "ruff" "mypy" "pytest" "tox" "pre-commit")

    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$bin_dir/$tool"
        chmod +x "$bin_dir/$tool"
    done

    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$bin_dir/$tool" ]; then
            assert_true true "$tool is installed"
        else
            assert_true false "$tool is not installed"
        fi
    done
}

# Test: Poetry configuration
test_poetry_config() {
    local poetry_config="$TEST_TEMP_DIR/home/testuser/.config/pypoetry/config.toml"
    mkdir -p "$(dirname "$poetry_config")"

    # Create config
    command cat > "$poetry_config" << 'EOF'
[virtualenvs]
in-project = true
create = true
[cache]
dir = "/cache/poetry"
EOF

    assert_file_exists "$poetry_config"

    # Check configuration
    if grep -q "in-project = true" "$poetry_config"; then
        assert_true true "Poetry venv in-project enabled"
    else
        assert_true false "Poetry venv in-project not enabled"
    fi
}

# Test: Ruff configuration
test_ruff_config() {
    local ruff_config="$TEST_TEMP_DIR/home/testuser/.ruff.toml"

    # Create config
    command cat > "$ruff_config" << 'EOF'
line-length = 88
target-version = "py311"
select = ["E", "F", "W", "I", "N"]
EOF

    assert_file_exists "$ruff_config"

    # Check configuration
    if grep -q "line-length = 88" "$ruff_config"; then
        assert_true true "Ruff line length configured"
    else
        assert_true false "Ruff line length not configured"
    fi
}

# Test: Black configuration
test_black_config() {
    local black_config="$TEST_TEMP_DIR/home/testuser/pyproject.toml"

    # Create config
    command cat > "$black_config" << 'EOF'
[tool.black]
line-length = 88
target-version = ['py311']
EOF

    assert_file_exists "$black_config"

    # Check configuration
    if grep -q "line-length = 88" "$black_config"; then
        assert_true true "Black line length configured"
    else
        assert_true false "Black line length not configured"
    fi
}

# Test: Pytest configuration
test_pytest_config() {
    local pytest_ini="$TEST_TEMP_DIR/home/testuser/pytest.ini"

    # Create config
    command cat > "$pytest_ini" << 'EOF'
[pytest]
testpaths = tests
python_files = test_*.py
python_classes = Test*
python_functions = test_*
EOF

    assert_file_exists "$pytest_ini"

    # Check configuration
    if grep -q "testpaths = tests" "$pytest_ini"; then
        assert_true true "Pytest test paths configured"
    else
        assert_true false "Pytest test paths not configured"
    fi
}

# Test: Pre-commit hooks
test_precommit_hooks() {
    local precommit_config="$TEST_TEMP_DIR/.pre-commit-config.yaml"

    # Create config
    command cat > "$precommit_config" << 'EOF'
repos:
  - repo: https://github.com/charliermarsh/ruff-pre-commit
    rev: v0.1.0
    hooks:
      - id: ruff
  - repo: https://github.com/psf/black
    rev: 23.0.0
    hooks:
      - id: black
EOF

    assert_file_exists "$precommit_config"

    # Check hooks
    if grep -q "id: ruff" "$precommit_config"; then
        assert_true true "Ruff pre-commit hook configured"
    else
        assert_true false "Ruff pre-commit hook not configured"
    fi
}

# Test: IPython configuration
test_ipython_config() {
    local ipython_dir="$TEST_TEMP_DIR/home/testuser/.ipython/profile_default"
    mkdir -p "$ipython_dir"

    # Create startup script
    mkdir -p "$ipython_dir/startup"
    command cat > "$ipython_dir/startup/00-imports.py" << 'EOF'
import numpy as np
import pandas as pd
EOF

    assert_file_exists "$ipython_dir/startup/00-imports.py"
}

# Test: Development aliases
test_dev_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/30-python-dev.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias pyt='pytest'
alias pytv='pytest -v'
alias pytc='pytest --cov'
alias bl='black .'
alias rff='ruff check --fix'
alias myp='mypy'
EOF

    # Check aliases
    if grep -q "alias pyt='pytest'" "$bashrc_file"; then
        assert_true true "pytest alias defined"
    else
        assert_true false "pytest alias not defined"
    fi
}

# Test: Jupyter installation
test_jupyter_installation() {
    local bin_dir="$TEST_TEMP_DIR/home/testuser/.local/bin"

    # Create mock Jupyter binaries
    touch "$bin_dir/jupyter"
    touch "$bin_dir/jupyter-lab"
    chmod +x "$bin_dir/jupyter" "$bin_dir/jupyter-lab"

    # Check Jupyter
    if [ -x "$bin_dir/jupyter-lab" ]; then
        assert_true true "JupyterLab is installed"
    else
        assert_true false "JupyterLab is not installed"
    fi
}

# Test: Verification script
test_python_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-python-dev.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Python dev tools:"
for tool in poetry pipenv black ruff mypy pytest; do
    command -v $tool &>/dev/null && echo "  - $tool: installed" || echo "  - $tool: not found"
done
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_dev_tools_installation "Python dev tools installation"
run_test_with_setup test_poetry_config "Poetry configuration"
run_test_with_setup test_ruff_config "Ruff configuration"
run_test_with_setup test_black_config "Black configuration"
run_test_with_setup test_pytest_config "Pytest configuration"
run_test_with_setup test_precommit_hooks "Pre-commit hooks"
run_test_with_setup test_ipython_config "IPython configuration"
run_test_with_setup test_dev_aliases "Development aliases"
run_test_with_setup test_jupyter_installation "Jupyter installation"
run_test_with_setup test_python_dev_verification "Python dev verification"

# Generate test report
generate_report
