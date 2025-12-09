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

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# ============================================================================
# System Updates
# ============================================================================
echo "=== Updating base system packages for security ==="

# Update package lists and upgrade existing packages
apt_update
# Note: apt_install doesn't handle upgrades, so we use apt-get with retry logic
apt_retry apt-get upgrade -y

# ============================================================================
# Package Installation
# ============================================================================
echo "=== Installing essential system packages ==="

# Install essential system packages
# Note: build-essential, pkg-config, libssl-dev, libffi-dev removed from base
# Language features (python, ruby, r) install these as needed and clean up in production
apt_install \
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
    jq \
    shellcheck \
    unzip \
    vim-tiny \
    less \
    procps \
    htop \
    tzdata \
    coreutils \
    tini

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
ln -snf /usr/share/zoneinfo/"$TZ" /etc/localtime
echo "$TZ" > /etc/timezone

# ============================================================================
# Zoxide Installation - Smarter directory navigation
# ============================================================================
echo "=== Installing zoxide ==="
ARCH=$(dpkg --print-architecture)
ZOXIDE_VERSION="${ZOXIDE_VERSION:-0.9.8}"
cd /tmp
if [ "$ARCH" = "amd64" ]; then
    command curl -L "https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar xz
elif [ "$ARCH" = "arm64" ]; then
    command curl -L "https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-aarch64-unknown-linux-musl.tar.gz" | tar xz
fi
command mv zoxide /usr/local/bin/
chmod +x /usr/local/bin/zoxide
cd /

# ============================================================================
# Cosign Installation - Sigstore signature verification
# ============================================================================
echo "=== Installing cosign ==="
COSIGN_VERSION="${COSIGN_VERSION:-3.0.2}"
cd /tmp
if [ "$ARCH" = "amd64" ]; then
    command curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64" -o cosign
elif [ "$ARCH" = "arm64" ]; then
    command curl -fsSL "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-arm64" -o cosign
fi
command mv cosign /usr/local/bin/
chmod +x /usr/local/bin/cosign
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
apt_cleanup

echo "=== Base system setup complete ==="
