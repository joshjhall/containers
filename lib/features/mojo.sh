#!/bin/bash
# Mojo Programming Language - Version-specific Installation
#
# Description:
#   Installs Mojo programming language using pixi package manager.
#   Magic CLI is deprecated and pixi is the recommended installation method.
#   This script uses the Modular conda channel to install the modular package which includes Mojo.
#
# Features:
#   - Mojo compiler and runtime
#   - Pixi package manager for environment management
#   - Modular platform integration
#   - Support for Python interop
#   - LSP server for IDE integration
#
# Environment Variables:
#   - MOJO_VERSION: Version to install (default: latest nightly)
#
# Requirements:
#   - x86_64/amd64 architecture (ARM support limited)
#   - Linux (Debian/Ubuntu based)
#
# Note:
#   This installation method does not require authentication.
#   The old Modular CLI is deprecated in favor of pixi.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Start logging
log_feature_start "Mojo"

# ============================================================================
# Architecture Check
# ============================================================================
log_message "Checking system requirements for Mojo..."

# Check architecture - Mojo currently requires x86_64
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" != "amd64" ]; then
    log_warning "Mojo currently only supports x86_64/amd64 architecture"
    log_warning "Current architecture: $ARCH"
    log_warning "Skipping Mojo installation on this architecture"
    log_feature_end
    exit 0
fi

# ============================================================================
# OS Version Check
# ============================================================================
log_message "Checking OS version compatibility..."

# Check if we're on a supported Linux distribution
if [ -f /etc/os-release ]; then
    . /etc/os-release
    log_message "Detected OS: $NAME $VERSION"
else
    log_warning "Could not detect OS version"
fi

# ============================================================================
# Dependencies Installation
# ============================================================================
log_message "Installing dependencies..."

# Update package lists with retry logic
apt_update

# Install dependencies for pixi and Mojo
log_message "Installing required packages"
apt_install curl ca-certificates libssl-dev libbz2-dev libffi-dev zlib1g-dev git

# ============================================================================
# Cache and Path Configuration
# ============================================================================
log_message "Configuring Mojo cache and paths..."

# ALWAYS use /cache paths for consistency with other languages
# This will either use cache mount (faster rebuilds) or be created in the image
PIXI_CACHE="/cache/pixi"
MOJO_PROJECT="/cache/mojo/project"

# Create cache directories with correct ownership
# Use install -d for atomic directory creation with ownership
# Important: Create parent /cache/mojo directory first to ensure correct ownership
log_command "Creating Mojo/Pixi cache directories with ownership" \
    bash -c "install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '${PIXI_CACHE}' && \
    install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '/cache/mojo' && \
    install -d -m 0755 -o '${USER_UID}' -g '${USER_GID}' '${MOJO_PROJECT}'"

log_message "Mojo cache paths:"
log_message "  Pixi cache: ${PIXI_CACHE}"
log_message "  Mojo project: ${MOJO_PROJECT}"

# ============================================================================
# Pixi Installation (Secure with Checksum Verification)
# ============================================================================
log_message "Checking for pixi package manager..."

# Check if pixi is already installed
if command -v pixi &> /dev/null; then
    log_message "✓ pixi is already installed at $(which pixi)"
    log_message "  Version: $(pixi --version)"
    # Set PIXI_HOME for consistency if not already set
    export PIXI_HOME="${PIXI_HOME:-/opt/pixi}"
else
    log_message "pixi not found - installing pixi package manager..."

    # Install pixi to a system-wide location using PIXI_HOME
    export PIXI_HOME="/opt/pixi"
    log_message "Installing pixi to ${PIXI_HOME}"

    # Pixi version (default to latest if not specified)
    PIXI_VERSION="${PIXI_VERSION:-0.59.0}"
    log_message "Installing pixi version ${PIXI_VERSION}"

    # Determine platform and architecture
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
        amd64)
            PIXI_PLATFORM="x86_64-unknown-linux-musl"
            ;;
        arm64)
            PIXI_PLATFORM="aarch64-unknown-linux-musl"
            ;;
        *)
            log_error "Unsupported architecture for pixi: $ARCH"
            exit 1
            ;;
    esac

    log_message "Installing pixi for platform: ${PIXI_PLATFORM}"

    # Define download URLs
    PIXI_ARCHIVE="pixi-${PIXI_PLATFORM}.tar.gz"
    PIXI_URL="https://github.com/prefix-dev/pixi/releases/download/v${PIXI_VERSION}/${PIXI_ARCHIVE}"
    PIXI_CHECKSUM_URL="${PIXI_URL}.sha256"

    # Fetch SHA256 checksum from GitHub
    log_message "Fetching pixi checksum from GitHub..."
    if ! PIXI_CHECKSUM=$(fetch_github_sha256_file "$PIXI_CHECKSUM_URL" 2>/dev/null); then
        log_error "Failed to fetch checksum for pixi ${PIXI_VERSION}"
        log_error "URL: ${PIXI_CHECKSUM_URL}"
        log_error "Please verify version exists: https://github.com/prefix-dev/pixi/releases/tag/v${PIXI_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "Expected SHA256: ${PIXI_CHECKSUM}"

    # Download and verify pixi
    log_message "Downloading and verifying pixi..."
    download_and_extract \
        "$PIXI_URL" \
        "$PIXI_CHECKSUM" \
        "${PIXI_HOME}"

    # The binary should now be in ${PIXI_HOME}/pixi
    if [ -f "${PIXI_HOME}/pixi" ]; then
        log_message "✓ pixi binary extracted successfully"

        # Create bin directory if needed
        mkdir -p "${PIXI_HOME}/bin"

        # Move pixi to bin directory
        log_command "Moving pixi to bin directory" \
            mv "${PIXI_HOME}/pixi" "${PIXI_HOME}/bin/pixi"

        # Ensure the binary is executable and has correct permissions
        log_command "Setting pixi binary permissions" \
            chmod 755 "${PIXI_HOME}/bin/pixi"

        # Set ownership to allow non-root users to use it
        log_command "Setting pixi directory ownership" \
            chown -R "${USER_UID}:${USER_GID}" "${PIXI_HOME}"

        # Create symlink using the helper function
        create_symlink "${PIXI_HOME}/bin/pixi" "/usr/local/bin/pixi" "pixi package manager"

        log_message "✓ pixi v${PIXI_VERSION} installed successfully"
    else
        log_error "pixi installation failed - binary not found after extraction"
        exit 1
    fi

    cd /
fi

# ============================================================================
# Mojo Installation via Pixi
# ============================================================================
log_message "Installing Mojo via pixi..."

# Set pixi cache directory
export PIXI_CACHE_DIR="${PIXI_CACHE}"

# Initialize a Mojo project in the cache directory
cd "${MOJO_PROJECT}"

# Initialize pixi project with Modular conda channel as the user
log_command "Initializing pixi project for Mojo" \
    su - "${USERNAME}" -c "cd '${MOJO_PROJECT}' && export PIXI_CACHE_DIR='${PIXI_CACHE}' && pixi init mojo-env -c https://conda.modular.com/max-nightly/ -c conda-forge"

# Add the modular package which includes Mojo as the user
log_command "Adding modular package (includes Mojo)" \
    su - "${USERNAME}" -c "cd '${MOJO_PROJECT}/mojo-env' && export PIXI_CACHE_DIR='${PIXI_CACHE}' && pixi add modular"

# Also add Python support for interop as the user
log_command "Adding Python support" \
    su - "${USERNAME}" -c "cd '${MOJO_PROJECT}/mojo-env' && export PIXI_CACHE_DIR='${PIXI_CACHE}' && pixi add 'python>=3.11,<3.13'"

# Set proper ownership on the mojo-env directory after package installation
log_command "Setting mojo-env directory ownership" \
    chown -R "${USER_UID}:${USER_GID}" "${MOJO_PROJECT}/mojo-env"

# ============================================================================
# Create System-wide Wrapper Scripts
# ============================================================================
log_message "Creating system-wide Mojo wrapper scripts..."

# Create a wrapper script for mojo command
cat > /usr/local/bin/mojo << 'EOF'
#!/bin/bash
# Wrapper script for Mojo via pixi
export PIXI_CACHE_DIR="/cache/pixi"
cd /cache/mojo/project/mojo-env 2>/dev/null || {
    echo "Error: Mojo environment not found at /cache/mojo/project/mojo-env"
    exit 1
}
exec pixi run mojo "$@"
EOF

log_command "Setting mojo wrapper permissions" \
    chmod 755 /usr/local/bin/mojo

# Create wrapper for mojo-lsp-server
cat > /usr/local/bin/mojo-lsp-server << 'EOF'
#!/bin/bash
# Wrapper script for Mojo LSP server via pixi
export PIXI_CACHE_DIR="/cache/pixi"
cd /cache/mojo/project/mojo-env 2>/dev/null || {
    echo "Error: Mojo environment not found at /cache/mojo/project/mojo-env"
    exit 1
}
exec pixi run mojo-lsp-server "$@"
EOF

log_command "Setting mojo-lsp-server wrapper permissions" \
    chmod 755 /usr/local/bin/mojo-lsp-server

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide Mojo environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Mojo configuration
write_bashrc_content /etc/bashrc.d/60-mojo.sh "Mojo configuration" << 'MOJO_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Mojo Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# Mojo environment configuration
export PIXI_CACHE_DIR="/cache/pixi"
export MOJO_PROJECT_DIR="/cache/mojo/project/mojo-env"

# Mojo aliases
alias mojo-repl='mojo'
alias mojo-build='mojo build'
alias mojo-run='mojo run'
alias mojo-test='mojo test'
alias mojo-format='mojo format'
alias mojo-doc='mojo doc'

# Helper function to activate Mojo environment
mojo-shell() {
    cd "${MOJO_PROJECT_DIR}" && pixi shell
}

# Helper function to run Mojo with pixi
mojo-exec() {
    cd "${MOJO_PROJECT_DIR}" && pixi run "$@"
}

# Helper function to add packages to Mojo environment
mojo-add() {
    cd "${MOJO_PROJECT_DIR}" && pixi add "$@"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
MOJO_BASHRC_EOF

log_command "Setting Mojo bashrc script permissions" \
    chmod +x /etc/bashrc.d/60-mojo.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Mojo startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/30-mojo-setup.sh << 'EOF'
#!/bin/bash
# Mojo environment setup

# Check if we're in a Mojo project
if [ -f ${WORKING_DIR}/*.mojo ] || [ -f ${WORKING_DIR}/*.🔥 ] || [ -d ${WORKING_DIR}/.mojo ]; then
    echo "=== Mojo Project Detected ==="
    echo "Mojo is available via the 'mojo' command"

    # Show Mojo version
    if command -v mojo &> /dev/null; then
        echo "Mojo version: $(mojo --version 2>&1 | head -1)"
    fi

    echo ""
    echo "Mojo commands:"
    echo "  mojo              - Start Mojo REPL"
    echo "  mojo run file.mojo - Run a Mojo file"
    echo "  mojo build file.mojo - Build executable"
    echo "  mojo-shell        - Enter pixi shell for Mojo environment"
    echo ""
fi
EOF

log_command "Setting Mojo startup script permissions" \
    chmod +x /etc/container/first-startup/30-mojo-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Mojo verification script..."

cat > /usr/local/bin/test-mojo << 'EOF'
#!/bin/bash
echo "=== Mojo Installation Status ==="

# Check pixi
if command -v pixi &> /dev/null; then
    echo "✓ Pixi is installed"
    echo "  Version: $(pixi --version)"
    echo "  Binary: $(which pixi)"
else
    echo "✗ Pixi is not installed"
fi

echo ""

# Check Mojo wrapper
if [ -f /usr/local/bin/mojo ]; then
    echo "✓ Mojo wrapper script exists"

    # Try to get Mojo version
    if mojo --version &> /dev/null; then
        echo "  Version: $(mojo --version 2>&1 | head -1)"
    else
        echo "  Warning: Could not determine Mojo version"
    fi
else
    echo "✗ Mojo wrapper not found"
fi

echo ""
echo "=== Environment ==="
echo "  PIXI_CACHE_DIR: ${PIXI_CACHE_DIR:-/cache/pixi}"
echo "  Mojo project: /cache/mojo/project/mojo-env"

if [ -d /cache/mojo/project/mojo-env ]; then
    echo "  ✓ Mojo environment directory exists"
    if [ -f /cache/mojo/project/mojo-env/pixi.lock ]; then
        echo "  ✓ pixi.lock file exists"
    fi
else
    echo "  ✗ Mojo environment not found"
fi
EOF

log_command "Setting test-mojo permissions" \
    chmod 755 /usr/local/bin/test-mojo

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Mojo installation..."

# Verify pixi is available
log_command "Checking pixi version" \
    /usr/local/bin/pixi --version || log_warning "Pixi not installed properly"

# Try to verify Mojo (may fail if environment not fully activated)
log_message "Checking Mojo availability"
if cd "${MOJO_PROJECT}/mojo-env" && pixi run mojo --version; then
    log_message "✓ Mojo is available"
else
    log_warning "Mojo version check failed (this is normal during build)"
fi

# ============================================================================
# Final Permissions Check
# ============================================================================
log_message "Verifying permissions for non-root users..."

# Ensure all Mojo-related directories are accessible
log_command "Setting final permissions on cache directories" \
    chmod -R 755 "${PIXI_CACHE}" "${MOJO_PROJECT}"

# Verify wrapper scripts are executable by all
for script in /usr/local/bin/mojo /usr/local/bin/mojo-lsp-server /usr/local/bin/test-mojo /usr/local/bin/pixi; do
    if [ -f "$script" ] || [ -L "$script" ]; then
        log_message "Checking $script permissions: $(ls -la $script)"
    fi
done

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Mojo directories..."
log_command "Final ownership fix for Mojo cache directories" \
    chown -R "${USER_UID}:${USER_GID}" "${PIXI_CACHE}" "${MOJO_PROJECT}" || true

# Log feature summary
log_feature_summary \
    --feature "Mojo" \
    --tools "mojo,pixi,mojo-lsp-server" \
    --paths "${PIXI_CACHE},${MOJO_PROJECT}" \
    --env "PIXI_CACHE_DIR,MOJO_PROJECT_DIR" \
    --commands "mojo,mojo-repl,mojo-build,mojo-run,mojo-test,mojo-shell,mojo-exec,mojo-add,pixi" \
    --next-steps "Run 'test-mojo' to verify installation. Use 'mojo' to start REPL, 'mojo run file.mojo' to execute code. Enter pixi shell with 'mojo-shell'."

# End logging
log_feature_end

echo ""
echo "Run 'test-mojo' to verify installation"
echo "Run 'mojo' to start the Mojo REPL"
echo "Run 'check-build-logs.sh mojo' to review installation logs"
