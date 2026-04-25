#!/bin/bash
# Development Tools - Modern CLI utilities and productivity enhancers
#
# Description:
#   Installs a comprehensive set of development tools for enhanced productivity.
#   Includes modern CLI replacements, git helpers, monitoring tools, and more.
#
# Features:
#   - Modern CLI replacements: eza (ls), bat (cat), duf (df), fd (find), ripgrep (grep)
#   - Git helpers: lazygit, delta (side-by-side diffs), git-cliff, tig, colordiff
#   - Development utilities: direnv, entr, fzf (fuzzy finder), inotify-tools
#   - Network tools: netcat-openbsd, dnsutils, iputils-ping, traceroute
#   - System monitoring: htop, iotop, sysstat, strace, lsof, dua-cli
#   - Security tools: mkcert (local HTTPS certificates)
#   - Archive tools: zip, unzip
#   - GitHub/GitLab CLIs: gh, act (local GitHub Actions), glab
#   - Text processing: jq, xxd
#   - Search tools: silversearcher-ag, ack, tree, rsync
#   - Build tools: build-essential, pkg-config, libssl-dev, libffi-dev
#   - Terminal tools: tmux, xclip
#   - Text editors: nano, vim
#   - Process management: supervisor
#   - Linting/Formatting: biome (fast linter/formatter for JS/TS/JSON/CSS),
#                         shfmt (shell script formatter)
#   - TOML tools: taplo (TOML formatter and linter)
#   - AI tools: agnix (AI agent config linter, requires Node.js),
#               agentsys (AI plugin marketplace, requires Node.js)
#   - Spell checking: typos (Rust static binary, code-aware),
#                     cspell (Node.js-based, richer dictionary; optional)
#
# Note: Claude Code CLI, plugins, and MCP servers are now installed by
#       claude-code-setup.sh which runs after this script.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source download verification utilities for secure binary downloads
source /tmp/build-scripts/base/download-verify.sh

# Source checksum fetching utilities for dynamic checksum retrieval
source /tmp/build-scripts/base/checksum-fetch.sh
source /tmp/build-scripts/base/cache-utils.sh

# Source GitHub release installer for binary tool installations
source /tmp/build-scripts/features/lib/install-github-release.sh

# Start logging
log_feature_start "Development Tools"

# ============================================================================
# Version Configuration
# ============================================================================
# Tool versions (can be overridden via environment variables)
DUF_VERSION="${DUF_VERSION:-0.9.1}"
DIRENV_VERSION="${DIRENV_VERSION:-2.37.1}"
ENTR_VERSION="${ENTR_VERSION:-5.8}"
MKCERT_VERSION="${MKCERT_VERSION:-1.4.4}"
GLAB_VERSION="${GLAB_VERSION:-1.93.0}"
LAZYGIT_VERSION="${LAZYGIT_VERSION:-0.61.1}"
DELTA_VERSION="${DELTA_VERSION:-0.19.2}"
ACT_VERSION="${ACT_VERSION:-0.2.87}"
GITCLIFF_VERSION="${GITCLIFF_VERSION:-2.8.0}"
BIOME_VERSION="${BIOME_VERSION:-2.4.13}"
TAPLO_VERSION="${TAPLO_VERSION:-0.10.0}"
JUST_VERSION="${JUST_VERSION:-1.50.0}"
EZA_VERSION="${EZA_VERSION:-0.23.4}"
UV_VERSION="${UV_VERSION:-0.11.7}"
LEFTHOOK_VERSION="${LEFTHOOK_VERSION:-2.1.6}"
GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.30.1}"
RUMDL_VERSION="${RUMDL_VERSION:-0.1.81}"
DPRINT_VERSION="${DPRINT_VERSION:-0.54.0}"
OSV_SCANNER_VERSION="${OSV_SCANNER_VERSION:-2.3.5}"
YQ_VERSION="${YQ_VERSION:-4.53.2}"
SD_VERSION="${SD_VERSION:-1.1.0}"
DUA_VERSION="${DUA_VERSION:-2.34.0}"
HYPERFINE_VERSION="${HYPERFINE_VERSION:-1.20.0}"
VALE_VERSION="${VALE_VERSION:-3.14.1}"
TYPOS_VERSION="${TYPOS_VERSION:-1.45.1}"
SHFMT_VERSION="${SHFMT_VERSION:-3.13.1}"
CONFORM_VERSION="${CONFORM_VERSION:-0.1.0-alpha.31}"
HADOLINT_VERSION="${HADOLINT_VERSION:-2.14.0}"
ACTIONLINT_VERSION="${ACTIONLINT_VERSION:-1.7.12}"

# ============================================================================
# Repository Configuration
# ============================================================================
log_message "Configuring repositories for development tools..."

# Add GitHub CLI repository
log_message "Adding GitHub CLI GPG key"
retry_with_backoff curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg

log_command "Setting GitHub CLI GPG key permissions" \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

log_command "Adding GitHub CLI repository" \
    bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list'

# Update package lists with retry logic
apt_update

# ============================================================================
# Package Installation
# ============================================================================
log_message "Installing development tools grouped by category..."

# ----------------------------------------------------------------------------
# Build Tools (required for compiling tools from source)
# ----------------------------------------------------------------------------
log_message "Installing build tools for development..."
apt_install \
    build-essential \
    pkg-config \
    libssl-dev \
    libffi-dev

# ----------------------------------------------------------------------------
# Version Control Extras
# ----------------------------------------------------------------------------
log_message "Installing version control tools..."
apt_install \
    tig \
    colordiff \
    gh

# ----------------------------------------------------------------------------
# Search and File Tools
# ----------------------------------------------------------------------------
log_message "Installing search and file tools..."
apt_install \
    ripgrep \
    fd-find \
    silversearcher-ag \
    ack \
    tree \
    rsync \
    zip \
    unzip

# Terminal and monitoring tools
log_message "Installing terminal and monitoring tools..."
apt_install \
    htop \
    bat \
    tmux

# Modern ls replacement - Debian version dependent
# Debian 13+: eza available from apt
# Debian 11/12: eza installed from GitHub release (exa is archived upstream)
if is_debian_version 13; then
    log_message "Installing eza (modern ls replacement) from apt..."
    apt_install eza
else
    log_message "Installing eza (modern ls replacement) from GitHub release..."
    install_github_release "eza" "$EZA_VERSION" \
        "https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}" \
        "eza_x86_64-unknown-linux-gnu.tar.gz" \
        "eza_aarch64-unknown-linux-gnu.tar.gz" \
        "calculate" "extract_flat:eza"
fi

# Network debugging tools
# nmap package also provides ncat (feature-rich netcat) and nping
log_message "Installing network debugging tools..."
apt_install \
    netcat-openbsd \
    nmap \
    dnsutils \
    iputils-ping \
    traceroute

# System monitoring and debugging
log_message "Installing system monitoring tools..."
apt_install \
    lsof \
    strace \
    sysstat \
    iotop

# File processing extras
log_message "Installing file processing tools..."
apt_install \
    jq \
    xxd

# Development helpers
log_message "Installing development helpers..."
apt_install \
    inotify-tools \
    supervisor \
    xclip

# Replace the stock Debian supervisord.conf, which targets /var/run and
# /var/log/supervisor (both root-owned) and therefore EACCES-fails under any
# non-root USERNAME this image ships. The shipped config redirects pidfile,
# socket, and logs under /tmp. See issue #386.
log_command "Installing non-root-safe supervisord.conf" \
    install -m 0644 \
    /tmp/build-scripts/features/lib/dev-tools/supervisord.conf \
    /etc/supervisor/supervisord.conf

# Text editors
log_message "Installing text editors..."
apt_install \
    nano \
    vim

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring environment and aliases..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide dev tools configuration (content in lib/bashrc/dev-tools.sh)
write_bashrc_content /etc/bashrc.d/80-dev-tools.sh "dev tools bashrc configuration" \
    </tmp/build-scripts/features/lib/bashrc/dev-tools.sh

# ============================================================================
# Binary Tool Installations
# ============================================================================
source /tmp/build-scripts/features/lib/dev-tools/install-binary-tools.sh

log_message "Installing additional development tools..."

install_github_binary_tools
install_entr

log_message "Installing fzf (fuzzy finder)..."
if ! install_fzf; then
    log_warning "fzf installation failed, continuing without fzf"
    log_warning "fzf will not be available in this container"
else
    if [ -d /opt/fzf ]; then
        log_command "Setting fzf directory ownership" \
            chown -R "${USER_UID}:${USER_GID}" /opt/fzf
    fi
fi

create_tool_symlinks

# ============================================================================
# Build-Time Configuration for Runtime
# ============================================================================
source /tmp/build-scripts/features/lib/dev-tools/persist-feature-flags.sh

log_message "Writing build configuration for runtime..."
persist_feature_flags

# ============================================================================
# Git Configuration
# ============================================================================
log_message "Configuring git to use delta..."

command cat /tmp/build-scripts/features/lib/dev-tools/gitconfig-delta >>/etc/gitconfig

# Add tool-specific configurations to bashrc.d (content in lib/bashrc/dev-tools-extras.sh)
write_bashrc_content /etc/bashrc.d/80-dev-tools.sh "tool-specific configurations" \
    </tmp/build-scripts/features/lib/bashrc/dev-tools-extras.sh

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring cache directories for development tools..."

# Some tools benefit from cache directories
DEV_TOOLS_CACHE="/cache/dev-tools"

# Create cache directory using shared utility
create_cache_directories "${DEV_TOOLS_CACHE}"

# Configure tools to use cache where applicable (content in lib/bashrc/dev-tools-cache.sh)
write_bashrc_content /etc/bashrc.d/80-dev-tools.sh "cache configuration" \
    </tmp/build-scripts/features/lib/bashrc/dev-tools-cache.sh

# Make bashrc.d script executable to match other scripts in the directory
log_command "Setting dev-tools bashrc script permissions" \
    chmod 755 /etc/bashrc.d/80-dev-tools.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating dev tools verification script..."

install -m 755 /tmp/build-scripts/features/lib/dev-tools/test-dev-tools.sh /usr/local/bin/test-dev-tools

# Export directory paths for feature summary (also defined in bashrc for runtime)
export DEV_TOOLS_CACHE="/cache/dev-tools"
export CAROOT="${DEV_TOOLS_CACHE}/mkcert-ca"
export DIRENV_ALLOW_DIR="${DEV_TOOLS_CACHE}/direnv-allow"

# Log feature summary
log_feature_summary \
    --feature "Development Tools" \
    --tools "gh,lazygit,delta,act,git-cliff,glab,biome,taplo,uv,duf,entr,fzf,direnv,mkcert,jq,ripgrep,fd,bat,eza,htop,dua,lefthook,gitleaks,osv-scanner,hadolint,actionlint,rumdl,dprint,typos,shfmt,conform,agnix,agentsys,cspell" \
    --paths "${DEV_TOOLS_CACHE},/opt/fzf,${CAROOT}" \
    --env "DEV_TOOLS_CACHE,CAROOT,DIRENV_ALLOW_DIR,ENABLE_LSP_TOOL" \
    --commands "gh,lazygit,delta,act,git-cliff,glab,biome,uv,uvx,duf,entr,fzf,direnv,mkcert,jq,rg,fd,bat,eza,htop,dua,lefthook,gitleaks,osv-scanner,hadolint,actionlint,rumdl,dprint,typos,shfmt,conform,agnix,agentsys,cspell" \
    --next-steps "Run 'test-dev-tools' to verify installation. Many modern CLI replacements are aliased (ls=eza, cat=bat, grep=rg, find=fd). Claude Code is installed separately by claude-code-setup.sh."

# End logging
log_feature_end

log_feature_instructions "test-dev-tools" "development-tools"
