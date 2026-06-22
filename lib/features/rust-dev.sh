#!/bin/bash
# Rust Development Tools - Advanced development utilities for Rust
#
# Description:
#   Installs additional development tools for Rust programming, including
#   code analysis, formatting, testing, and parsing tools. These complement
#   the base Rust installation with productivity-enhancing utilities.
#
# Tools Installed:
#   - tree-sitter-cli: Incremental parsing library and code analysis
#   - cargo-watch: Automatically rebuild on file changes
#   - cargo-expand: Expand macros to see generated code
#   - cargo-modules: Visualize module structure and visibility
#   - cargo-outdated: Check for outdated dependencies
#   - cargo-sweep: Clean up old build artifacts to reclaim disk space
#   - cargo-release: Semantic versioning and crate publishing
#   - cargo-audit: Security vulnerability scanning for dependencies
#   - cargo-deny: Dependency linting (licenses, duplicates, bans)
#   - cargo-geiger: Detect unsafe Rust code usage
#   - cargo-machete: Detect unused dependencies in Cargo.toml
#   - cargo-nextest: Next-generation test runner (faster, CI partitioning, flake retries)
#   - cargo-llvm-cov: Source-based coverage via LLVM instrumentation
#   - sccache: Shared compilation cache for faster builds
#   - bacon: Background rust code checker
#   - tokei: Code statistics tool
#   - hyperfine: Command-line benchmarking tool
#   - just: Modern command runner (like make)
#   - mdbook: Create books from markdown files
#   - taplo-cli: TOML formatter and linter
#   - mold: Fast Linux linker (opt-in via project .cargo/config.toml)
#
# Common Commands:
#   - cargo watch -x run: Auto-rebuild and run on changes
#   - cargo add <crate>: Add dependency to Cargo.toml (built into cargo)
#   - cargo expand: Show macro-expanded code
#   - cargo modules structure: Visualize module tree and visibility
#   - cargo outdated: List outdated dependencies
#   - cargo sweep --time 14: Remove build artifacts older than 14 days
#   - bacon: Run continuous background compilation
#   - tokei: Count lines of code by language
#   - hyperfine <cmd>: Benchmark command execution
#   - just: Run project tasks
#
# Automatic Cleanup:
#   cargo-sweep runs via cron (every 6 hours) to clean old build artifacts.
#   Configure via environment variables:
#   - CARGO_SWEEP_DAYS: Age threshold in days (default: 14)
#   - CARGO_SWEEP_DISABLE: Set to "true" to disable automatic sweep
#
#   Note: Requires INCLUDE_CRON=true (auto-enabled with INCLUDE_RUST_DEV)
#
# Requirements:
#   - Rust/Cargo must be installed (via INCLUDE_RUST=true)
#
# Note:
#   These tools significantly improve Rust development workflow,
#   especially for large projects or continuous development.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities (retry_with_backoff) for hardening cargo binstall
# against transient network failures on its from-source fallback path (#544)
source /tmp/build-scripts/base/retry-utils.sh

# Source GitHub release installer for binary tool downloads (used for mold)
source /tmp/build-scripts/features/lib/install-github-release.sh

# Start logging
log_feature_start "Rust Development Tools"

# ============================================================================
# Cargo Tool Versions
# ============================================================================
# Every cargo (b)install below is --locked and pinned to an explicit @version so
# upstream drift on crates.io cannot retroactively break a previously-working
# build. Auto-bumped weekly via bin/check-versions.sh (crates.io API).
# cargo-watch and mdbook are also pinned in rust.sh (same feature chain);
# keep the defaults in sync between the two files.
#
# Tools are installed with `cargo binstall` (downloads a prebuilt, checksum-
# verified binary) instead of `cargo install` (compiles from source). This is
# the deeper fix for the CI cold-build timeout (#517): the from-source compile
# of this ~20-tool suite exceeded 25min on a cold cache. binstall falls back to
# `cargo install` automatically for any crate without a prebuilt binary, so the
# from-source path still works (just slower for that one crate).
CARGO_BINSTALL_VERSION="${CARGO_BINSTALL_VERSION:-1.20.0}"
TREE_SITTER_CLI_VERSION="${TREE_SITTER_CLI_VERSION:-0.26.8}"
CARGO_WATCH_VERSION="${CARGO_WATCH_VERSION:-8.5.3}"
CARGO_EXPAND_VERSION="${CARGO_EXPAND_VERSION:-1.0.121}"
CARGO_MODULES_VERSION="${CARGO_MODULES_VERSION:-0.26.0}"
CARGO_OUTDATED_VERSION="${CARGO_OUTDATED_VERSION:-0.19.0}"
CARGO_SWEEP_VERSION="${CARGO_SWEEP_VERSION:-0.8.0}"
CARGO_AUDIT_VERSION="${CARGO_AUDIT_VERSION:-0.22.1}"
CARGO_DENY_VERSION="${CARGO_DENY_VERSION:-0.19.6}"
CARGO_GEIGER_VERSION="${CARGO_GEIGER_VERSION:-0.13.0}"
CARGO_MACHETE_VERSION="${CARGO_MACHETE_VERSION:-0.9.2}"
NEXTEST_VERSION="${NEXTEST_VERSION:-0.9.133}"
LLVM_COV_VERSION="${LLVM_COV_VERSION:-0.8.7}"
BACON_VERSION="${BACON_VERSION:-3.22.0}"
TOKEI_VERSION="${TOKEI_VERSION:-14.0.0}"
HYPERFINE_CARGO_VERSION="${HYPERFINE_CARGO_VERSION:-1.20.0}"
JUST_CARGO_VERSION="${JUST_CARGO_VERSION:-1.51.0}"
SCCACHE_VERSION="${SCCACHE_VERSION:-0.15.0}"
MDBOOK_VERSION="${MDBOOK_VERSION:-0.5.2}"
CARGO_RELEASE_VERSION="${CARGO_RELEASE_VERSION:-1.1.2}"
TAPLO_CLI_VERSION="${TAPLO_CLI_VERSION:-0.10.0}"
MOLD_VERSION="${MOLD_VERSION:-2.41.0}"

# ============================================================================
# Prerequisites Check
# ============================================================================
require_feature_binary "/usr/local/bin/cargo" "INCLUDE_RUST"

# ============================================================================
# System Dependencies
# ============================================================================
# Update package lists with retry logic
apt_update

log_message "Installing system dependencies for Rust dev tools"
# build-essential needed for compiling Rust crates with C dependencies
# pkg-config needed for finding system libraries
# libssl-dev needed for crates using OpenSSL
# cmake needed for some complex crates
# libclang-dev needed for bindgen (used by tree-sitter-cli and other crates)
apt_install \
    build-essential \
    pkg-config \
    libssl-dev \
    cmake \
    libclang-dev

# ============================================================================
# Rust Development Tools Installation
# ============================================================================
log_message "Installing Rust development tools via Cargo..."

# Use the cargo symlink we created
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"

# ----------------------------------------------------------------------------
# Bootstrap cargo-binstall (prebuilt-binary installer)
# ----------------------------------------------------------------------------
# Installed from its own prebuilt release rather than `cargo install` (which
# would defeat the purpose by compiling it from source). The musl tarball is a
# single static `cargo-binstall` binary; install_github_release handles arch
# detection and runs it through the 4-tier verification (Tier 2 pinned checksum
# in lib/checksums.json) before placing it in /usr/local/bin — so the cached
# path keeps checksum integrity.
log_message "Installing cargo-binstall ${CARGO_BINSTALL_VERSION}..."
install_github_release "cargo-binstall" "${CARGO_BINSTALL_VERSION}" \
    "https://github.com/cargo-bins/cargo-binstall/releases/download/v${CARGO_BINSTALL_VERSION}" \
    "cargo-binstall-x86_64-unknown-linux-musl.tgz" \
    "cargo-binstall-aarch64-unknown-linux-musl.tgz" \
    "calculate" "extract_flat:cargo-binstall"
# Make it discoverable as a cargo subcommand for the user's cargo too.
if [ -x /usr/local/bin/cargo-binstall ] && [ ! -e "${CARGO_HOME}/bin/cargo-binstall" ]; then
    mkdir -p "${CARGO_HOME}/bin"
    ln -s /usr/local/bin/cargo-binstall "${CARGO_HOME}/bin/cargo-binstall" || true
fi

# ----------------------------------------------------------------------------
# binstall helper
# ----------------------------------------------------------------------------
# Wraps `cargo binstall` with the flags we always want:
#   --locked       honour Cargo.lock (parity with the old `cargo install --locked`)
#   --no-confirm   non-interactive (required in a build)
#   --disable-telemetry  no phone-home during builds
# Runs as ${USERNAME} so artifacts land under /cache/cargo with correct
# ownership, mirroring the previous cargo-install invocation. GITHUB_TOKEN (if
# provided via a BuildKit secret) is forwarded so binstall's GitHub API lookups
# aren't rate-limited on shared CI runners; absent, it degrades to
# unauthenticated requests, which is fine for local builds.
# The whole binstall call is wrapped in retry_with_backoff: when binstall
# can't find a prebuilt binary it falls back to `cargo install --locked` from
# source, which makes live crates.io downloads. A single transient network
# blip there would otherwise abort the entire image build (observed with
# taplo-cli@0.10.0, #544). Retries cover both the prebuilt-fetch and the
# from-source fallback paths. --locked and the explicit @version pins are
# preserved, so a retry never silently changes what gets installed.
#
# --log-level info makes binstall announce whether it resolved a prebuilt
# binary or fell back to compiling from source, so future flakes are easy to
# attribute from the build log.
cargo_binstall_tool() {
    local spec="$1"
    retry_with_backoff su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' GITHUB_TOKEN='${GITHUB_TOKEN:-}' && /usr/local/bin/cargo binstall --locked --no-confirm --disable-telemetry --log-level info ${spec}"
}

# Core development tools
# Run as the user to ensure correct ownership
log_command "Installing tree-sitter-cli" \
    cargo_binstall_tool "tree-sitter-cli@${TREE_SITTER_CLI_VERSION}"

log_command "Installing cargo-watch" \
    cargo_binstall_tool "cargo-watch@${CARGO_WATCH_VERSION}"

log_command "Installing cargo-expand" \
    cargo_binstall_tool "cargo-expand@${CARGO_EXPAND_VERSION}"

log_command "Installing cargo-modules" \
    cargo_binstall_tool "cargo-modules@${CARGO_MODULES_VERSION}"

log_command "Installing cargo-outdated" \
    cargo_binstall_tool "cargo-outdated@${CARGO_OUTDATED_VERSION}"

log_command "Installing cargo-sweep" \
    cargo_binstall_tool "cargo-sweep@${CARGO_SWEEP_VERSION}"

log_command "Installing cargo-audit" \
    cargo_binstall_tool "cargo-audit@${CARGO_AUDIT_VERSION}"

log_command "Installing cargo-deny" \
    cargo_binstall_tool "cargo-deny@${CARGO_DENY_VERSION}"

log_command "Installing cargo-geiger" \
    cargo_binstall_tool "cargo-geiger@${CARGO_GEIGER_VERSION}"

log_command "Installing cargo-machete" \
    cargo_binstall_tool "cargo-machete@${CARGO_MACHETE_VERSION}"

log_command "Installing cargo-nextest" \
    cargo_binstall_tool "cargo-nextest@${NEXTEST_VERSION}"

# cargo-llvm-cov drives `cargo` with LLVM source-based coverage instrumentation;
# the llvm-tools-preview component ships profdata/cov binaries it shells out to.
# This adds it to the build-time default toolchain; the first-startup hook
# below reconciles it onto a workspace-pinned toolchain too, so `cargo
# llvm-cov` under a rust-toolchain.toml pin doesn't trip an interactive
# component-install prompt that hangs CI (#487). Retried because the component
# download is a live network fetch.
log_command "Adding llvm-tools-preview rustup component for cargo-llvm-cov" \
    retry_with_backoff su - "${USERNAME}" -c "export CARGO_HOME='${CARGO_HOME}' RUSTUP_HOME='${RUSTUP_HOME}' && /usr/local/bin/rustup component add llvm-tools-preview"

log_command "Installing cargo-llvm-cov" \
    cargo_binstall_tool "cargo-llvm-cov@${LLVM_COV_VERSION}"

log_command "Installing bacon" \
    cargo_binstall_tool "bacon@${BACON_VERSION}"

log_command "Installing tokei" \
    cargo_binstall_tool "tokei@${TOKEI_VERSION}"

log_command "Installing hyperfine" \
    cargo_binstall_tool "hyperfine@${HYPERFINE_CARGO_VERSION}"

# Skip if already installed by dev-tools
if ! command -v just &>/dev/null; then
    log_command "Installing just" \
        cargo_binstall_tool "just@${JUST_CARGO_VERSION}"
else
    log_message "just already installed, skipping..."
fi

log_command "Installing sccache" \
    cargo_binstall_tool "sccache@${SCCACHE_VERSION}"

log_command "Installing mdbook" \
    cargo_binstall_tool "mdbook@${MDBOOK_VERSION}"

log_command "Installing cargo-release" \
    cargo_binstall_tool "cargo-release@${CARGO_RELEASE_VERSION}"

# Install taplo-cli (TOML formatter/linter) if not already installed by dev-tools
if ! command -v taplo &>/dev/null; then
    log_command "Installing taplo-cli" \
        cargo_binstall_tool "taplo-cli@${TAPLO_CLI_VERSION}"
else
    log_message "taplo already installed, skipping..."
fi

# ============================================================================
# Mold Linker (Linux-only, pre-built binary)
# ============================================================================
# mold is a faster drop-in replacement for ld; projects opt in via
# .cargo/config.toml. The release tarball lays out as
# mold-${VERSION}-${arch}-linux/{bin/mold,bin/ld.mold,...}; we extract just the
# `mold` binary and create the conventional `ld.mold` symlink so downstream
# `linker = "/usr/bin/clang"` + `link-arg=-fuse-ld=mold` configs find it.
log_message "Installing mold linker ${MOLD_VERSION}..."
install_github_release "mold" "${MOLD_VERSION}" \
    "https://github.com/rui314/mold/releases/download/v${MOLD_VERSION}" \
    "mold-${MOLD_VERSION}-x86_64-linux.tar.gz" \
    "mold-${MOLD_VERSION}-aarch64-linux.tar.gz" \
    "calculate" "extract:mold"

# Provide the canonical ld.mold name. mold treats argv[0] to decide its mode
# (linker vs. driver), so a hard symlink works the same as the upstream binary.
if [ -x /usr/local/bin/mold ] && [ ! -e /usr/local/bin/ld.mold ]; then
    log_command "Creating ld.mold symlink" \
        ln -s /usr/local/bin/mold /usr/local/bin/ld.mold
fi

# Create symlinks for the installed tools
log_message "Creating symlinks for Rust dev tools..."
for tool in tree-sitter cargo-watch cargo-expand cargo-modules cargo-outdated cargo-sweep cargo-audit cargo-deny cargo-geiger cargo-machete cargo-nextest cargo-llvm-cov bacon tokei hyperfine just sccache mdbook cargo-release taplo; do
    if [ -f "${CARGO_HOME}/bin/${tool}" ]; then
        create_symlink "${CARGO_HOME}/bin/${tool}" "/usr/local/bin/${tool}" "${tool} Rust dev tool"
    fi
done

# ============================================================================
# Verification and Helpers
# ============================================================================
# Create verification script
command cat >/usr/local/bin/test-rust-dev <<'EOF'
#!/bin/bash
echo "=== Rust Development Tools Status ==="
tools=(
    "tree-sitter"
    "cargo-watch"
    "cargo-expand"
    "cargo-modules"
    "cargo-outdated"
    "cargo-sweep"
    "cargo-audit"
    "cargo-deny"
    "cargo-geiger"
    "cargo-machete"
    "cargo-nextest"
    "cargo-llvm-cov"
    "bacon"
    "tokei"
    "hyperfine"
    "just"
    "sccache"
    "mdbook"
    "cargo-release"
    "taplo"
    "mold"
)

installed=0
for tool in "${tools[@]}"; do
    if command -v "$tool" &> /dev/null; then
        echo "✓ $tool is installed"
        ((installed++))
    else
        echo "✗ $tool is not found"
    fi
done

echo ""
echo "Installed: $installed/${#tools[@]} tools"
EOF

log_command "Setting test-rust-dev script permissions" \
    chmod +x /usr/local/bin/test-rust-dev

# ============================================================================
# Shell Helpers
# ============================================================================
echo "=== Setting up Rust development helpers ==="

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add rust-dev aliases and helpers (content in lib/bashrc/rust-dev.sh)
write_bashrc_content /etc/bashrc.d/35-rust-dev.sh "Rust development tools configuration" \
    </tmp/build-scripts/features/lib/bashrc/rust-dev.sh

log_command "Setting Rust dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/35-rust-dev.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
echo "=== Creating rust-dev startup script ==="

# Create startup directory if it doesn't exist
log_command "Creating startup directory" \
    mkdir -p /etc/container/first-startup

command cat >/etc/container/first-startup/20-rust-dev-setup.sh <<'EOF'
#!/bin/bash
# Rust development tools configuration
if command -v cargo &> /dev/null; then
    echo "=== Rust Development Tools ==="

    # Check which tools are installed
    tools_found=()
    [ -x "$(command -v tree-sitter)" ] && tools_found+=("tree-sitter")
    [ -x "$(command -v cargo-watch)" ] && tools_found+=("cargo-watch")
    [ -x "$(command -v cargo-nextest)" ] && tools_found+=("cargo-nextest")
    [ -x "$(command -v cargo-llvm-cov)" ] && tools_found+=("cargo-llvm-cov")
    [ -x "$(command -v cargo-machete)" ] && tools_found+=("cargo-machete")
    [ -x "$(command -v bacon)" ] && tools_found+=("bacon")
    [ -x "$(command -v just)" ] && tools_found+=("just")
    [ -x "$(command -v tokei)" ] && tools_found+=("tokei")
    [ -x "$(command -v sccache)" ] && tools_found+=("sccache")
    [ -x "$(command -v mdbook)" ] && tools_found+=("mdbook")
    [ -x "$(command -v mold)" ] && tools_found+=("mold")

    if [ ${#tools_found[@]} -gt 0 ]; then
        echo "Installed tools: ${tools_found[*]}"
        echo ""
        echo "Quick commands:"
        echo "  cargo watch -x run        - Auto-rebuild on changes"
        echo "  cargo nextest run         - Faster test runner"
        echo "  cargo llvm-cov            - Source-based coverage"
        echo "  cargo machete             - Find unused dependencies"
        echo "  bacon                     - Background compilation"
        echo "  just                      - Run project tasks"
        echo "  tokei                     - Count lines of code"
        echo "  mold --version            - Fast linker (opt in via .cargo/config.toml)"
        echo "  rust-dev-enable-sccache   - Enable compilation cache"
    fi

    # Check for Rust projects
    if [ -f ${WORKING_DIR}/Cargo.toml ]; then
        echo ""
        echo "Rust project detected!"

        # Suggest creating a justfile if it doesn't exist
        if [ ! -f ${WORKING_DIR}/justfile ] && command -v just &> /dev/null; then
            echo "Tip: Run 'just-init' to create a justfile for common tasks"
        fi

        # Enable sccache if available
        if command -v sccache &> /dev/null && [ -z "$RUSTC_WRAPPER" ]; then
            echo "Tip: Run 'rust-dev-enable-sccache' for faster builds"
        fi
    fi

    # Check for tree-sitter grammar projects
    if compgen -G "${WORKING_DIR}/tree-sitter-*" > /dev/null || [ -f ${WORKING_DIR}/grammar.js ]; then
        echo ""
        echo "Tree-sitter grammar project detected!"
        echo "Use 'tree-sitter generate' to build your parser"
    fi
fi
EOF

log_command "Setting startup script permissions" \
    chmod +x /etc/container/first-startup/20-rust-dev-setup.sh

# ----------------------------------------------------------------------------
# Pinned-toolchain llvm-tools-preview reconciliation (#487)
# ----------------------------------------------------------------------------
# llvm-tools-preview is added to the build-time default toolchain above, but a
# project pinning a different toolchain via rust-toolchain.toml would get that
# toolchain without it — and `cargo llvm-cov` then trips an interactive
# component-install prompt that hangs CI. The base rust feature installs the
# rust-ensure-pinned-components helper (and reconciles its own components); we
# layer llvm-tools-preview onto the pinned toolchain here so coverage works
# under a pin. Idempotent: a no-op when the pin matches the default.
command cat >/etc/container/first-startup/21-rust-dev-toolchain-components.sh <<'EOF'
#!/bin/bash
# Reconcile llvm-tools-preview onto a workspace-pinned toolchain so
# `cargo llvm-cov` works when a project pins a toolchain other than the image
# default via rust-toolchain.toml (#487).
if command -v rust-ensure-pinned-components >/dev/null 2>&1; then
    rust-ensure-pinned-components "${WORKING_DIR:-$PWD}" llvm-tools-preview
fi
EOF

log_command "Setting rust-dev toolchain component startup script permissions" \
    chmod +x /etc/container/first-startup/21-rust-dev-toolchain-components.sh

# ============================================================================
# Cron Job for cargo-sweep
# ============================================================================
echo "=== Creating cargo-sweep cron job ==="

# Create cron.d directory if it doesn't exist
log_command "Creating cron.d directory" \
    mkdir -p /etc/cron.d

# Create the wrapper script that cron will execute
command cat >/usr/local/bin/cargo-sweep-cron <<'SWEEP_SCRIPT_EOF'
#!/bin/bash
# Wrapper script for cargo-sweep cron job
# Sources container environment and respects configuration

# Load container environment (provides PATH, CARGO_HOME, etc.)
if [ -f /etc/container/cron-env ]; then
    source /etc/container/cron-env
fi

# Check if disabled
if [ "${CARGO_SWEEP_DISABLE:-false}" = "true" ]; then
    exit 0
fi

# Check if cargo-sweep is available
if ! command -v cargo-sweep &> /dev/null; then
    exit 0
fi

# Configuration
SWEEP_DAYS="${CARGO_SWEEP_DAYS:-14}"
WORKING_DIR="${WORKING_DIR:-/workspace}"

# Only sweep if we have Rust projects in the workspace
if [ -d "$WORKING_DIR" ]; then
    # Find all directories with Cargo.toml and sweep them
    command find "$WORKING_DIR" -name "Cargo.toml" -type f 2>/dev/null | while read -r cargo_file; do
        project_dir=$(dirname "$cargo_file")
        if [ -d "$project_dir/target" ]; then
            logger -t cargo-sweep "Cleaning artifacts older than ${SWEEP_DAYS} days in $project_dir"
            cargo-sweep sweep --time "$SWEEP_DAYS" "$project_dir" 2>/dev/null || true
        fi
    done
fi
SWEEP_SCRIPT_EOF

log_command "Setting cargo-sweep-cron script permissions" \
    chmod +x /usr/local/bin/cargo-sweep-cron

# Create the cron job in /etc/cron.d/
# Runs every 6 hours at minute 0
# Note: USERNAME is substituted at build time
command cat >/etc/cron.d/cargo-sweep <<CRON_EOF
# Cargo-sweep automatic cleanup - clean old Rust build artifacts
# Runs every 6 hours
# Configuration via environment variables:
#   CARGO_SWEEP_DAYS - Age threshold in days (default: 14)
#   CARGO_SWEEP_DISABLE - Set to "true" to disable

SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

# Run at minute 0 of hours 0, 6, 12, 18
0 */6 * * * ${USERNAME} /usr/local/bin/cargo-sweep-cron
CRON_EOF

log_command "Setting cargo-sweep cron job permissions" \
    chmod 644 /etc/cron.d/cargo-sweep

# ============================================================================
# Final ownership fix
# ============================================================================
# Note: rust-dev does not create cache directories itself, it relies on the base rust feature
# This final ownership fix ensures cargo cache is owned correctly after tool installations
log_message "Ensuring correct ownership of Rust directories..."
log_command "Final ownership fix for cargo cache" \
    chown -R "${USER_UID}:${USER_GID}" "${CARGO_HOME}" "${RUSTUP_HOME}" || true

# Log feature summary
# Export directory paths for feature summary (also defined in parent rust.sh)
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"
log_feature_summary \
    --feature "Rust Development Tools" \
    --tools "rust-analyzer,clippy,rustfmt,cargo-watch,cargo-audit,cargo-outdated,cargo-sweep,cargo-expand,cargo-modules,cargo-release,cargo-deny,cargo-geiger,cargo-machete,cargo-nextest,cargo-llvm-cov,sccache,bacon,tokei,hyperfine,just,mdbook,taplo,mold" \
    --paths "${CARGO_HOME},${RUSTUP_HOME}" \
    --env "CARGO_HOME,RUSTUP_HOME,CARGO_SWEEP_DAYS,CARGO_SWEEP_DISABLE" \
    --commands "rust-analyzer,cargo-clippy,cargo-fmt,cargo-watch,cargo-audit,cargo-outdated,cargo-sweep,cargo-machete,cargo-nextest,cargo-llvm-cov,bacon,mold,ld.mold,rust-lint-all,rust-security-check,rust-watch" \
    --next-steps "Run 'test-rust-dev' to check installed tools. Use 'cargo clippy' for linting, 'cargo fmt' for formatting, 'cargo watch' for hot reload, 'cargo nextest run' for fast tests, 'cargo llvm-cov' for coverage, 'cargo machete' to find unused deps, 'cargo sweep --time 14' to clean old artifacts. Opt into mold by setting linker = \"clang\" / link-arg = \"-fuse-ld=mold\" in .cargo/config.toml."

# End logging
log_feature_end

log_feature_instructions "test-rust-dev" "rust-development-tools"
