#!/bin/bash
# Rust Programming Language - Toolchain and development tools
#
# Description:
#   Installs the Rust programming language toolchain via rustup with essential
#   development tools. Configures cache directories for optimal container usage.
#
# Features:
#   - Rust toolchain installed via rustup (stable by default)
#   - Essential components: rust-src, rust-analyzer, clippy, rustfmt
#   - Development tools: cargo-watch (auto-rebuild)
#   - Documentation: mdbook, mdbook-mermaid, mdbook-toc, mdbook-admonish
#
# Note: cargo-edit is no longer needed as cargo add/remove are built into Cargo 1.62+
#
# Cache Strategy:
#   - Uses /cache/cargo and /cache/rustup for consistent caching
#   - Allows volume mounting for persistent caches across container rebuilds
#
# Environment Variables:
#   - RUST_VERSION: Toolchain version specification (default: 1.88.0)
#     * Major.minor only (e.g., "1.84"): Resolves to latest 1.84.x
#     * Specific version (e.g., "1.84.1"): Uses exact version
#     * Can also be: stable, beta, nightly
#
# Note:
#   - rustup-init is verified using Tier 3 (published checksums from rust-lang.org)
#   - Rust toolchains are verified by rustup's built-in verification system
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source version resolution for partial version support
source /tmp/build-scripts/base/version-resolution.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/base/checksum-fetch.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh
source /tmp/build-scripts/base/cache-utils.sh
source /tmp/build-scripts/base/path-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
RUST_VERSION="${RUST_VERSION:-1.88.0}"

# Validate Rust version format to prevent shell injection
validate_rust_version "$RUST_VERSION" || {
    log_error "Build failed due to invalid RUST_VERSION"
    exit 1
}

# Resolve partial versions to full versions (e.g., "1.84" -> "1.84.1")
# This enables users to use partial versions for latest patches
# Note: Only applies to X.Y or X.Y.Z versions, not to "stable", "beta", "nightly"
if [[ "$RUST_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ORIGINAL_VERSION="$RUST_VERSION"
    RUST_VERSION=$(resolve_rust_version "$RUST_VERSION" 2>/dev/null || echo "$RUST_VERSION")

    if [ "$ORIGINAL_VERSION" != "$RUST_VERSION" ]; then
        log_message "📍 Version Resolution: $ORIGINAL_VERSION → $RUST_VERSION"
        log_message "   Using latest patch version"
    fi
fi

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
    chown -R "${USER_UID}:${USER_GID}" "${CARGO_HOME}" "${RUSTUP_HOME}"

# ============================================================================
# Rust Toolchain Installation (Secure with Checksum Verification)
# ============================================================================
log_message "Installing Rust toolchain..."

# Determine rustup target triple based on architecture
RUSTUP_TARGET=$(map_arch "x86_64-unknown-linux-gnu" "aarch64-unknown-linux-gnu")

log_message "Installing rustup for ${RUSTUP_TARGET}..."

# Define download URLs
RUSTUP_URL="https://static.rust-lang.org/rustup/dist/${RUSTUP_TARGET}/rustup-init"
RUSTUP_CHECKSUM_URL="${RUSTUP_URL}.sha256"

# Fetch SHA256 checksum from official source
log_message "Fetching rustup checksum from rust-lang.org..."
if ! RUSTUP_CHECKSUM=$(command curl -fsSL "$RUSTUP_CHECKSUM_URL" 2>/dev/null); then
    log_error "Failed to fetch checksum for rustup"
    log_error "URL: ${RUSTUP_CHECKSUM_URL}"
    log_feature_end
    exit 1
fi

# Extract just the checksum (rustup .sha256 files include path, format: "checksum *path/file")
RUSTUP_CHECKSUM=$(echo "$RUSTUP_CHECKSUM" | awk '{print $1}')
log_message "Expected SHA256: ${RUSTUP_CHECKSUM}"

# Download and verify rustup-init
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
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
    su - "${USERNAME}" -c "
    export CARGO_HOME='${CARGO_HOME}'
    export RUSTUP_HOME='${RUSTUP_HOME}'

    # Run verified rustup installer
    ${BUILD_TEMP}/rustup-init -y \
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

cd /
log_command "Cleaning up build directory" \
    command rm -rf "$BUILD_TEMP"

# Install additional Cargo tools
# These enhance the development experience but aren't required for basic Rust usage
log_command "Installing cargo development tools" \
    su - "${USERNAME}" -c "
    export CARGO_HOME='${CARGO_HOME}'
    export RUSTUP_HOME='${RUSTUP_HOME}'
    source ${CARGO_HOME}/env

    # cargo-watch: Automatically re-run commands when files change
    # Note: cargo add/remove are now built into Cargo 1.62+, no need for cargo-edit
    echo 'Installing development tools...'
    cargo install --locked cargo-watch || true

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
for cmd in cargo-watch mdbook; do
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

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Rust toolchain paths
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"

# Add cargo bin to PATH with security validation
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "${CARGO_HOME}/bin" 2>/dev/null || export PATH="${CARGO_HOME}/bin:$PATH"
else
    # Fallback if safe_add_to_path not available
    if [ -d "${CARGO_HOME}/bin" ]; then
        export PATH="${CARGO_HOME}/bin:$PATH"
    fi
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
add_to_system_path "/cache/cargo/bin"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of Rust directories..."
log_command "Final ownership fix for cargo cache" \
    chown -R "${USER_UID}:${USER_GID}" "${CARGO_HOME}" "${RUSTUP_HOME}"

# Log feature summary
# Export directory paths for feature summary (also defined in bashrc for runtime)
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"
log_feature_summary \
    --feature "Rust" \
    --version "${RUST_VERSION}" \
    --tools "rustc,cargo,rustup" \
    --paths "${CARGO_HOME},${RUSTUP_HOME}" \
    --env "CARGO_HOME,RUSTUP_HOME,RUST_VERSION" \
    --commands "rustc,cargo,rustup,rustc-version,cargo-new,cargo-build,cargo-test,cargo-run" \
    --next-steps "Run 'test-rust' to verify installation. Use 'cargo new <name>' to create projects, 'cargo build' to compile, 'cargo test' to run tests, 'cargo run' to execute."

# End logging
log_feature_end

echo ""
echo "Rust installation complete:"
echo "    Toolchain: ${RUST_VERSION}"
echo "    CARGO_HOME: ${CARGO_HOME}"
echo "    RUSTUP_HOME: ${RUSTUP_HOME}"
echo "    Tools installed: cargo-watch, mdBook suite"
echo "Run 'check-build-logs.sh rust' to review installation logs"
