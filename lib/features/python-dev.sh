#!/bin/bash
# Python Development Tools - Testing, linting, formatting, and documentation
#
# Description:
#   Installs comprehensive Python development tools for testing, code quality,
#   and documentation. All tools are installed via pipx for isolation.
#
# Features:
#   - Testing: pytest, pytest-cov, pytest-xdist, pytest-asyncio, tox
#   - Formatting: black, isort, ruff
#   - Linting: flake8, mypy, pylint, bandit, pip-audit
#   - Documentation: sphinx, sphinx-autobuild, doc8
#   - Utilities: cookiecutter, rich-cli, httpie, yq
#   - Interactive: jupyter, jupyterlab, ipython
#   - Pre-commit hooks
#   - LSP: python-lsp-server with black and ruff plugins, pyright
#
# Note:
#   Requires INCLUDE_PYTHON feature to be enabled first.
#   All tools are installed in isolated environments via pipx.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Python Development Tools"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing Python development dependencies..."

# Update package lists with retry logic
apt_update

# Install Python development dependencies with retry logic
apt_install \
    python3-dev \
    python3-full \
    python3-distutils \
    python3-venv \
    python3-tk \
    libpq-dev \
    libxml2-dev \
    libxslt1-dev \
    libldap2-dev \
    libsasl2-dev \
    libffi-dev \
    libjpeg-dev \
    zlib1g-dev

# ============================================================================
# Python Tool Installation
# ============================================================================
log_message "Checking prerequisites..."

# Check if Python is available
if [ ! -f "/usr/local/bin/python" ]; then
    log_error "Python not found at /usr/local/bin/python"
    log_error "The INCLUDE_PYTHON feature must be enabled first"
    log_feature_end
    exit 1
fi

# Install Python tools globally via pip
# Since we're in a container, global installation is appropriate
log_message "Installing development tools..."

# Get cache directories from environment or use defaults
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/cache/pip}"

# Upgrade pip first as the user
log_command "Upgrading pip, setuptools, and wheel" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python -m pip install --upgrade --no-warn-script-location pip setuptools wheel"

# Development tools - install in one command for better dependency resolution
log_message "Installing Python development tools..."
# Use --only-binary :all: to prefer compiled wheels where available
# Run as user to ensure correct ownership
log_command "Installing Python development packages" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python -m pip install --no-warn-script-location --prefer-binary \
    'black[jupyter]' \
    isort \
    ruff \
    flake8 \
    mypy \
    pylint \
    bandit \
    pip-audit \
    pytest \
    pytest-cov \
    pytest-xdist \
    pytest-asyncio \
    tox \
    pre-commit \
    cookiecutter \
    rich-cli \
    sphinx \
    sphinx-autobuild \
    doc8 \
    jupyter \
    jupyterlab \
    ipython \
    httpie \
    yq"

# ============================================================================
# Create symlinks for Python development tools
# ============================================================================
log_message "Creating symlinks for Python development tools..."

# Since we're installing directly from source, tools are in /usr/local/bin
# Check if any tools need alternative names
PYTHON_BIN_DIR="/usr/local/bin"

# Some tools install with different names or need alternative commands
declare -A alt_tools=(
    ["py.test"]="pytest"         # Alternative pytest command
    ["ipython3"]="ipython"       # ipython3 -> ipython
)

for alt_cmd in "${!alt_tools[@]}"; do
    source_cmd="${alt_tools[$alt_cmd]}"
    # Check if the source command exists and alt doesn't
    if [ -f "${PYTHON_BIN_DIR}/${source_cmd}" ] && [ ! -f "${PYTHON_BIN_DIR}/${alt_cmd}" ]; then
        create_symlink "${PYTHON_BIN_DIR}/${source_cmd}" "${PYTHON_BIN_DIR}/${alt_cmd}" "${alt_cmd} command"
    fi
done

# ============================================================================
# Configure system-wide environment
# ============================================================================
echo "=== Configuring system-wide Python dev environment ==="

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create Python dev tools configuration
write_bashrc_content /etc/bashrc.d/25-python-dev.sh "Python dev tools configuration" << 'PYTHON_DEV_BASHRC_EOF'
# Python development tools configuration

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Jupyter configuration
export JUPYTER_CONFIG_DIR="${JUPYTER_CONFIG_DIR:-$HOME/.jupyter}"
# Use new platformdirs to avoid deprecation warning
export JUPYTER_PLATFORM_DIRS=1

# IPython configuration
export IPYTHONDIR="${IPYTHONDIR:-$HOME/.ipython}"

# Pre-commit cache
export PRE_COMMIT_HOME="${PRE_COMMIT_HOME:-$HOME/.cache/pre-commit}"

# MyPy cache
export MYPY_CACHE_DIR="${MYPY_CACHE_DIR:-$HOME/.mypy_cache}"

# Black cache
export BLACK_CACHE_DIR="${BLACK_CACHE_DIR:-$HOME/.cache/black}"

# Pylint configuration
export PYLINTHOME="${PYLINTHOME:-$HOME/.cache/pylint}"

# Set Python development mode for better error messages
export PYTHONDEVMODE=1

# All Python development tools are installed globally via pip
# They are available in /usr/local/bin alongside Python itself
PYTHON_DEV_BASHRC_EOF

log_command "Setting Python dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/25-python-dev.sh

# ============================================================================
# Create helpful aliases
# ============================================================================
log_message "Setting up Python development aliases..."

write_bashrc_content /etc/bashrc.d/25-python-dev.sh "Python development aliases" << 'PYTHON_DEV_ALIASES_EOF'

# Python development aliases
alias fmt='black . && isort .'
alias lint='flake8 && mypy . && pylint **/*.py'
alias test='pytest'
alias testv='pytest -v'
alias testcov='pytest --cov=. --cov-report=html'
alias notebook='jupyter notebook'
alias lab='jupyter lab'
alias ipy='ipython'

# Smart wrapper functions that detect and use Poetry when available
# These override the aliases when Poetry is detected
_smart_pytest() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run pytest "$@"
    else
        command pytest "$@"
    fi
}

_smart_pytest_verbose() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run pytest -v "$@"
    else
        command pytest -v "$@"
    fi
}

_smart_pytest_coverage() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run pytest --cov=. --cov-report=html "$@"
    else
        command pytest --cov=. --cov-report=html "$@"
    fi
}

_smart_format() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run black . && poetry run isort .
    else
        command black . && command isort .
    fi
}

_smart_lint() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run flake8 && poetry run mypy . && poetry run pylint **/*.py
    else
        command flake8 && command mypy . && command pylint **/*.py
    fi
}

_smart_ipython() {
    if [ -f "pyproject.toml" ] && command -v poetry &> /dev/null && poetry env info --path &> /dev/null; then
        poetry run ipython "$@"
    else
        command ipython "$@"
    fi
}

# Override aliases with functions when in interactive mode
# This allows the smart detection to work while keeping familiar command names
if [[ $- == *i* ]]; then
    function test() { _smart_pytest "$@"; }
    function testv() { _smart_pytest_verbose "$@"; }
    function testcov() { _smart_pytest_coverage "$@"; }
    function fmt() { _smart_format "$@"; }
    function lint() { _smart_lint "$@"; }
    function ipy() { _smart_ipython "$@"; }
fi

# Pre-commit helpers
alias pc='pre-commit'
alias pcall='pre-commit run --all-files'
alias pcinstall='pre-commit install'

# Unified workflow aliases
alias py-format-all='black . && isort .'
alias py-lint-all='ruff check . && flake8 && mypy . && pylint **/*.py 2>/dev/null || true'
alias py-security-check='bandit -r . && pip-audit'
PYTHON_DEV_ALIASES_EOF

# ============================================================================
# Python Language Server (for IDE support)
# ============================================================================
log_message "Installing Python language server for IDE support..."

# Install python-lsp-server with formatting and linting plugins
# - python-lsp-server: Core LSP implementation
# - python-lsp-black: Black formatter integration
# - python-lsp-ruff: Ruff linter integration (fast, replaces flake8/isort)
log_command "Installing python-lsp-server with plugins" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python -m pip install --no-warn-script-location --prefer-binary \
    python-lsp-server \
    python-lsp-black \
    python-lsp-ruff"

# Verify LSP installation
if command -v pylsp &>/dev/null; then
    log_message "Python LSP installed successfully"
else
    log_warning "Python LSP installation could not be verified"
fi

# Install pyright (type checker and language server)
# Required by the pyright-lsp Claude Code plugin for type checking integration.
# The pip package is a wrapper that bundles the pyright Node.js binary.
log_command "Installing pyright" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python -m pip install --no-warn-script-location --prefer-binary pyright"

# Verify pyright installation
if command -v pyright &>/dev/null; then
    log_message "Pyright installed successfully"
else
    log_warning "Pyright installation could not be verified"
fi

# ============================================================================
# Final verification
# ============================================================================
log_message "Verifying Python development tools installation..."

# Check key tools
log_command "Checking black version" \
    /usr/local/bin/black --version || log_warning "black installation failed"

log_command "Checking pytest version" \
    /usr/local/bin/pytest --version || log_warning "pytest installation failed"

log_command "Checking mypy version" \
    /usr/local/bin/mypy --version || log_warning "mypy installation failed"

log_command "Checking jupyter version" \
    /usr/local/bin/jupyter --version || log_warning "jupyter installation failed"

log_command "Checking ipython version" \
    /usr/local/bin/ipython --version || log_warning "ipython installation failed"

log_command "Checking ruff version" \
    /usr/local/bin/ruff --version || log_warning "ruff installation failed"

log_command "Checking pip-audit version" \
    /usr/local/bin/pip-audit --version || log_warning "pip-audit installation failed"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Python directories..."
log_command "Final ownership fix for Python cache directories" \
    chown -R "${USER_UID}:${USER_GID}" "${PIP_CACHE_DIR}" || true

# Log feature summary
# Export directory paths for feature summary (also defined in parent python.sh)
export PIP_CACHE_DIR="/cache/pip"

log_feature_summary \
    --feature "Python Development Tools" \
    --tools "ipython,pytest,black,ruff,mypy,pylint,bandit,pip-audit,pyright" \
    --paths "${PIP_CACHE_DIR}" \
    --env "PIP_CACHE_DIR" \
    --commands "ipython,pytest,black,ruff,mypy,pylint,bandit,pip-audit,py-lint-all,py-format-all,py-security-check" \
    --next-steps "Run 'test-python-dev' to verify installation. Use 'black .' to format code, 'pytest' to run tests, 'ruff check .' to lint, 'mypy .' for type checking, 'py-security-check' for security scanning."

# End logging
log_feature_end

echo ""
echo "Run 'check-build-logs.sh python-development-tools' to review installation logs"
