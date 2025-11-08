#!/bin/bash
# Rust Programming Language - Toolchain and development tools
#
# Description:
#   Installs the Rust programming language toolchain via rustup with essential
#   development tools. Configures cache directories for optimal container usage.
#
# Features:
#   - Rust toolchain (stable by default)
#   - Essential components: rust-src, rust-analyzer, clippy, rustfmt
#   - Development tools: cargo-watch (auto-rebuild), cargo-edit (dependency management)
#   - Documentation tools: mdBook and plugins for creating Rust documentation
#
# Cache Strategy:
#   - If /cache directory exists and CARGO_HOME/RUSTUP_HOME aren't set, uses /cache/cargo and /cache/rustup
#   - Otherwise uses standard home directory locations (~/.cargo, ~/.rustup)
#   - This allows volume mounting for persistent caches across container rebuilds
#
# Environment Variables:
#   - CARGO_HOME: Cargo's home directory (default: /cache/cargo or ~/.cargo)
#   - RUSTUP_HOME: Rustup's home directory (default: /cache/rustup or ~/.rustup)
#   - RUST_VERSION: Toolchain version (has a default; can be: stable, beta, nightly, or specific version)
#
# Note:
#   The script runs as root but installs Rust as the specified user to ensure proper permissions
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

# Get Rust version from environment or use default
RUST_VERSION="${RUST_VERSION:-1.88.0}"

# Start logging
log_feature_start "Rust" "${RUST_VERSION}"

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Installing Rust ${RUST_VERSION} for user ${USERNAME}..."

# ALWAYS use /cache paths for consistency
# These will either use cache mounts (faster rebuilds) or be created in the image
CARGO_HOME="/cache/cargo"
RUSTUP_HOME="/cache/rustup"

log_message "Rust installation paths:"
log_message "  CARGO_HOME: ${CARGO_HOME}"
log_message "  RUSTUP_HOME: ${RUSTUP_HOME}"

# Create directories with correct ownership
# This ensures they exist in the image even without cache mounts
log_command "Creating Rust cache directories" \
    mkdir -p "${CARGO_HOME}" "${RUSTUP_HOME}"

log_command "Setting cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${CARGO_HOME}" "${RUSTUP_HOME}"

# ============================================================================
# Rust Toolchain Installation (Secure with Checksum Verification)
# ============================================================================
log_message "Installing Rust toolchain..."

# Determine rustup target triple based on architecture
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64)
        RUSTUP_TARGET="x86_64-unknown-linux-gnu"
        ;;
    arm64)
        RUSTUP_TARGET="aarch64-unknown-linux-gnu"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

log_message "Installing rustup for ${RUSTUP_TARGET}..."

# Define download URLs
RUSTUP_URL="https://static.rust-lang.org/rustup/dist/${RUSTUP_TARGET}/rustup-init"
RUSTUP_CHECKSUM_URL="${RUSTUP_URL}.sha256"

# Fetch SHA256 checksum from official source
log_message "Fetching rustup checksum from rust-lang.org..."
if ! RUSTUP_CHECKSUM=$(curl -fsSL "$RUSTUP_CHECKSUM_URL" 2>/dev/null); then
    log_error "Failed to fetch checksum for rustup"
    log_error "URL: ${RUSTUP_CHECKSUM_URL}"
    log_feature_end
    exit 1
fi

# Extract just the checksum (rustup .sha256 files include path, format: "checksum *path/file")
RUSTUP_CHECKSUM=$(echo "$RUSTUP_CHECKSUM" | awk '{print $1}')
log_message "Expected SHA256: ${RUSTUP_CHECKSUM}"

# Download and verify rustup-init
cd /tmp
log_message "Downloading and verifying rustup-init..."
download_and_verify \
    "$RUSTUP_URL" \
    "$RUSTUP_CHECKSUM" \
    "rustup-init"

# Make executable
log_command "Making rustup-init executable" \
    chmod +x rustup-init

# Run rustup-init as the target user with verified binary
log_command "Installing Rust via verified rustup" \
    su - ${USERNAME} -c "
    export CARGO_HOME='${CARGO_HOME}'
    export RUSTUP_HOME='${RUSTUP_HOME}'

    # Run verified rustup installer
    /tmp/rustup-init -y \
        --default-toolchain ${RUST_VERSION} \
        --profile default

    # Source cargo environment to make rustup/cargo available
    source ${CARGO_HOME}/env

    # Add essential Rust components
    # - rust-src: Rust standard library source (needed by rust-analyzer)
    # - rust-analyzer: Official LSP for IDE support
    # - clippy: Linting tool for common mistakes and style
    # - rustfmt: Code formatter
    rustup component add rust-src rust-analyzer clippy rustfmt
"

# Clean up installer
log_command "Cleaning up rustup installer" \
    rm -f /tmp/rustup-init

cd /

# Install additional Cargo tools
# These enhance the development experience but aren't required for basic Rust usage
log_command "Installing cargo development tools" \
    su - ${USERNAME} -c "
    export CARGO_HOME='${CARGO_HOME}'
    export RUSTUP_HOME='${RUSTUP_HOME}'
    source ${CARGO_HOME}/env

    # cargo-watch: Automatically re-run commands when files change
    # cargo-edit: Add/remove dependencies from Cargo.toml via CLI
    echo 'Installing development tools...'
    cargo install --locked cargo-watch cargo-edit || true

    # mdBook: Create books from Markdown (Rust's documentation standard)
    # Includes plugins for enhanced documentation features
    echo 'Installing mdBook documentation tools...'
    cargo install --locked mdbook || true
    cargo install --locked mdbook-mermaid || true      # Mermaid diagram support
    cargo install --locked mdbook-toc || true          # Table of contents generation
    cargo install --locked mdbook-admonish || true     # Callout boxes (note, warning, etc.)
"

# ============================================================================
# Create symlinks for Rust binaries
# ============================================================================
log_message "Creating Rust symlinks..."

# Create /usr/local/bin symlinks for easier access
RUST_BIN_DIR="${CARGO_HOME}/bin"
for cmd in rustc cargo rustup rust-analyzer rustfmt clippy-driver; do
    if [ -f "${RUST_BIN_DIR}/${cmd}" ]; then
        create_symlink "${RUST_BIN_DIR}/${cmd}" "/usr/local/bin/${cmd}" "${cmd} Rust tool"
    fi
done

# Also link cargo-installed tools
for cmd in cargo-watch cargo-add cargo-rm cargo-upgrade mdbook; do
    if [ -f "${RUST_BIN_DIR}/${cmd}" ]; then
        create_symlink "${RUST_BIN_DIR}/${cmd}" "/usr/local/bin/${cmd}" "${cmd} cargo tool"
    fi
done

# ============================================================================
# Configure system-wide environment
# ============================================================================
log_message "Configuring system-wide Rust environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create Rust configuration
write_bashrc_content /etc/bashrc.d/30-rust.sh "Rust configuration" << 'RUST_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Rust environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Rust toolchain paths
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"

# Only add cargo bin to PATH if not already there
if [ -d "${CARGO_HOME}/bin" ] && [[ ":$PATH:" != *":${CARGO_HOME}/bin:"* ]]; then
    export PATH="${CARGO_HOME}/bin:$PATH"
fi

# Rust compiler flags for better error messages
export RUST_BACKTRACE=1

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
RUST_BASHRC_EOF

log_command "Setting Rust bashrc script permissions" \
    chmod +x /etc/bashrc.d/30-rust.sh

# Update /etc/environment with static paths
log_message "Updating system PATH in /etc/environment..."

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

# Add cargo bin if not already present
NEW_PATH="$EXISTING_PATH"
if [[ ":$NEW_PATH:" != *":/cache/cargo/bin:"* ]]; then
    NEW_PATH="$NEW_PATH:/cache/cargo/bin"
fi

# Write back
log_command "Writing updated PATH to /etc/environment" \
    bash -c "echo 'PATH=\"$NEW_PATH\"' >> /etc/environment"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Rust directories..."
log_command "Final ownership fix for cargo cache" \
    chown -R ${USER_UID}:${USER_GID} "${CARGO_HOME}" "${RUSTUP_HOME}"

# End logging
log_feature_end

echo ""
echo "Rust installation complete:"
echo "    Toolchain: ${RUST_VERSION}"
echo "    CARGO_HOME: ${CARGO_HOME}"
echo "    RUSTUP_HOME: ${RUSTUP_HOME}"
echo "    Tools installed: cargo-watch, cargo-edit, mdBook suite"
echo "Run 'check-build-logs.sh rust' to review installation logs"
