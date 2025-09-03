#!/bin/bash
# Python Base - Direct installation without pyenv
#
# Description:
#   Installs Python directly from source without using pyenv.
#   This is simpler and more appropriate for containers where only
#   one Python version is needed.
#
# Features:
#   - Python installation from source
#   - pip, setuptools, wheel for package management
#   - pipx for isolated tool installations
#   - Poetry for modern dependency management
#   - Cache optimization for containerized environments
#
# Environment Variables:
#   - PYTHON_VERSION: Python version to install (has a default)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
PYTHON_VERSION="${PYTHON_VERSION:-3.13.5}"

# Start logging
log_feature_start "Python" "${PYTHON_VERSION}"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing Python build dependencies..."

# Update package lists with retry logic
apt_update

# Install Python build dependencies with retry logic
apt_install \
    build-essential \
    gdb \
    lcov \
    libbz2-dev \
    libffi-dev \
    libgdbm-dev \
    liblzma-dev \
    libncurses5-dev \
    libreadline-dev \
    libsqlite3-dev \
    libssl-dev \
    lzma \
    lzma-dev \
    tk-dev \
    uuid-dev \
    zlib1g-dev \
    wget \
    ca-certificates

# ============================================================================
# Cache Configuration
# ============================================================================
# Set up cache directories
PIP_CACHE_DIR="/cache/pip"
POETRY_CACHE_DIR="/cache/poetry"
PIPX_HOME="/opt/pipx"
PIPX_BIN_DIR="/opt/pipx/bin"

log_message "Python installation paths:"
log_message "  Python will be installed to: /usr/local"
log_message "  PIP_CACHE_DIR: ${PIP_CACHE_DIR}"
log_message "  POETRY_CACHE_DIR: ${POETRY_CACHE_DIR}"
log_message "  PIPX_HOME: ${PIPX_HOME}"

# Create cache directories with correct ownership
log_command "Creating Python cache directories" \
    mkdir -p "${PIP_CACHE_DIR}" "${POETRY_CACHE_DIR}" "${PIPX_HOME}" "${PIPX_BIN_DIR}"

log_command "Setting cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${PIP_CACHE_DIR}" "${POETRY_CACHE_DIR}" "${PIPX_HOME}"

# ============================================================================
# Python Installation from Source
# ============================================================================
log_message "Downloading and building Python ${PYTHON_VERSION}..."

cd /tmp

# Download Python source
log_command "Downloading Python ${PYTHON_VERSION} source" \
    wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz"

log_command "Extracting Python source" \
    tar -xzf "Python-${PYTHON_VERSION}.tgz"

cd "Python-${PYTHON_VERSION}"

# Configure Python with optimization and shared library support
log_command "Configuring Python build" \
    ./configure \
    --prefix=/usr/local \
    --enable-shared \
    --enable-optimizations \
    --with-lto \
    --with-system-ffi \
    --without-ensurepip \
    LDFLAGS="-Wl,-rpath /usr/local/lib"

# Build and install Python
log_command "Building Python (this may take several minutes)" \
    make -j"$(nproc)"

log_command "Installing Python" \
    make install

# Clean up build files
cd /
rm -rf "/tmp/Python-${PYTHON_VERSION}" "/tmp/Python-${PYTHON_VERSION}.tgz"

# Update library cache
log_command "Updating library cache" \
    ldconfig

# ============================================================================
# Create symlinks for Python 3
# ============================================================================
log_message "Creating Python symlinks..."

# Ensure python3 and python point to our installation
create_symlink "/usr/local/bin/python3" "/usr/local/bin/python" "python"

# ============================================================================
# Install pip
# ============================================================================
log_message "Installing pip..."

# Download and install pip
log_command "Downloading get-pip.py" \
    wget -q https://bootstrap.pypa.io/get-pip.py

log_command "Installing pip" \
    /usr/local/bin/python3 get-pip.py --no-cache-dir

rm get-pip.py

# Upgrade pip, setuptools, and wheel as the user
log_command "Upgrading pip, setuptools, and wheel" \
    su - ${USERNAME} -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel"

# ============================================================================
# Handle Python project files if they were copied during build
# ============================================================================
log_message "Checking for Python project files..."

# If Python project files were copied to temp during build, move them to workspace
if [ -d /tmp/python-project-files ] && [ -n "$(ls -A /tmp/python-project-files 2>/dev/null)" ]; then
    log_message "Found Python project files, moving to workspace..."
    
    # Ensure workspace directory exists
    log_command "Creating workspace directory" \
        mkdir -p ${WORKING_DIR}
    
    # Copy files to workspace
    for file in /tmp/python-project-files/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            log_command "Copying $filename to workspace" \
                cp "$file" "${WORKING_DIR}/"
        fi
    done
    
    # Fix ownership
    log_command "Setting correct ownership on workspace" \
        chown -R ${USER_UID}:${USER_GID} ${WORKING_DIR}
    
    # Clean up temp files
    log_command "Cleaning up temporary files" \
        rm -rf /tmp/python-project-files
fi

# ============================================================================
# Install pipx and Poetry
# ============================================================================
log_message "Installing pipx and Poetry..."

# Install pipx as the user
log_command "Installing pipx" \
    su - ${USERNAME} -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python3 -m pip install --no-cache-dir pipx"

# Ensure pipx bin directory is in PATH
export PATH="${PIPX_BIN_DIR}:$PATH"

# Use pipx to install Poetry
log_command "Installing Poetry via pipx" \
    su - ${USERNAME} -c "
    export PIPX_HOME='${PIPX_HOME}'
    export PIPX_BIN_DIR='${PIPX_BIN_DIR}'
    export PATH='${PIPX_BIN_DIR}:/usr/local/bin:$PATH'

    /usr/local/bin/python3 -m pipx install poetry

    # Configure Poetry
    ${PIPX_BIN_DIR}/poetry config virtualenvs.in-project true
    ${PIPX_BIN_DIR}/poetry config cache-dir ${POETRY_CACHE_DIR}
"

# ============================================================================
# System-wide Configuration
# ============================================================================
log_message "Configuring Python environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create Python configuration
write_bashrc_content /etc/bashrc.d/20-python.sh "Python configuration" << 'PYTHON_BASHRC_EOF'
# Python environment configuration

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Python cache directories
export PIP_CACHE_DIR="/cache/pip"
export PIP_NO_CACHE_DIR=false
export PIP_DISABLE_PIP_VERSION_CHECK=1

# Poetry configuration
export POETRY_CACHE_DIR="/cache/poetry"
export POETRY_VIRTUALENVS_IN_PROJECT=true

# pipx configuration
if [ -d /opt/pipx ] && [[ ":$PATH:" != *":/opt/pipx/bin:"* ]]; then
    export PIPX_HOME="/opt/pipx"
    export PIPX_BIN_DIR="/opt/pipx/bin"
    export PATH="$PIPX_BIN_DIR:$PATH"
fi
PYTHON_BASHRC_EOF

log_command "Setting Python bashrc script permissions" \
    chmod +x /etc/bashrc.d/20-python.sh

# ============================================================================
# Update /etc/environment with static paths
# ============================================================================
# First, read existing PATH if any
if [ -f /etc/environment ] && grep -q "^PATH=" /etc/environment; then
    # Extract existing PATH
    EXISTING_PATH=$(grep "^PATH=" /etc/environment | cut -d'"' -f2)
    # Remove the line
    log_command "Removing existing PATH from /etc/environment" \
        grep -v "^PATH=" /etc/environment > /etc/environment.tmp && mv /etc/environment.tmp /etc/environment
else
    EXISTING_PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
fi

# Add pipx bin path if not already present
NEW_PATH="$EXISTING_PATH"
if [[ ":$NEW_PATH:" != *":/opt/pipx/bin:"* ]]; then
    NEW_PATH="$NEW_PATH:/opt/pipx/bin"
fi

# Write back
log_command "Writing updated PATH to /etc/environment" \
    bash -c "echo 'PATH=\"$NEW_PATH\"' >> /etc/environment"

# ============================================================================
# Create container startup scripts
# ============================================================================
log_message "Creating Python startup script..."

# Create startup directory if it doesn't exist
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/10-poetry-install.sh << 'PYTHON_POETRY_EOF'
#!/bin/bash
# Install Python dependencies if pyproject.toml exists
if [ -f ${WORKING_DIR}/pyproject.toml ]; then
    echo "Installing Poetry dependencies..."
    cd ${WORKING_DIR}
    export PATH="/opt/pipx/bin:$PATH"
    poetry install --no-interaction || echo "Poetry install failed, continuing..."
fi

# Install pip requirements if requirements.txt exists
if [ -f ${WORKING_DIR}/requirements.txt ]; then
    echo "Installing pip requirements..."
    cd ${WORKING_DIR}
    python3 -m pip install -r requirements.txt || echo "pip install failed, continuing..."
fi
PYTHON_POETRY_EOF

log_command "Setting startup script permissions" \
    chmod +x /etc/container/first-startup/10-poetry-install.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Python verification script..."

cat > /usr/local/bin/test-python << 'PYTHON_TEST_EOF'
#!/bin/bash
echo "=== Python Installation Status ==="
if command -v python3 &> /dev/null; then
    echo "✓ Python3 $(python3 --version) is installed"
    echo "  Binary: $(which python3)"
    echo "  Real path: $(readlink -f $(which python3))"
else
    echo "✗ Python3 is not installed"
fi

if command -v python &> /dev/null; then
    echo "✓ Python symlink exists at $(which python)"
fi

echo ""
echo "=== Python Package Managers ==="
for cmd in pip pip3 pipx poetry; do
    if command -v $cmd &> /dev/null; then
        version=$($cmd --version 2>&1 | head -1)
        echo "✓ $cmd: $version"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Python Environment ==="
echo "PIP_CACHE_DIR: ${PIP_CACHE_DIR:-not set}"
echo "POETRY_CACHE_DIR: ${POETRY_CACHE_DIR:-not set}"
echo "PIPX_HOME: ${PIPX_HOME:-not set}"

echo ""
echo "=== Installed Python Packages ==="
pip list 2>/dev/null | head -10
echo "..."
total_packages=$(pip list 2>/dev/null | wc -l)
echo "Total packages: $total_packages"
PYTHON_TEST_EOF

log_command "Setting test-python script permissions" \
    chmod +x /usr/local/bin/test-python

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Python installation..."

log_command "Checking Python version" \
    /usr/local/bin/python3 --version

log_command "Checking pip version" \
    /usr/local/bin/pip --version || log_warning "pip not installed"

log_command "Checking Poetry version" \
    ${PIPX_BIN_DIR}/poetry --version || log_warning "poetry not installed"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Python directories..."
log_command "Final ownership fix for Python cache directories" \
    chown -R ${USER_UID}:${USER_GID} "${PIP_CACHE_DIR}" "${PIPX_HOME}" "${POETRY_CACHE_DIR}" || true

# End logging
log_feature_end

echo ""
echo "Python is installed directly without pyenv"
echo "Run 'test-python' to verify Python installation"
echo "Run 'check-build-logs.sh python' to review installation logs"
