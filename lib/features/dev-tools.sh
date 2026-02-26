#!/bin/bash
# Development Tools - Modern CLI utilities and productivity enhancers
#
# Description:
#   Installs a comprehensive set of development tools for enhanced productivity.
#   Includes modern CLI replacements, git helpers, monitoring tools, and more.
#
# Features:
#   - Modern CLI replacements: eza/exa (ls), bat (cat), duf (df), fd (find), ripgrep (grep)
#   - Git helpers: lazygit, delta (side-by-side diffs), git-cliff, tig, colordiff
#   - Development utilities: direnv, entr, fzf (fuzzy finder), inotify-tools
#   - Network tools: netcat-openbsd, dnsutils, iputils-ping, traceroute
#   - System monitoring: htop, iotop, sysstat, strace, lsof, ncdu
#   - Security tools: mkcert (local HTTPS certificates)
#   - Archive tools: zip, unzip
#   - GitHub/GitLab CLIs: gh, act (local GitHub Actions), glab
#   - Text processing: jq, xxd
#   - Search tools: silversearcher-ag, ack, tree, rsync
#   - Build tools: build-essential, pkg-config, libssl-dev, libffi-dev
#   - Terminal tools: tmux, xclip
#   - Text editors: nano, vim
#   - Process management: supervisor
#   - Linting/Formatting: biome (fast linter/formatter for JS/TS/JSON/CSS)
#   - TOML tools: taplo (TOML formatter and linter)
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
ENTR_VERSION="${ENTR_VERSION:-5.7}"
MKCERT_VERSION="${MKCERT_VERSION:-1.4.4}"
GLAB_VERSION="${GLAB_VERSION:-1.86.0}"
LAZYGIT_VERSION="${LAZYGIT_VERSION:-0.59.0}"
DELTA_VERSION="${DELTA_VERSION:-0.18.2}"
ACT_VERSION="${ACT_VERSION:-0.2.84}"
GITCLIFF_VERSION="${GITCLIFF_VERSION:-2.8.0}"
BIOME_VERSION="${BIOME_VERSION:-2.4.4}"
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
    zip \
    unzip

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
    jq \
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


# Override with modern tool aliases when available
# Prefer eza (maintained) over exa (deprecated but still in older Debian)
if command -v eza &> /dev/null; then
    alias ls='eza'
    alias ll='eza -l'
    alias la='eza -la'
    alias l='eza -F'
    alias tree='eza --tree'
elif command -v exa &> /dev/null; then
    alias ls='exa'
    alias ll='exa -l'
    alias la='exa -la'
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


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
DEV_TOOLS_BASHRC_EOF

# ============================================================================
# Binary Tool Installations
# ============================================================================
log_message "Installing additional development tools..."

# duf (modern disk usage utility)
install_github_release "duf" "$DUF_VERSION" \
    "https://github.com/muesli/duf/releases/download/v${DUF_VERSION}" \
    "duf_${DUF_VERSION}_linux_amd64.deb" "duf_${DUF_VERSION}_linux_arm64.deb" \
    "checksums_txt" "dpkg" \
    || { log_feature_end; exit 1; }

# Install entr (file watcher) — source build, not a GitHub release binary
log_message "Installing entr (file watcher)..."
ENTR_TARBALL="entr-${ENTR_VERSION}.tar.gz"
ENTR_URL="http://eradman.com/entrproject/code/${ENTR_TARBALL}"

log_message "Calculating checksum for entr ${ENTR_VERSION}..."
ENTR_CHECKSUM=$(calculate_checksum_sha256 "$ENTR_URL" 2>/dev/null)

if [ -z "$ENTR_CHECKSUM" ]; then
    log_error "Failed to calculate checksum for entr ${ENTR_VERSION}"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${ENTR_CHECKSUM}"

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

# Install fzf (fuzzy finder) — git clone with custom retry logic
log_message "Installing fzf (fuzzy finder)..."

install_fzf() {
    local max_retries=3
    local retry_delay=5
    local i

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

    export FZF_NO_UPDATE_RC=1
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

if ! install_fzf; then
    log_warning "fzf installation failed, continuing without fzf"
    log_warning "fzf will not be available in this container"
else
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

if [ -f /opt/fzf/bin/fzf ]; then
    create_symlink "/opt/fzf/bin/fzf" "/usr/local/bin/fzf" "fzf fuzzy finder"
    if [ -f /opt/fzf/bin/fzf-tmux ]; then
        create_symlink "/opt/fzf/bin/fzf-tmux" "/usr/local/bin/fzf-tmux" "fzf-tmux"
    fi
fi

# direnv (direct binary, no published checksums)
install_github_release "direnv" "$DIRENV_VERSION" \
    "https://github.com/direnv/direnv/releases/download/v${DIRENV_VERSION}" \
    "direnv.linux-amd64" "direnv.linux-arm64" \
    "calculate" "binary" \
    || { log_feature_end; exit 1; }

# lazygit (tar with binary at top level)
install_github_release "lazygit" "$LAZYGIT_VERSION" \
    "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}" \
    "lazygit_${LAZYGIT_VERSION}_linux_x86_64.tar.gz" \
    "lazygit_${LAZYGIT_VERSION}_linux_arm64.tar.gz" \
    "checksums_txt" "extract_flat:lazygit" \
    || { log_feature_end; exit 1; }

# delta (better git diffs — tar with binary in subdirectory, no published checksums)
install_github_release "delta" "$DELTA_VERSION" \
    "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}" \
    "delta-${DELTA_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    "delta-${DELTA_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
    "calculate" "extract:delta" \
    || { log_feature_end; exit 1; }

# mkcert (local HTTPS certificates, no published checksums)
install_github_release "mkcert" "$MKCERT_VERSION" \
    "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}" \
    "mkcert-v${MKCERT_VERSION}-linux-amd64" "mkcert-v${MKCERT_VERSION}-linux-arm64" \
    "calculate" "binary" \
    || { log_feature_end; exit 1; }

# act (GitHub Actions CLI)
install_github_release "act" "$ACT_VERSION" \
    "https://github.com/nektos/act/releases/download/v${ACT_VERSION}" \
    "act_Linux_x86_64.tar.gz" "act_Linux_arm64.tar.gz" \
    "checksums_txt" "extract_flat:act" \
    || { log_feature_end; exit 1; }

# git-cliff (automatic changelog generator, SHA512 checksums)
install_github_release "git-cliff" "$GITCLIFF_VERSION" \
    "https://github.com/orhun/git-cliff/releases/download/v${GITCLIFF_VERSION}" \
    "git-cliff-${GITCLIFF_VERSION}-x86_64-unknown-linux-gnu.tar.gz" \
    "git-cliff-${GITCLIFF_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
    "sha512" "extract:git-cliff" \
    || { log_feature_end; exit 1; }

# glab (GitLab CLI — non-fatal, uses GitLab release URLs)
install_github_release "glab" "$GLAB_VERSION" \
    "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads" \
    "glab_${GLAB_VERSION}_linux_amd64.deb" "glab_${GLAB_VERSION}_linux_arm64.deb" \
    "checksums_txt" "dpkg" \
    || log_warning "glab installation failed, continuing without glab"

# biome (linting and formatting — non-standard tag format, no published checksums)
install_github_release "biome" "$BIOME_VERSION" \
    "https://github.com/biomejs/biome/releases/download/@biomejs/biome@${BIOME_VERSION}" \
    "biome-linux-x64" "biome-linux-arm64" \
    "calculate" "binary" \
    || { log_feature_end; exit 1; }

# taplo (TOML formatter/linter) — skip if already installed by rust-dev
if ! command -v taplo &> /dev/null; then
    install_github_release "taplo" "$TAPLO_VERSION" \
        "https://github.com/tamasfe/taplo/releases/download/${TAPLO_VERSION}" \
        "taplo-linux-x86_64.gz" "taplo-linux-aarch64.gz" \
        "calculate" "gunzip" \
        || { log_feature_end; exit 1; }
else
    log_message "taplo already installed (likely via rust-dev), skipping..."
fi

# ============================================================================
# Build-Time Configuration for Runtime
# ============================================================================
# Pass build-time feature flags to runtime startup scripts via config file
log_message "Writing build configuration for runtime..."

log_command "Creating container config directory" \
    mkdir -p /etc/container/config

cat > /etc/container/config/enabled-features.conf << FEATURES_EOF
# Auto-generated at build time - DO NOT EDIT
# This file passes build-time feature flags to runtime startup scripts
INCLUDE_PYTHON_DEV=${INCLUDE_PYTHON_DEV:-false}
INCLUDE_NODE_DEV=${INCLUDE_NODE_DEV:-false}
INCLUDE_RUST_DEV=${INCLUDE_RUST_DEV:-false}
INCLUDE_RUBY_DEV=${INCLUDE_RUBY_DEV:-false}
INCLUDE_GOLANG_DEV=${INCLUDE_GOLANG_DEV:-false}
INCLUDE_JAVA_DEV=${INCLUDE_JAVA_DEV:-false}
INCLUDE_KOTLIN_DEV=${INCLUDE_KOTLIN_DEV:-false}
INCLUDE_ANDROID_DEV=${INCLUDE_ANDROID_DEV:-false}

# Extra plugins to install (comma-separated)
# Can be overridden at runtime via environment variable
CLAUDE_EXTRA_PLUGINS_DEFAULT="${CLAUDE_EXTRA_PLUGINS:-}"

# Extra MCP servers to install (comma-separated)
# Can be overridden at runtime via environment variable
CLAUDE_EXTRA_MCPS_DEFAULT="${CLAUDE_EXTRA_MCPS:-}"

# Support tool flags (for conditional skills/agents)
INCLUDE_DOCKER=${INCLUDE_DOCKER:-false}
INCLUDE_KUBERNETES=${INCLUDE_KUBERNETES:-false}
INCLUDE_TERRAFORM=${INCLUDE_TERRAFORM:-false}
INCLUDE_AWS=${INCLUDE_AWS:-false}
INCLUDE_GCLOUD=${INCLUDE_GCLOUD:-false}
INCLUDE_CLOUDFLARE=${INCLUDE_CLOUDFLARE:-false}
FEATURES_EOF

log_command "Setting config file permissions" \
    chmod 644 /etc/container/config/enabled-features.conf

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

# Claude Code LSP support
# Enables Language Server Protocol integration for better code intelligence
# LSP plugins are configured automatically on first container startup
export ENABLE_LSP_TOOL=1
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
    --tools "gh,lazygit,delta,act,git-cliff,glab,biome,taplo,duf,entr,fzf,direnv,mkcert,jq,ripgrep,fd,bat,eza/exa,htop,ncdu" \
    --paths "${DEV_TOOLS_CACHE},/opt/fzf,${CAROOT}" \
    --env "DEV_TOOLS_CACHE,CAROOT,DIRENV_ALLOW_DIR,ENABLE_LSP_TOOL" \
    --commands "gh,lazygit,delta,act,git-cliff,glab,biome,duf,entr,fzf,direnv,mkcert,jq,rg,fd,bat,eza/exa,htop,ncdu" \
    --next-steps "Run 'test-dev-tools' to verify installation. Many modern CLI replacements are aliased (ls=eza, cat=bat, grep=rg, find=fd). Claude Code is installed separately by claude-code-setup.sh."

# End logging
log_feature_end

echo ""
echo "Run 'test-dev-tools' to verify installation"
echo "Run 'check-build-logs.sh development-tools' to review installation logs"
