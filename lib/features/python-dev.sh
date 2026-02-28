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

# python3-distutils was removed in Debian 13 (merged into python3-stdlib-extensions)
apt_install_conditional 11 12 python3-distutils

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

# Tools are installed as user, binaries are in ~/.local/bin
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

# Create Python dev tools configuration (content in lib/bashrc/python-dev-config.sh)
write_bashrc_content /etc/bashrc.d/25-python-dev.sh "Python dev tools configuration" \
    < /tmp/build-scripts/features/lib/bashrc/python-dev-config.sh

log_command "Setting Python dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/25-python-dev.sh

# ============================================================================
# Create helpful aliases
# ============================================================================
log_message "Setting up Python development aliases..."

# Python development aliases (content in lib/bashrc/python-dev-aliases.sh)
write_bashrc_content /etc/bashrc.d/25-python-dev.sh "Python development aliases" \
    < /tmp/build-scripts/features/lib/bashrc/python-dev-aliases.sh

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
if su - "${USERNAME}" -c "command -v pylsp" &>/dev/null; then
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
if su - "${USERNAME}" -c "command -v pyright" &>/dev/null; then
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
    su - "${USERNAME}" -c "black --version" || log_warning "black installation failed"

log_command "Checking pytest version" \
    su - "${USERNAME}" -c "pytest --version" || log_warning "pytest installation failed"

log_command "Checking mypy version" \
    su - "${USERNAME}" -c "mypy --version" || log_warning "mypy installation failed"

log_command "Checking jupyter version" \
    su - "${USERNAME}" -c "jupyter --version" || log_warning "jupyter installation failed"

log_command "Checking ipython version" \
    su - "${USERNAME}" -c "ipython --version" || log_warning "ipython installation failed"

log_command "Checking ruff version" \
    su - "${USERNAME}" -c "ruff --version" || log_warning "ruff installation failed"

log_command "Checking pip-audit version" \
    su - "${USERNAME}" -c "pip-audit --version" || log_warning "pip-audit installation failed"

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
