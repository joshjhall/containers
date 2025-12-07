#!/bin/bash
# Development Tools - Modern CLI utilities and productivity enhancers
#
# Description:
#   Installs a comprehensive set of development tools for enhanced productivity.
#   Includes modern CLI replacements, git helpers, monitoring tools, and more.
#
# Features:
#   - Modern CLI replacements: eza/exa (ls), bat (cat), duf (df), fd (find), ripgrep (grep)
#   - Git helpers: lazygit, delta (side-by-side diffs), git-cliff (changelog generation)
#   - Development utilities: direnv, just (with modules), entr
#   - Network tools: telnet, netcat, nmap, tcpdump, socat, whois
#   - System monitoring: htop, btop, iotop, sysstat, strace
#   - Security tools: mkcert (local HTTPS certificates)
#   - Archive tools: unzip, zip, tar, 7zip
#   - GitHub/GitLab CLIs: gh, act (local GitHub Actions), glab
#   - Text processing: jq
#   - Release tools: git-cliff (automatic changelog from conventional commits)
#   - Linting/Formatting: biome (fast linter/formatter for JS/TS/JSON/CSS)
#   - TOML tools: taplo (TOML formatter and linter)
#   - Claude Code CLI tool
#   - And many more productivity tools
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
source /tmp/build-scripts/features/lib/checksum-fetch.sh
source /tmp/build-scripts/base/cache-utils.sh

# Start logging
log_feature_start "Development Tools"

# ============================================================================
# Version Configuration
# ============================================================================
# Tool versions (can be overridden via environment variables)
LAZYGIT_VERSION="${LAZYGIT_VERSION:-0.57.0}"
DELTA_VERSION="${DELTA_VERSION:-0.18.2}"
ACT_VERSION="${ACT_VERSION:-0.2.83}"
GITCLIFF_VERSION="${GITCLIFF_VERSION:-2.8.0}"
BIOME_VERSION="${BIOME_VERSION:-1.9.4}"
TAPLO_VERSION="${TAPLO_VERSION:-0.10.0}"

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
    zip

# Terminal and monitoring tools
log_message "Installing terminal and monitoring tools..."
apt_install \
    htop \
    ncdu \
    bat \
    tmux

# Modern ls replacement - Debian version dependent
# Debian 11/12: exa (deprecated upstream but only option)
# Debian 13+: eza (maintained fork)
if is_debian_version 13; then
    log_message "Installing eza (modern ls replacement)..."
    apt_install eza
else
    log_message "Installing exa (modern ls replacement)..."
    apt_install exa
fi

# Network debugging tools
log_message "Installing network debugging tools..."
apt_install \
    netcat-openbsd \
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
    xxd

# Development helpers
log_message "Installing development helpers..."
apt_install \
    inotify-tools \
    supervisor \
    xclip

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

# Create system-wide dev tools configuration
write_bashrc_content /etc/bashrc.d/80-dev-tools.sh "dev tools bashrc configuration" << 'DEV_TOOLS_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Development Tools Configuration and Helpers
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

# Override with modern tool aliases when available
# Prefer eza (maintained) over exa (deprecated but still in older Debian)
if command -v eza &> /dev/null; then
    alias ls='eza'
    alias ll='eza -la'
    alias la='eza -a'
    alias l='eza -F'
    alias tree='eza --tree'
elif command -v exa &> /dev/null; then
    alias ls='exa'
    alias ll='exa -la'
    alias la='exa -a'
    alias l='exa -F'
    alias tree='exa --tree'
fi

if command -v batcat &> /dev/null; then
    alias cat='batcat --style=plain'
    alias bat='batcat'
    alias less='batcat --paging=always'
    export LESSOPEN="| /usr/bin/env batcat --color=always --style=plain %s 2>/dev/null"
elif command -v bat &> /dev/null; then
    alias cat='bat --style=plain'
    alias less='bat --paging=always'
    export LESSOPEN="| /usr/bin/env bat --color=always --style=plain %s 2>/dev/null"
fi

if command -v fdfind &> /dev/null; then
    alias fd='fdfind'
    alias find='fdfind'  # Direct override for muscle memory
elif command -v fd &> /dev/null; then
    alias find='fd'  # Direct override for muscle memory
fi

if command -v rg &> /dev/null; then
    alias grep='rg'
    alias egrep='rg'
    alias fgrep='rg -F'
fi

if command -v duf &> /dev/null; then
    alias df='duf'
fi

if command -v ncdu &> /dev/null; then
    alias du='echo "Hint: Try ncdu for an interactive disk usage analyzer" && du'
fi

if command -v htop &> /dev/null; then
    alias top='htop'
fi

# Git aliases with delta
if command -v delta &> /dev/null; then
    alias gd='git diff'
    alias gdc='git diff --cached'
    alias gdh='git diff HEAD'
fi

# GitHub CLI aliases
if command -v gh &> /dev/null; then
    alias ghpr='gh pr create'
    alias ghprs='gh pr list'
    alias ghprv='gh pr view'
    alias ghprc='gh pr checks'
    alias ghis='gh issue list'
    alias ghiv='gh issue view'
    alias ghruns='gh run list'
    alias ghrunv='gh run view'
fi

# Additional modern tool shortcuts
# (ipython alias moved to python-dev where ipython is actually installed)

# Override basic tools with modern equivalents
alias diff='colordiff' 2>/dev/null || true
alias gitlog='tig' 2>/dev/null || true
alias diskusage='ncdu' 2>/dev/null || true

# Override lt alias to use eza/exa if available
if command -v eza &> /dev/null; then
    alias lt='eza -la --tree'
elif command -v exa &> /dev/null; then
    alias lt='exa -la --tree'
fi

# Entr helper functions
if command -v entr &> /dev/null; then
    # Watch and run tests
    # Use 'command find' to bypass the find='fd' alias (fd has different syntax)
    watch-test() {
        command find . -name "*.py" -o -name "*.sh" | entr -c "$@"
    }

    # Watch and reload service
    watch-reload() {
        echo "$1" | entr -r "$@"
    }

    # Watch and run make
    # Use 'command find' to bypass the find='fd' alias (fd has different syntax)
    watch-make() {
        command find . -name "*.c" -o -name "*.h" -o -name "Makefile" | entr -c make "$@"
    }
fi

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
DEV_TOOLS_BASHRC_EOF

# ============================================================================
# Binary Tool Installations
# ============================================================================
log_message "Installing additional development tools..."

# Install duf (modern disk usage utility)
log_message "Installing duf (modern disk usage utility)..."
DUF_VERSION="${DUF_VERSION:-0.9.1}"
ARCH=$(dpkg --print-architecture)

if [ "$ARCH" = "amd64" ] || [ "$ARCH" = "arm64" ]; then
    DUF_DEB="duf_${DUF_VERSION}_linux_${ARCH}.deb"
    DUF_URL="https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/${DUF_DEB}"

    # Fetch checksum dynamically from GitHub releases
    log_message "Fetching duf checksum from GitHub..."
    DUF_CHECKSUMS_URL="https://github.com/muesli/duf/releases/download/v${DUF_VERSION}/checksums.txt"

    if ! DUF_CHECKSUM=$(fetch_github_checksums_txt "$DUF_CHECKSUMS_URL" "$DUF_DEB" 2>/dev/null); then
        log_error "Failed to fetch checksum for duf ${DUF_VERSION}"
        log_error "Please verify version exists: https://github.com/muesli/duf/releases/tag/v${DUF_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "Expected SHA256: ${DUF_CHECKSUM}"

    # Download and verify duf with checksum verification
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading and verifying duf..."
    download_and_verify \
        "$DUF_URL" \
        "$DUF_CHECKSUM" \
        "duf.deb"

    log_message "✓ duf v${DUF_VERSION} verified successfully"

    # Install the verified package
    log_command "Installing duf package" \
        dpkg -i duf.deb

    cd /
else
    log_warning "duf not available for architecture $ARCH, skipping..."
fi

# Install entr (file watcher)
log_message "Installing entr (file watcher)..."
ENTR_VERSION="${ENTR_VERSION:-5.7}"
ENTR_TARBALL="entr-${ENTR_VERSION}.tar.gz"
ENTR_URL="http://eradman.com/entrproject/code/${ENTR_TARBALL}"

# Calculate checksum for verification (eradman.com doesn't publish checksums)
log_message "Calculating checksum for entr ${ENTR_VERSION}..."
ENTR_CHECKSUM=$(calculate_checksum_sha256 "$ENTR_URL" 2>/dev/null)

if [ -z "$ENTR_CHECKSUM" ]; then
    log_error "Failed to calculate checksum for entr ${ENTR_VERSION}"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${ENTR_CHECKSUM}"

# Download and verify entr source
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading and verifying entr ${ENTR_VERSION}..."
download_and_verify \
    "$ENTR_URL" \
    "$ENTR_CHECKSUM" \
    "$ENTR_TARBALL"

log_message "✓ entr v${ENTR_VERSION} verified successfully"

log_command "Extracting entr source" \
    tar -xzf "$ENTR_TARBALL"

log_command "Building entr" \
    bash -c "cd entr-${ENTR_VERSION} && ./configure && make && make install"

cd /

# Install fzf (fuzzy finder)
log_message "Installing fzf (fuzzy finder)..."

# Function to install fzf with retries
install_fzf() {
    local max_retries=3
    local retry_delay=5
    local i

    # Clone the repository with retries
    for i in $(seq 1 $max_retries); do
        log_message "Cloning fzf repository (attempt $i/$max_retries)..."
        if log_command "Cloning fzf repository" \
            git clone --depth 1 https://github.com/junegunn/fzf.git /opt/fzf; then
            break
        fi

        if [ "$i" -lt "$max_retries" ]; then
            log_warning "Failed to clone fzf repository, retrying in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        else
            log_warning "Failed to clone fzf repository after $max_retries attempts"
            return 1
        fi
    done

    # Run the installer non-interactively with retries
    export FZF_NO_UPDATE_RC=1  # Don't modify shell rc files
    retry_delay=5
    for i in $(seq 1 $max_retries); do
        log_message "Running fzf installer (attempt $i/$max_retries)..."
        if log_command "Installing fzf" \
            bash -c "cd /opt/fzf && ./install --bin"; then
            log_message "fzf installed successfully"
            return 0
        fi

        if [ "$i" -lt "$max_retries" ]; then
            log_warning "fzf installer failed, retrying in ${retry_delay}s..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))
        fi
    done

    log_warning "Failed to install fzf after $max_retries attempts"
    return 1
}

# Install fzf with error handling
if ! install_fzf; then
    log_warning "fzf installation failed, continuing without fzf"
    log_warning "fzf will not be available in this container"
    # Don't fail the entire build due to fzf
else
    # Ensure proper ownership of fzf directory
    if [ -d /opt/fzf ]; then
        log_command "Setting fzf directory ownership" \
            chown -R "${USER_UID}:${USER_GID}" /opt/fzf
    fi
fi

# ============================================================================
# Symlink Creation
# ============================================================================
log_message "Creating tool symlinks..."

if command -v fdfind &> /dev/null && ! command -v fd &> /dev/null; then
    create_symlink "$(which fdfind)" "/usr/local/bin/fd" "fd (find alternative)"
fi

if command -v batcat &> /dev/null && ! command -v bat &> /dev/null; then
    create_symlink "$(which batcat)" "/usr/local/bin/bat" "bat (cat alternative)"
fi

# Create symlinks for fzf
if [ -f /opt/fzf/bin/fzf ]; then
    create_symlink "/opt/fzf/bin/fzf" "/usr/local/bin/fzf" "fzf fuzzy finder"
    if [ -f /opt/fzf/bin/fzf-tmux ]; then
        create_symlink "/opt/fzf/bin/fzf-tmux" "/usr/local/bin/fzf-tmux" "fzf-tmux"
    fi
fi

# Install direnv
log_message "Installing direnv..."
ARCH=$(dpkg --print-architecture)
DIRENV_VERSION="${DIRENV_VERSION:-2.37.1}"

if [ "$ARCH" = "amd64" ]; then
    DIRENV_BINARY="direnv.linux-amd64"
elif [ "$ARCH" = "arm64" ]; then
    DIRENV_BINARY="direnv.linux-arm64"
else
    log_warning "direnv not available for architecture $ARCH, skipping..."
    DIRENV_BINARY=""
fi

if [ -n "$DIRENV_BINARY" ]; then
    DIRENV_URL="https://github.com/direnv/direnv/releases/download/v${DIRENV_VERSION}/${DIRENV_BINARY}"

    # Calculate checksum from download (direnv doesn't publish checksums)
    log_message "Calculating checksum for direnv ${DIRENV_VERSION}..."
    if ! DIRENV_CHECKSUM=$(calculate_checksum_sha256 "$DIRENV_URL" 2>/dev/null); then
        log_error "Failed to download and calculate checksum for direnv ${DIRENV_VERSION}"
        log_error "Please verify version exists: https://github.com/direnv/direnv/releases/tag/v${DIRENV_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Calculated checksum from download"

    # Download and verify direnv
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading and verifying direnv for ${ARCH}..."
    download_and_verify \
        "$DIRENV_URL" \
        "${DIRENV_CHECKSUM}" \
        "direnv"

    log_command "Installing direnv binary" \
        command mv direnv /usr/local/bin/direnv

    log_command "Setting direnv permissions" \
        chmod +x /usr/local/bin/direnv

    cd /
fi

# Install lazygit with checksum verification
log_message "Installing lazygit ${LAZYGIT_VERSION}..."

# Determine lazygit filename based on architecture
case "$ARCH" in
    amd64)
        LAZYGIT_FILENAME="lazygit_${LAZYGIT_VERSION}_linux_x86_64.tar.gz"
        ;;
    arm64)
        LAZYGIT_FILENAME="lazygit_${LAZYGIT_VERSION}_linux_arm64.tar.gz"
        ;;
    *)
        log_warning "lazygit not available for architecture $ARCH, skipping..."
        LAZYGIT_FILENAME=""
        ;;
esac

if [ -n "$LAZYGIT_FILENAME" ]; then
    log_message "Fetching checksum for lazygit ${LAZYGIT_VERSION} ${ARCH}..."

    # Fetch checksum dynamically from GitHub checksums.txt file
    LAZYGIT_CHECKSUMS_URL="https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/checksums.txt"
    if ! LAZYGIT_CHECKSUM=$(fetch_github_checksums_txt "$LAZYGIT_CHECKSUMS_URL" "$LAZYGIT_FILENAME" 2>/dev/null); then
        log_error "Failed to fetch checksum for lazygit ${LAZYGIT_VERSION}"
        log_error "Please verify version exists: https://github.com/jesseduffield/lazygit/releases/tag/v${LAZYGIT_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Fetched checksum from GitHub"

    # Download and verify lazygit
    log_message "Downloading and verifying lazygit for ${ARCH}..."
    download_and_extract \
        "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/${LAZYGIT_FILENAME}" \
        "${LAZYGIT_CHECKSUM}" \
        "/usr/local/bin" \
        "lazygit"
fi

# Install delta (better git diffs) with checksum verification
log_message "Installing delta ${DELTA_VERSION}..."

# Determine delta filename and directory based on architecture
case "$ARCH" in
    amd64)
        DELTA_FILENAME="delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
        DELTA_DIR="delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu"
        ;;
    arm64)
        DELTA_FILENAME="delta-${DELTA_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
        DELTA_DIR="delta-${DELTA_VERSION}-aarch64-unknown-linux-gnu"
        ;;
    *)
        log_warning "delta not available for architecture $ARCH, skipping..."
        DELTA_FILENAME=""
        ;;
esac

if [ -n "$DELTA_FILENAME" ]; then
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"

    log_message "Calculating checksum for delta ${DELTA_VERSION} ${ARCH}..."
    log_message "(Delta doesn't publish checksums, calculating on download)"

    # Calculate checksum from download (delta project doesn't publish checksums)
    DELTA_URL="https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/${DELTA_FILENAME}"
    if ! DELTA_CHECKSUM=$(calculate_checksum_sha256 "$DELTA_URL" 2>/dev/null); then
        log_error "Failed to download and calculate checksum for delta ${DELTA_VERSION}"
        log_error "Please verify version exists: https://github.com/dandavison/delta/releases/tag/${DELTA_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Calculated checksum from download"

    # Download and verify delta
    log_message "Downloading and verifying delta for ${ARCH}..."
    download_and_verify \
        "$DELTA_URL" \
        "${DELTA_CHECKSUM}" \
        "delta-verified.tar.gz"

    log_command "Extracting delta" \
        tar -xzf delta-verified.tar.gz
    log_command "Installing delta binary" \
        command mv "${DELTA_DIR}/delta" /usr/local/bin/

    cd /
fi

# Install mkcert (local HTTPS certificates)
log_message "Installing mkcert (local HTTPS certificates)..."
MKCERT_VERSION="${MKCERT_VERSION:-1.4.4}"

if [ "$ARCH" = "amd64" ]; then
    MKCERT_BINARY="mkcert-v${MKCERT_VERSION}-linux-amd64"
elif [ "$ARCH" = "arm64" ]; then
    MKCERT_BINARY="mkcert-v${MKCERT_VERSION}-linux-arm64"
else
    log_warning "mkcert not available for architecture $ARCH, skipping..."
    MKCERT_BINARY=""
fi

if [ -n "$MKCERT_BINARY" ]; then
    MKCERT_URL="https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/${MKCERT_BINARY}"

    # Calculate checksum from download (mkcert doesn't publish checksums)
    log_message "Calculating checksum for mkcert ${MKCERT_VERSION}..."
    if ! MKCERT_CHECKSUM=$(calculate_checksum_sha256 "$MKCERT_URL" 2>/dev/null); then
        log_error "Failed to download and calculate checksum for mkcert ${MKCERT_VERSION}"
        log_error "Please verify version exists: https://github.com/FiloSottile/mkcert/releases/tag/v${MKCERT_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Calculated checksum from download"

    # Download and verify mkcert
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading and verifying mkcert for ${ARCH}..."
    download_and_verify \
        "$MKCERT_URL" \
        "${MKCERT_CHECKSUM}" \
        "mkcert"

    log_command "Installing mkcert binary" \
        command mv mkcert /usr/local/bin/mkcert

    log_command "Setting mkcert permissions" \
        chmod +x /usr/local/bin/mkcert

    cd /
fi

# Install GitHub Actions CLI (act) with checksum verification
log_message "Installing act ${ACT_VERSION}..."

# Determine act filename based on architecture
case "$ARCH" in
    amd64)
        ACT_FILENAME="act_Linux_x86_64.tar.gz"
        ;;
    arm64)
        ACT_FILENAME="act_Linux_arm64.tar.gz"
        ;;
    *)
        log_warning "act not available for architecture $ARCH, skipping..."
        ACT_FILENAME=""
        ;;
esac

if [ -n "$ACT_FILENAME" ]; then
    log_message "Fetching checksum for act ${ACT_VERSION} ${ARCH}..."

    # Fetch checksum dynamically from GitHub checksums.txt file
    ACT_CHECKSUMS_URL="https://github.com/nektos/act/releases/download/v${ACT_VERSION}/checksums.txt"
    if ! ACT_CHECKSUM=$(fetch_github_checksums_txt "$ACT_CHECKSUMS_URL" "$ACT_FILENAME" 2>/dev/null); then
        log_error "Failed to fetch checksum for act ${ACT_VERSION}"
        log_error "Please verify version exists: https://github.com/nektos/act/releases/tag/v${ACT_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Fetched checksum from GitHub"

    # Download and verify act
    log_message "Downloading and verifying act for ${ARCH}..."
    download_and_extract \
        "https://github.com/nektos/act/releases/download/v${ACT_VERSION}/${ACT_FILENAME}" \
        "${ACT_CHECKSUM}" \
        "/usr/local/bin" \
        "act"
fi

# Install git-cliff (automatic changelog generator) with SHA512 checksum verification
log_message "Installing git-cliff ${GITCLIFF_VERSION}..."

# Determine git-cliff filename based on architecture
case "$ARCH" in
    amd64) GITCLIFF_FILENAME="git-cliff-${GITCLIFF_VERSION}-x86_64-unknown-linux-gnu.tar.gz" ;;
    arm64) GITCLIFF_FILENAME="git-cliff-${GITCLIFF_VERSION}-aarch64-unknown-linux-gnu.tar.gz" ;;
    *) GITCLIFF_FILENAME="" ;;
esac

if [ -n "$GITCLIFF_FILENAME" ]; then
    log_message "Fetching checksum for git-cliff ${GITCLIFF_VERSION} ${ARCH}..."

    GITCLIFF_SHA512_URL="https://github.com/orhun/git-cliff/releases/download/v${GITCLIFF_VERSION}/${GITCLIFF_FILENAME}.sha512"
    if ! GITCLIFF_CHECKSUM=$(fetch_github_sha512_file "$GITCLIFF_SHA512_URL" 2>/dev/null); then
        log_error "Failed to fetch checksum for git-cliff ${GITCLIFF_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Fetched SHA512 checksum from GitHub"

    # Validate checksum format (should be 128 hex chars for SHA512)
    if ! validate_checksum_format "$GITCLIFF_CHECKSUM" "sha512"; then
        log_error "Invalid SHA512 checksum format for git-cliff ${GITCLIFF_VERSION}: ${GITCLIFF_CHECKSUM}"
        log_feature_end
        exit 1
    fi

    # Download and verify, then extract manually (binary is in subdirectory)
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    GITCLIFF_URL="https://github.com/orhun/git-cliff/releases/download/v${GITCLIFF_VERSION}/${GITCLIFF_FILENAME}"
    download_and_verify "$GITCLIFF_URL" "${GITCLIFF_CHECKSUM}" "git-cliff-verified.tar.gz"

    log_command "Extracting git-cliff" \
        tar -xzf git-cliff-verified.tar.gz
    log_command "Installing git-cliff binary" \
        command mv "git-cliff-${GITCLIFF_VERSION}/git-cliff" /usr/local/bin/

    cd /
    log_message "✓ git-cliff ${GITCLIFF_VERSION} installed successfully"
else
    log_warning "Unsupported architecture for git-cliff: $ARCH"
fi

# Install GitLab CLI (glab)
log_message "Installing glab (GitLab CLI)..."
GLAB_VERSION="${GLAB_VERSION:-1.79.0}"

# GitLab CLI provides builds for amd64 and arm64
if [ "$ARCH" = "amd64" ]; then
    GLAB_ARCH="amd64"
elif [ "$ARCH" = "arm64" ]; then
    GLAB_ARCH="arm64"
else
    log_warning "Unsupported architecture for glab: $ARCH"
    GLAB_ARCH=""
fi

if [ -n "$GLAB_ARCH" ]; then
    GLAB_DEB="glab_${GLAB_VERSION}_linux_${GLAB_ARCH}.deb"
    GLAB_URL="https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/${GLAB_DEB}"

    # Fetch checksum dynamically from GitLab releases
    log_message "Fetching glab checksum from GitLab..."
    GLAB_CHECKSUMS_URL="https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/checksums.txt"

    if ! GLAB_CHECKSUM=$(fetch_github_checksums_txt "$GLAB_CHECKSUMS_URL" "$GLAB_DEB" 2>/dev/null); then
        log_warning "Failed to fetch checksum for glab ${GLAB_VERSION}, skipping installation"
        log_warning "Please verify version exists: https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}"
    else
        log_message "Expected SHA256: ${GLAB_CHECKSUM}"

        # Download and verify glab with checksum verification
        BUILD_TEMP=$(create_secure_temp_dir)
        cd "$BUILD_TEMP"
        log_message "Downloading and verifying glab..."
        if download_and_verify \
            "$GLAB_URL" \
            "$GLAB_CHECKSUM" \
            "glab.deb"; then

            log_message "✓ glab v${GLAB_VERSION} verified successfully"

            # Install the verified package
            log_command "Installing glab package" \
                dpkg -i glab.deb || log_warning "Failed to install glab"
        else
            log_warning "glab verification failed, skipping installation"
        fi

        cd /
    fi
fi

# Install Biome (linting and formatting tool)
log_message "Installing Biome ${BIOME_VERSION}..."

# Determine Biome binary name based on architecture
case "$ARCH" in
    amd64)
        BIOME_BINARY="biome-linux-x64"
        ;;
    arm64)
        BIOME_BINARY="biome-linux-arm64"
        ;;
    *)
        log_warning "Biome not available for architecture $ARCH, skipping..."
        BIOME_BINARY=""
        ;;
esac

if [ -n "$BIOME_BINARY" ]; then
    BIOME_URL="https://github.com/biomejs/biome/releases/download/cli/v${BIOME_VERSION}/${BIOME_BINARY}"

    # Calculate checksum from download (Biome doesn't publish checksums)
    log_message "Calculating checksum for Biome ${BIOME_VERSION}..."
    if ! BIOME_CHECKSUM=$(calculate_checksum_sha256 "$BIOME_URL" 2>/dev/null); then
        log_error "Failed to download and calculate checksum for Biome ${BIOME_VERSION}"
        log_error "Please verify version exists: https://github.com/biomejs/biome/releases/tag/cli/v${BIOME_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "✓ Calculated checksum from download"

    # Download and verify Biome
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading and verifying Biome for ${ARCH}..."
    download_and_verify \
        "$BIOME_URL" \
        "${BIOME_CHECKSUM}" \
        "biome"

    log_command "Installing Biome binary" \
        command mv biome /usr/local/bin/biome

    log_command "Setting Biome permissions" \
        chmod +x /usr/local/bin/biome

    cd /
    log_message "✓ Biome ${BIOME_VERSION} installed successfully"
fi

# Install taplo (TOML formatter/linter) if not already installed by rust-dev
if ! command -v taplo &> /dev/null; then
    log_message "Installing taplo ${TAPLO_VERSION}..."

    # Determine taplo binary name based on architecture
    case "$ARCH" in
        amd64)
            TAPLO_BINARY="taplo-linux-x86_64.gz"
            ;;
        arm64)
            TAPLO_BINARY="taplo-linux-aarch64.gz"
            ;;
        *)
            log_warning "taplo not available for architecture $ARCH, skipping..."
            TAPLO_BINARY=""
            ;;
    esac

    if [ -n "$TAPLO_BINARY" ]; then
        TAPLO_URL="https://github.com/tamasfe/taplo/releases/download/${TAPLO_VERSION}/${TAPLO_BINARY}"

        # Calculate checksum from download (taplo doesn't publish checksums)
        log_message "Calculating checksum for taplo ${TAPLO_VERSION}..."
        if ! TAPLO_CHECKSUM=$(calculate_checksum_sha256 "$TAPLO_URL" 2>/dev/null); then
            log_error "Failed to download and calculate checksum for taplo ${TAPLO_VERSION}"
            log_error "Please verify version exists: https://github.com/tamasfe/taplo/releases/tag/${TAPLO_VERSION}"
            log_feature_end
            exit 1
        fi

        log_message "✓ Calculated checksum from download"

        # Download and verify taplo
        BUILD_TEMP=$(create_secure_temp_dir)
        cd "$BUILD_TEMP"
        log_message "Downloading and verifying taplo for ${ARCH}..."
        download_and_verify \
            "$TAPLO_URL" \
            "${TAPLO_CHECKSUM}" \
            "taplo.gz"

        log_command "Extracting taplo" \
            gunzip taplo.gz

        log_command "Installing taplo binary" \
            command mv taplo /usr/local/bin/taplo

        log_command "Setting taplo permissions" \
            chmod +x /usr/local/bin/taplo

        cd /
        log_message "✓ taplo ${TAPLO_VERSION} installed successfully"
    fi
else
    log_message "taplo already installed (likely via rust-dev), skipping..."
fi

# Install Claude Code CLI
log_message "Installing Claude Code CLI..."

# Get the target user's home directory
TARGET_USER="${USERNAME:-developer}"
if [ "$TARGET_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="/home/$TARGET_USER"
fi

# Security Note: The Claude install script (https://claude.ai/install.sh) performs
# checksum verification internally:
# 1. Downloads manifest.json with expected SHA256 checksums
# 2. Downloads the binary
# 3. Verifies downloaded binary matches expected checksum using sha256sum
# 4. Fails installation if verification fails
#
# Additionally, we verify the installer script itself before execution to ensure
# the installer hasn't been compromised at the distribution point.

# Download and verify Claude Code installer with checksum
CLAUDE_INSTALLER_URL="https://claude.ai/install.sh"
log_message "Calculating checksum for Claude Code installer..."
CLAUDE_INSTALLER_CHECKSUM=$(calculate_checksum_sha256 "$CLAUDE_INSTALLER_URL" 2>/dev/null)

if [ -z "$CLAUDE_INSTALLER_CHECKSUM" ]; then
    log_warning "Failed to calculate checksum for Claude Code installer"
    log_warning "Claude Code will not be available in this container"
else
    log_message "Expected SHA256: ${CLAUDE_INSTALLER_CHECKSUM}"

    BUILD_TEMP=$(create_secure_temp_dir)
    if download_and_verify \
        "$CLAUDE_INSTALLER_URL" \
        "$CLAUDE_INSTALLER_CHECKSUM" \
        "${BUILD_TEMP}/claude-install.sh"; then
        log_message "✓ Claude Code installer verified successfully"
    else
        log_warning "Failed to download or verify Claude Code installer"
        log_warning "Claude Code will not be available in this container"
    fi
fi

if [ -f "${BUILD_TEMP}/claude-install.sh" ]; then
    # Install Claude Code to the target user's home directory
    log_command "Installing Claude Code for user $TARGET_USER" \
        su -c "cd '$USER_HOME' && bash ${BUILD_TEMP}/claude-install.sh" "$TARGET_USER" || {
            log_warning "Claude Code installation failed"
            log_warning "Claude Code will not be available in this container"
        }

    # Create system-wide symlink if installation succeeded
    if [ -f "$USER_HOME/.local/bin/claude" ]; then
        log_command "Creating system-wide Claude symlink" \
            ln -sf "$USER_HOME/.local/bin/claude" /usr/local/bin/claude
    fi
fi

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating startup scripts..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/30-claude-code-setup.sh << 'EOF'
#!/bin/bash
# Check if Claude Code needs setup
if command -v claude &> /dev/null && [ ! -f ~/.config/claude/config.json ]; then
    echo "=== Claude Code CLI Setup ==="
    echo "Claude Code is installed but not configured."
    echo "To set up Claude Code, run: claude login"
    echo "You'll need your API key from https://console.anthropic.com"
fi
EOF
log_command "Setting Claude Code startup script permissions" \
    chmod +x /etc/container/first-startup/30-claude-code-setup.sh

# ============================================================================
# Git Configuration
# ============================================================================
log_message "Configuring git to use delta..."

command cat >> /etc/gitconfig << 'EOF'
[core]
    pager = delta
[interactive]
    diffFilter = delta --color-only
[delta]
    navigate = true
    light = false
    side-by-side = true
    line-numbers = true
    syntax-theme = Dracula
[merge]
    conflictstyle = diff3
[diff]
    colorMoved = default
EOF

# Add tool-specific configurations to bashrc.d
write_bashrc_content /etc/bashrc.d/80-dev-tools.sh "tool-specific configurations" << 'DEV_TOOLS_BASHRC_EOF'

# fzf configuration
if [ -f /opt/fzf/bin/fzf ]; then
    # Source shell integration files if they exist
    if [ -f /opt/fzf/shell/key-bindings.bash ]; then
        source /opt/fzf/shell/key-bindings.bash 2>/dev/null || true
    fi
    if [ -f /opt/fzf/shell/completion.bash ]; then
        source /opt/fzf/shell/completion.bash 2>/dev/null || true
    fi

    # Better fzf defaults
    export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --info=inline"

    # Use fd for fzf if available
    if command -v fd &> /dev/null; then
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
        export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
        export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
    fi
fi

# direnv hook
if command -v direnv &> /dev/null; then
    safe_eval "direnv hook bash" direnv hook bash
fi

# lazygit alias
if command -v lazygit &> /dev/null; then
    alias lg='lazygit'
    alias lzg='lazygit'
fi

# just aliases
if command -v just &> /dev/null; then
    alias j='just'
    # just completion with validation
    COMPLETION_FILE="/tmp/just-completion.$$.bash"
    if just --completions bash > "$COMPLETION_FILE" 2>/dev/null; then
        # Validate completion output before sourcing
        # Use 'command grep' to bypass any aliases (e.g., grep='rg')
        if [ -f "$COMPLETION_FILE" ] && \
           [ "$(wc -c < "$COMPLETION_FILE")" -lt 100000 ] && \
           ! command grep -qE '(rm -rf|curl.*bash|wget.*bash|eval.*\$)' "$COMPLETION_FILE"; then
            # shellcheck disable=SC1090  # Dynamic source is validated
            source "$COMPLETION_FILE"
        fi
    fi
    command rm -f "$COMPLETION_FILE"
fi

# mkcert helpers
if command -v mkcert &> /dev/null; then
    alias mkcert-install='mkcert -install'
    alias mkcert-uninstall='mkcert -uninstall'
fi

# Helper function for fzf git operations
if command -v fzf &> /dev/null && command -v git &> /dev/null; then
    # Git branch selector
    # Use 'command grep' to bypass aliases for reliable filtering
    fgb() {
        git branch -a | command grep -v HEAD | fzf --preview 'git log --oneline --graph --date=short --color=always --pretty="format:%C(auto)%cd %h%d %s" $(echo {} | command sed "s/.* //")' | command sed "s/.* //"
    }

    # Git checkout with fzf
    fco() {
        local branch
        branch=$(fgb)
        [ -n "$branch" ] && git checkout "$branch"
    }

    # Git log browser
    fgl() {
        git log --graph --color=always --format="%C(auto)%h%d %s %C(black)%C(bold)%cr" "$@" |
        fzf --ansi --no-sort --reverse --tiebreak=index --bind=ctrl-s:toggle-sort \
            --bind "ctrl-m:execute:
                (grep -o '[a-f0-9]\{7\}' | head -1 |
                xargs -I % sh -c 'git show --color=always % | less -R') <<< '{}'"
    }
fi

# GitHub Actions (act) aliases
if command -v act &> /dev/null; then
    alias act-list='act -l'
    alias act-dry='act -n'
    alias act-ci='act push'
    alias act-pr='act pull_request'
fi

# GitLab CLI aliases
if command -v glab &> /dev/null; then
    alias gl='glab'
    alias glmr='glab mr create'
    alias glmrs='glab mr list'
    alias glmrv='glab mr view'
    alias glis='glab issue list'
    alias gliv='glab issue view'
    alias glpipe='glab pipeline list'
    alias glci='glab ci view'
fi
DEV_TOOLS_BASHRC_EOF

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring cache directories for development tools..."

# Some tools benefit from cache directories
DEV_TOOLS_CACHE="/cache/dev-tools"

# Create cache directory using shared utility
create_cache_directories "${DEV_TOOLS_CACHE}"

# Configure tools to use cache where applicable
write_bashrc_content /etc/bashrc.d/80-dev-tools.sh "cache configuration" << 'DEV_TOOLS_BASHRC_EOF'

# Development tools cache configuration
export DEV_TOOLS_CACHE="/cache/dev-tools"

# mkcert CA root storage
export CAROOT="${DEV_TOOLS_CACHE}/mkcert-ca"

# direnv allow directory
export DIRENV_ALLOW_DIR="${DEV_TOOLS_CACHE}/direnv-allow"
DEV_TOOLS_BASHRC_EOF

# Make bashrc.d script executable to match other scripts in the directory
log_command "Setting dev-tools bashrc script permissions" \
    chmod 755 /etc/bashrc.d/80-dev-tools.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating dev tools verification script..."

command cat > /usr/local/bin/test-dev-tools << 'EOF'
#!/bin/bash
echo "=== Development Tools Status ==="
echo ""
echo "Version Control:"
for tool in git tig colordiff gh delta lazygit; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

echo ""
echo "Search Tools:"
for tool in rg fd ag ack; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

echo ""
echo "Modern CLI Tools:"
# Check for eza (preferred) or exa (fallback for older Debian)
if command -v eza &> /dev/null; then
    echo "  ✓ eza is installed"
elif command -v exa &> /dev/null; then
    echo "  ✓ exa is installed"
else
    echo "  ✗ eza/exa is not found"
fi

for tool in bat duf htop ncdu fzf; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

echo ""
echo "Development Utilities:"
for tool in direnv entr just mkcert act glab biome taplo; do
    if command -v $tool &> /dev/null; then
        echo "  ✓ $tool is installed"
    else
        echo "  ✗ $tool is not found"
    fi
done

# Claude is optional since it may fail to download
if command -v claude &> /dev/null; then
    echo "  ✓ claude is installed"
else
    echo "  ℹ claude is not installed (optional)"
fi

echo ""
echo "Cache Configuration:"
echo "  DEV_TOOLS_CACHE: ${DEV_TOOLS_CACHE:-/cache/dev-tools}"
echo "  CAROOT: ${CAROOT:-/cache/dev-tools/mkcert-ca}"
echo "  DIRENV_ALLOW_DIR: ${DIRENV_ALLOW_DIR:-/cache/dev-tools/direnv-allow}"
EOF

log_command "Setting test-dev-tools script permissions" \
    chmod +x /usr/local/bin/test-dev-tools

# Export directory paths for feature summary (also defined in bashrc for runtime)
export DEV_TOOLS_CACHE="/cache/dev-tools"
export CAROOT="${DEV_TOOLS_CACHE}/mkcert-ca"
export DIRENV_ALLOW_DIR="${DEV_TOOLS_CACHE}/direnv-allow"

# Log feature summary
log_feature_summary \
    --feature "Development Tools" \
    --tools "gh,lazygit,delta,act,git-cliff,glab,biome,taplo,duf,entr,fzf,direnv,mkcert,jq,ripgrep,fd,bat,eza/exa,htop,ncdu,claude" \
    --paths "${DEV_TOOLS_CACHE},/opt/fzf,${CAROOT}" \
    --env "DEV_TOOLS_CACHE,CAROOT,DIRENV_ALLOW_DIR" \
    --commands "gh,lazygit,delta,act,git-cliff,glab,biome,duf,entr,fzf,direnv,mkcert,jq,rg,fd,bat,eza/exa,htop,ncdu,claude" \
    --next-steps "Run 'test-dev-tools' to verify installation. Many modern CLI replacements are aliased (ls=eza, cat=bat, grep=rg, find=fd)."

# End logging
log_feature_end

echo ""
echo "Run 'test-dev-tools' to verify installation"
echo "Run 'check-build-logs.sh development-tools' to review installation logs"
