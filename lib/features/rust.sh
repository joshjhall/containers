#!/bin/bash
# Rust Programming Language - Toolchain and development tools
#
# Description:
#   Delegates toolchain installation to `luggage install rust@${RUST_VERSION}`
#   and adds cargo-installed development tools on top. See
#   docs/architecture/luggage-migration.md for the migration playbook.
#
# Features:
#   - Rust toolchain installed via luggage (rustup-init under the hood)
#   - Essential components: rust-src, rust-analyzer, clippy, rustfmt
#     (applied by catalog `post_install` steps)
#   - Development tools: cargo-watch (auto-rebuild)
#   - Documentation: mdbook, mdbook-mermaid, mdbook-toc, mdbook-admonish
#
# Cache Strategy:
#   - Uses /cache/cargo and /cache/rustup for consistent caching
#   - Allows volume mounting for persistent caches across container rebuilds
#
# Environment Variables:
#   - RUST_VERSION: Toolchain version specification (default: 1.95.0)
#     * Specific version (e.g., "1.84.1"): Uses exact version
#     * Major.minor only (e.g., "1.84"): Resolves to latest patch
#     * Channel names (stable, beta, nightly): Passed to luggage --channel
#
# Note:
#   - rustup-init is verified by luggage's tier-3 verifier
#     (published sha256 from static.rust-lang.org)
#   - Rust toolchains remain verified by rustup's built-in system
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

source /tmp/build-scripts/base/cache-utils.sh
source /tmp/build-scripts/base/path-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
RUST_VERSION="${RUST_VERSION:-1.96.0}"

# Cargo tool versions. Every cargo install must be --locked and pinned to an
# explicit @version so upstream drift on crates.io cannot retroactively break
# a previously-working build. Auto-bumped weekly via bin/check-versions.sh.
CARGO_WATCH_VERSION="${CARGO_WATCH_VERSION:-8.5.3}"
MDBOOK_VERSION="${MDBOOK_VERSION:-0.5.2}"
MDBOOK_MERMAID_VERSION="${MDBOOK_MERMAID_VERSION:-0.17.0}"
MDBOOK_TOC_VERSION="${MDBOOK_TOC_VERSION:-0.15.3}"
MDBOOK_ADMONISH_VERSION="${MDBOOK_ADMONISH_VERSION:-1.20.0}"

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
# Rust Toolchain Installation (delegated to luggage)
# ============================================================================
# luggage downloads + tier-3-verifies rustup-init, runs it under ${USERNAME},
# and applies the rust-src/rust-analyzer/clippy/rustfmt component_add
# post_install steps from the catalog. Channel names (stable/beta/nightly)
# route through `--channel`; semver-shaped values use `tool@<version>`.
log_message "Installing Rust toolchain via luggage..."

if [[ "$RUST_VERSION" =~ ^(stable|beta|nightly)$ ]]; then
    log_command "luggage install rust --channel ${RUST_VERSION}" \
        /usr/local/bin/luggage install rust \
        --channel "${RUST_VERSION}" \
        --catalog "${CONTAINERS_DB:-/opt/containers-db}" \
        --user "${USERNAME}" \
        --cache-root /cache \
        --log-dir /var/log/luggage
else
    log_command "luggage install rust@${RUST_VERSION}" \
        /usr/local/bin/luggage install "rust@${RUST_VERSION}" \
        --catalog "${CONTAINERS_DB:-/opt/containers-db}" \
        --user "${USERNAME}" \
        --cache-root /cache \
        --log-dir /var/log/luggage
fi

# Install additional Cargo tools
# These enhance the development experience but aren't required for basic Rust usage

# build-essential provides cc/gcc, required to link the Rust binaries we
# build below. Without this, cargo fails with "linker `cc` not found"
# on minimal base images.
log_message "Installing system dependencies for Rust tooling (build-essential)"
apt_update
apt_install build-essential pkg-config

log_command "Installing cargo development tools" \
    su - "${USERNAME}" -c "
    export CARGO_HOME='${CARGO_HOME}'
    export RUSTUP_HOME='${RUSTUP_HOME}'
    source ${CARGO_HOME}/env

    # cargo-watch: Automatically re-run commands when files change
    # Note: cargo add/remove are now built into Cargo 1.62+, no need for cargo-edit
    echo 'Installing development tools...'
    cargo install --locked cargo-watch@${CARGO_WATCH_VERSION}

    # mdBook: Create books from Markdown (Rust's documentation standard)
    # Includes plugins for enhanced documentation features
    echo 'Installing mdBook documentation tools...'
    cargo install --locked mdbook@${MDBOOK_VERSION}
    cargo install --locked mdbook-mermaid@${MDBOOK_MERMAID_VERSION}
    cargo install --locked mdbook-toc@${MDBOOK_TOC_VERSION}
    cargo install --locked mdbook-admonish@${MDBOOK_ADMONISH_VERSION}
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

# Create Rust configuration (content in lib/bashrc/rust.sh)
write_bashrc_content /etc/bashrc.d/30-rust.sh "Rust configuration" \
    </tmp/build-scripts/features/lib/bashrc/rust.sh

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
log_feature_instructions "test-rust" "rust"
