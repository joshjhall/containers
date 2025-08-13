#!/bin/bash
# Base system setup - common to all contexts
#
# Description:
#   Installs essential system packages and configures the base environment
#   This script runs before user creation and feature installation
#
# Features:
#   - Essential build tools and utilities
#   - Shell script validation (shellcheck) and JSON processing (jq)
#   - Locale and timezone configuration
#   - Zoxide for smarter directory navigation
#   - Base aliases and shell improvements
#
set -euo pipefail

# ============================================================================
# System Updates
# ============================================================================
echo "=== Updating base system packages for security ==="

# Update package lists and upgrade existing packages
apt-get update
apt-get upgrade -y

# ============================================================================
# Package Installation
# ============================================================================
echo "=== Installing essential system packages ==="

# Install essential system packages
apt-get install -y --no-install-recommends \
    build-essential \
    make \
    sudo \
    ca-certificates \
    git \
    openssh-client \
    tig \
    colordiff \
    curl \
    wget \
    gnupg \
    locales \
    lsb-release \
    pkg-config \
    libssl-dev \
    libffi-dev \
    jq \
    shellcheck \
    unzip \
    vim-tiny \
    less \
    procps \
    htop \
    tzdata \
    coreutils

# ============================================================================
# Locale Configuration
# ============================================================================
echo "=== Configuring locale ==="
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 || true

# ============================================================================
# Timezone Configuration
# ============================================================================
echo "=== Configuring timezone ==="
# TZ environment variable can override this at runtime
TZ=${TZ:-UTC}
ln -snf /usr/share/zoneinfo/$TZ /etc/localtime
echo $TZ > /etc/timezone

# ============================================================================
# Zoxide Installation - Smarter directory navigation
# ============================================================================
echo "=== Installing zoxide ==="
ARCH=$(dpkg --print-architecture)
ZOXIDE_VERSION="0.9.8"
cd /tmp
if [ "$ARCH" = "amd64" ]; then
    curl -L https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-x86_64-unknown-linux-musl.tar.gz | tar xz
elif [ "$ARCH" = "arm64" ]; then
    curl -L https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-aarch64-unknown-linux-musl.tar.gz | tar xz
fi
mv zoxide /usr/local/bin/
chmod +x /usr/local/bin/zoxide
cd /

# Note: Python packages are installed via system packages to comply with PEP 668
# pipx will be used for installing Python applications in isolated environments

# ============================================================================
# Shell Configuration
# ============================================================================
echo "=== Setting up base aliases ==="
/tmp/build-scripts/base/aliases.sh

# ============================================================================
# Cleanup
# ============================================================================
echo "=== Cleaning up ==="
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "=== Base system setup complete ==="