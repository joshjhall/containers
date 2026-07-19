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

# Source retry utilities (retry_with_backoff) for hardening cargo binstall
# against transient network failures on its from-source fallback path (#544)
source /tmp/build-scripts/base/retry-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# Source version resolution for partial version support
source /tmp/build-scripts/base/version-resolution.sh

source /tmp/build-scripts/base/cache-utils.sh
source /tmp/build-scripts/base/path-utils.sh

# Source GitHub release installer for binary tool downloads (used for cargo-binstall)
source /tmp/build-scripts/features/lib/install-github-release.sh

# ============================================================================
# Version Configuration
# ============================================================================
RUST_VERSION="${RUST_VERSION:-1.97.1}"

# Cargo tool versions. Every cargo (b)install must be --locked and pinned to an
# explicit @version so upstream drift on crates.io cannot retroactively break
# a previously-working build. Auto-bumped weekly via bin/check-versions.sh.
# Tools are installed with `cargo binstall` (prebuilt, checksum-verified
# binaries) to avoid the from-source compile that blew the CI timeout (#517);
# binstall falls back to `cargo install` for any crate lacking a prebuilt
# binary. CARGO_BINSTALL_VERSION is kept in sync with rust-dev.sh.
CARGO_BINSTALL_VERSION="${CARGO_BINSTALL_VERSION:-1.20.0}"
CARGO_WATCH_VERSION="${CARGO_WATCH_VERSION:-8.5.3}"
MDBOOK_VERSION="${MDBOOK_VERSION:-0.5.4}"
MDBOOK_MERMAID_VERSION="${MDBOOK_MERMAID_VERSION:-0.17.0}"
MDBOOK_TOC_VERSION="${MDBOOK_TOC_VERSION:-0.15.4}"
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

# Bootstrap cargo-binstall from its prebuilt release so the cargo tools below
# download as prebuilt, checksum-verified binaries instead of compiling from
# source (#517). install_github_release runs it through the 4-tier verifier
# (Tier 2 pinned checksum in lib/checksums.json) before placing it in
# /usr/local/bin. binstall falls back to `cargo install` for any crate without
# a prebuilt binary, so correctness is preserved.
log_message "Installing cargo-binstall ${CARGO_BINSTALL_VERSION}..."
install_github_release "cargo-binstall" "${CARGO_BINSTALL_VERSION}" \
    "https://github.com/cargo-bins/cargo-binstall/releases/download/v${CARGO_BINSTALL_VERSION}" \
    "cargo-binstall-x86_64-unknown-linux-musl.tgz" \
    "cargo-binstall-aarch64-unknown-linux-musl.tgz" \
    "calculate" "extract_flat:cargo-binstall"

# binstall helper
# ----------------------------------------------------------------------------
# Wraps `cargo binstall` (same flags as rust-dev.sh's cargo_binstall_tool):
#   --locked       honour Cargo.lock (parity with the old `cargo install --locked`)
#   --no-confirm   non-interactive (required in a build)
#   --disable-telemetry  no phone-home during builds
# Runs as ${USERNAME} so artifacts land under /cache/cargo with correct
# ownership. GITHUB_TOKEN (if provided via a BuildKit secret) is forwarded so
# binstall's GitHub API lookups aren't rate-limited.
#
# The whole call is wrapped in retry_with_backoff: when binstall can't find a
# prebuilt binary it falls back to `cargo install --locked` from source, which
# makes live crates.io downloads. A single transient network blip there would
# otherwise abort the entire image build (observed with taplo-cli@0.10.0 in
# rust-dev, #544). Retries cover both the prebuilt-fetch and the from-source
# fallback paths. --locked and the explicit @version pins are preserved, so a
# retry never silently changes what gets installed.
cargo_binstall_tool() {
    local spec="$1"
    retry_with_backoff su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' GITHUB_TOKEN='${GITHUB_TOKEN:-}' && source '${CARGO_HOME}/env' && cargo binstall --locked --no-confirm --disable-telemetry ${spec}"
}

# cargo-watch: Automatically re-run commands when files change
# Note: cargo add/remove are now built into Cargo 1.62+, no need for cargo-edit
log_command "Installing cargo-watch" \
    cargo_binstall_tool "cargo-watch@${CARGO_WATCH_VERSION}"

# mdBook: Create books from Markdown (Rust's documentation standard)
# Includes plugins for enhanced documentation features
log_command "Installing mdbook" \
    cargo_binstall_tool "mdbook@${MDBOOK_VERSION}"
log_command "Installing mdbook-mermaid" \
    cargo_binstall_tool "mdbook-mermaid@${MDBOOK_MERMAID_VERSION}"
log_command "Installing mdbook-toc" \
    cargo_binstall_tool "mdbook-toc@${MDBOOK_TOC_VERSION}"
log_command "Installing mdbook-admonish" \
    cargo_binstall_tool "mdbook-admonish@${MDBOOK_ADMONISH_VERSION}"

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
# Pinned-toolchain component reconciliation (#511, #487)
# ============================================================================
# The catalog's component_add post_install steps (rust-src, rust-analyzer,
# clippy, rustfmt) — and rust-dev's llvm-tools-preview — only land on the
# build-time default toolchain. When a consumer repo pins a different toolchain
# via rust-toolchain.toml, rustup auto-installs that toolchain *bare* the first
# time cargo/rustup runs in the project, so the rust-analyzer shim dies with
# "Unknown binary 'rust-analyzer' in official toolchain '...'" and cargo
# llvm-cov trips an interactive component-install prompt that hangs CI.
#
# We can't know the consumer's pin at image-build time (the project isn't in
# the build context for this layer), so reconcile at runtime: a first-startup
# hook reads the workspace's rust-toolchain.toml and applies the same
# components to the pinned toolchain. `rustup component add` is idempotent, so
# this is a no-op when the pin matches the default or the components already
# exist. The helper is shared with rust-dev's startup hook, which adds
# llvm-tools-preview on top.
log_message "Installing pinned-toolchain component reconciler..."

command cat >/usr/local/bin/rust-ensure-pinned-components <<'EOF'
#!/bin/bash
# Apply rustup components to the toolchain pinned by a project's
# rust-toolchain.toml (or legacy plain-text rust-toolchain file), so a pinned
# toolchain that rustup auto-installed bare still gets rust-analyzer, clippy,
# etc. See lib/features/rust.sh for the rationale (#511, #487).
#
# Usage: rust-ensure-pinned-components [project_dir] [component...]
#   project_dir  Directory to look for rust-toolchain.toml in (default: $PWD)
#   component... Components to add (default: rust-src rust-analyzer clippy rustfmt)
set -uo pipefail

export CARGO_HOME="${CARGO_HOME:-/cache/cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-/cache/rustup}"

project_dir="${1:-$PWD}"
shift 2>/dev/null || true
components=("$@")
if [ "${#components[@]}" -eq 0 ]; then
    components=(rust-src rust-analyzer clippy rustfmt)
fi

if ! command -v rustup >/dev/null 2>&1; then
    exit 0
fi

# Locate the toolchain file. rust-toolchain.toml is the modern form; a bare
# `rust-toolchain` file (legacy) holds just the channel string.
toolchain_file=""
if [ -f "${project_dir}/rust-toolchain.toml" ]; then
    toolchain_file="${project_dir}/rust-toolchain.toml"
elif [ -f "${project_dir}/rust-toolchain" ]; then
    toolchain_file="${project_dir}/rust-toolchain"
fi
[ -n "${toolchain_file}" ] || exit 0

# Extract the pinned channel. For the .toml form, grab the value of the
# `channel = "..."` key under [toolchain]; for the legacy form, the whole
# (trimmed) file is the channel.
pinned=""
if [[ "${toolchain_file}" == *.toml ]]; then
    pinned=$(command grep -E '^[[:space:]]*channel[[:space:]]*=' "${toolchain_file}" |
        command head -n1 |
        command sed -E 's/^[^=]*=[[:space:]]*//; s/[",[:space:]]//g')
else
    pinned=$(command sed -E 's/[[:space:]]+//g' "${toolchain_file}" | command head -n1)
fi
[ -n "${pinned}" ] || exit 0

# Skip if the pinned toolchain is already the default (components are already
# present from the build-time component_add steps).
default_tc=$(rustup show active-toolchain 2>/dev/null | command awk '{print $1}')
case "${default_tc}" in
    "${pinned}"-*) exit 0 ;;
esac

echo "Reconciling rustup components for pinned toolchain '${pinned}' (from $(basename "${toolchain_file}"))..."
# Ensure the pinned toolchain is installed with the full default profile
# (cargo/clippy/rustfmt), then add the extra components to it. Installing with
# --profile default means a completed install already carries the cargo
# subcommands even if the follow-up `component add` is skipped or rustup's lazy
# auto-install wins the race (#740). Failures are non-fatal: a startup hook must
# never block the container.
rustup toolchain install "${pinned}" --profile default --no-self-update 2>/dev/null || true
rustup component add --toolchain "${pinned}" "${components[@]}" 2>/dev/null ||
    echo "  ⚠ Could not add some components to '${pinned}' (continuing)"
EOF

log_command "Setting rust-ensure-pinned-components permissions" \
    chmod +x /usr/local/bin/rust-ensure-pinned-components

# First-startup hook: reconcile the base rust components against the workspace's
# pinned toolchain. rust-dev installs a companion hook for llvm-tools-preview.
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

command cat >/etc/container/first-startup/21-rust-toolchain-components.sh <<'EOF'
#!/bin/bash
# Reconcile rust-analyzer/rust-src/clippy/rustfmt onto a workspace-pinned
# toolchain so the LSP and cargo subcommands work when a project pins a
# toolchain other than the image default via rust-toolchain.toml (#511).
if command -v rust-ensure-pinned-components >/dev/null 2>&1; then
    rust-ensure-pinned-components "${WORKING_DIR:-$PWD}"
fi
EOF

log_command "Setting rust toolchain component startup script permissions" \
    chmod +x /etc/container/first-startup/21-rust-toolchain-components.sh

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
