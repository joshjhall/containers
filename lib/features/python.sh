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

# Source download and verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Source checksum verification utilities
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source version resolution for partial version support
source /tmp/build-scripts/base/version-resolution.sh

# Source 4-tier checksum verification system
source /tmp/build-scripts/base/checksum-verification.sh
source /tmp/build-scripts/base/cache-utils.sh
source /tmp/build-scripts/base/path-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
PYTHON_VERSION="${PYTHON_VERSION:-3.13.5}"

# Validate Python version format to prevent shell injection
validate_python_version "$PYTHON_VERSION" || {
    log_error "Build failed due to invalid PYTHON_VERSION"
    exit 1
}

# Resolve partial versions to full versions (e.g., "3.12" -> "3.12.12")
# This enables users to use partial versions and get latest patches with pinned checksums
ORIGINAL_VERSION="$PYTHON_VERSION"
PYTHON_VERSION=$(resolve_python_version "$PYTHON_VERSION" 2>/dev/null || echo "$PYTHON_VERSION")

if [ "$ORIGINAL_VERSION" != "$PYTHON_VERSION" ]; then
    log_message "📍 Version Resolution: $ORIGINAL_VERSION → $PYTHON_VERSION"
    log_message "   Using latest patch version with pinned checksum verification"
fi

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
    tk-dev \
    uuid-dev \
    zlib1g-dev \
    wget \
    ca-certificates

# Install version-specific packages
# lzma and lzma-dev were removed in Debian 13 (Trixie), replaced by liblzma-dev
apt_install_conditional 11 12 lzma lzma-dev

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

# Create cache directories with correct ownership using shared utility
create_cache_directories "${PIP_CACHE_DIR}" "${POETRY_CACHE_DIR}" "${PIPX_HOME}" "${PIPX_BIN_DIR}"

# ============================================================================
# Python Installation from Source
# ============================================================================
log_message "Downloading and building Python ${PYTHON_VERSION}..."

BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

# Download Python source with 4-tier checksum verification
PYTHON_TARBALL="Python-${PYTHON_VERSION}.tgz"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/${PYTHON_TARBALL}"

# Download Python tarball
log_message "Downloading Python ${PYTHON_VERSION}..."
if ! command curl -fsSL "$PYTHON_URL" -o "$PYTHON_TARBALL"; then
    log_error "Failed to download Python ${PYTHON_VERSION}"
    log_error "Please verify version exists: https://www.python.org/downloads/release/python-${PYTHON_VERSION//.}"
    log_feature_end
    exit 1
fi

# Verify using 4-tier system (GPG → Pinned → Published → Calculated)
# This will try each tier in order and log which method succeeded
if ! verify_download "language" "python" "$PYTHON_VERSION" "$PYTHON_TARBALL"; then
    log_error "Checksum verification failed for Python ${PYTHON_VERSION}"
    log_feature_end
    exit 1
fi

log_command "Extracting Python source" \
    tar -xzf "$PYTHON_TARBALL"

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
log_command "Cleaning up Python build directory" \
    command rm -rf "$BUILD_TEMP"

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

# Download and install pip with checksum verification
GET_PIP_URL="https://bootstrap.pypa.io/get-pip.py"

# Calculate checksum for verification (PyPA doesn't publish checksums for get-pip.py)
log_message "Calculating checksum for get-pip.py..."
GET_PIP_CHECKSUM=$(calculate_checksum_sha256 "$GET_PIP_URL" 2>/dev/null)

if [ -z "$GET_PIP_CHECKSUM" ]; then
    log_error "Failed to calculate checksum for get-pip.py"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${GET_PIP_CHECKSUM}"

# Download and verify get-pip.py
log_message "Downloading and verifying get-pip.py..."
download_and_verify \
    "$GET_PIP_URL" \
    "$GET_PIP_CHECKSUM" \
    "get-pip.py"

log_message "✓ get-pip.py verified successfully"

log_command "Installing pip" \
    /usr/local/bin/python3 get-pip.py --no-cache-dir

command rm get-pip.py

# Upgrade pip, setuptools, and wheel as the user
log_command "Upgrading pip, setuptools, and wheel" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel"

# ============================================================================
# Handle Python project files if they were copied during build
# ============================================================================
log_message "Checking for Python project files..."

# If Python project files were copied to temp during build, move them to workspace
if [ -d /tmp/python-project-files ] && [ -n "$(ls -A /tmp/python-project-files 2>/dev/null)" ]; then
    log_message "Found Python project files, moving to workspace..."
    
    # Ensure workspace directory exists
    log_command "Creating workspace directory" \
        mkdir -p "${WORKING_DIR}"
    
    # Copy files to workspace
    for file in /tmp/python-project-files/*; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            log_command "Copying $filename to workspace" \
                command cp "$file" "${WORKING_DIR}/"
        fi
    done

    # Fix ownership
    log_command "Setting correct ownership on workspace" \
        chown -R "${USER_UID}":"${USER_GID}" "${WORKING_DIR}"

    # Clean up temp files
    log_command "Cleaning up temporary files" \
        command rm -rf /tmp/python-project-files
fi

# ============================================================================
# Install pipx and Poetry
# ============================================================================
log_message "Installing pipx and Poetry..."

# Install pipx as the user
log_command "Installing pipx" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python3 -m pip install --no-cache-dir pipx"

# Ensure pipx bin directory is in PATH for build-time use (with security validation)
safe_add_to_path "${PIPX_BIN_DIR}" || export PATH="${PIPX_BIN_DIR}:$PATH"

# Use pipx to install Poetry with pinned version
POETRY_VERSION="2.2.1"
log_command "Installing Poetry ${POETRY_VERSION} via pipx" \
    su - "${USERNAME}" -c "
    # Source path utilities for secure PATH management
    if [ -f /tmp/build-scripts/base/path-utils.sh ]; then
        source /tmp/build-scripts/base/path-utils.sh
    fi

    export PIPX_HOME='${PIPX_HOME}'
    export PIPX_BIN_DIR='${PIPX_BIN_DIR}'

    # Securely add to PATH
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path '${PIPX_BIN_DIR}'
        safe_add_to_path '/usr/local/bin'
    else
        export PATH='${PIPX_BIN_DIR}:/usr/local/bin:$PATH'
    fi

    /usr/local/bin/python3 -m pipx install poetry==${POETRY_VERSION}

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

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# pipx configuration
if [ -d /opt/pipx ] && [[ ":$PATH:" != *":/opt/pipx/bin:"* ]]; then
    export PIPX_HOME="/opt/pipx"
    export PIPX_BIN_DIR="/opt/pipx/bin"
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$PIPX_BIN_DIR" 2>/dev/null || export PATH="$PIPX_BIN_DIR:$PATH"
    else
        export PATH="$PIPX_BIN_DIR:$PATH"
    fi
fi
PYTHON_BASHRC_EOF

log_command "Setting Python bashrc script permissions" \
    chmod +x /etc/bashrc.d/20-python.sh

# ============================================================================
# Update /etc/environment with static paths
# ============================================================================
log_message "Updating system PATH in /etc/environment..."
add_to_system_path "/opt/pipx/bin"

# ============================================================================
# Create container startup scripts
# ============================================================================
log_message "Creating Python startup script..."

# Create startup directory if it doesn't exist
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/10-poetry-install.sh << 'PYTHON_POETRY_EOF'
#!/bin/bash
# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Install Python dependencies if pyproject.toml exists
if [ -f ${WORKING_DIR}/pyproject.toml ]; then
    echo "Installing Poetry dependencies..."
    cd ${WORKING_DIR}
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "/opt/pipx/bin" 2>/dev/null || export PATH="/opt/pipx/bin:$PATH"
    else
        export PATH="/opt/pipx/bin:$PATH"
    fi
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

command cat > /usr/local/bin/test-python << 'PYTHON_TEST_EOF'
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
    chown -R "${USER_UID}":"${USER_GID}" "${PIP_CACHE_DIR}" "${PIPX_HOME}" "${POETRY_CACHE_DIR}" || true

# ============================================================================
# Feature Summary
# ============================================================================
# Export directory paths for feature summary (also defined in bashrc for runtime)
export PIP_CACHE_DIR="/cache/pip"
export PIPX_HOME="/cache/pipx"
export PIPX_BIN_DIR="/cache/pipx/bin"
export POETRY_CACHE_DIR="/cache/poetry"

log_feature_summary \
    --feature "Python" \
    --version "${PYTHON_VERSION}" \
    --tools "pip,poetry,pipx" \
    --paths "${PIP_CACHE_DIR},${POETRY_CACHE_DIR},${PIPX_HOME},${PIPX_BIN_DIR}" \
    --env "PIP_CACHE_DIR,POETRY_CACHE_DIR,PIPX_HOME,PIPX_BIN_DIR,PYTHON_VERSION" \
    --commands "python3,pip,poetry,pipx" \
    --next-steps "Run 'test-python' to verify installation"

# End logging
log_feature_end
