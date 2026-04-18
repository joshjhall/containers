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
# Source download verification for checksum-verified downloads
source /tmp/build-scripts/base/download-verify.sh

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
echo "en_US.UTF-8 UTF-8" >>/etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 || true

# ============================================================================
# Timezone Configuration
# ============================================================================
echo "=== Configuring timezone ==="
# TZ environment variable can override this at runtime
TZ=${TZ:-UTC}
ln -snf /usr/share/zoneinfo/"$TZ" /etc/localtime
echo "$TZ" >/etc/timezone

# ============================================================================
# Zoxide Installation - Smarter directory navigation
# ============================================================================
echo "=== Installing zoxide ==="
ARCH=$(dpkg --print-architecture)
ZOXIDE_VERSION="0.9.9"
# Tier 2 pinned SHA256 checksums from official release tarballs
ZOXIDE_SHA256_AMD64="4ff057d3c4d957946937274c2b8be7af2a9bbae7f90a1b5e9baaa7cb65a20caa"
ZOXIDE_SHA256_ARM64="96e6ea2e47a71db42cb7ad5a36e9209c8cb3708f8ae00f6945573d0d93315cb0"
if [ "$ARCH" = "amd64" ]; then
    ZOXIDE_URL="https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-x86_64-unknown-linux-musl.tar.gz"
    ZOXIDE_SHA256="$ZOXIDE_SHA256_AMD64"
elif [ "$ARCH" = "arm64" ]; then
    ZOXIDE_URL="https://github.com/ajeetdsouza/zoxide/releases/download/v${ZOXIDE_VERSION}/zoxide-${ZOXIDE_VERSION}-aarch64-unknown-linux-musl.tar.gz"
    ZOXIDE_SHA256="$ZOXIDE_SHA256_ARM64"
fi
download_and_extract "$ZOXIDE_URL" "$ZOXIDE_SHA256" "/tmp" "zoxide"
command mv /tmp/zoxide /usr/local/bin/
chmod +x /usr/local/bin/zoxide

# ============================================================================
# Cosign Installation - Sigstore signature verification
# ============================================================================
echo "=== Installing cosign ==="
COSIGN_VERSION="${COSIGN_VERSION:-3.0.6}"
# Tier 2 pinned SHA256 checksums from official cosign_checksums.txt
COSIGN_SHA256_AMD64="c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74"
COSIGN_SHA256_ARM64="bedac92e8c3729864e13d4a17048007cfafa79d5deca993a43a90ffe018ef2b8"
if [ "$ARCH" = "amd64" ]; then
    COSIGN_URL="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-amd64"
    COSIGN_SHA256="$COSIGN_SHA256_AMD64"
elif [ "$ARCH" = "arm64" ]; then
    COSIGN_URL="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-arm64"
    COSIGN_SHA256="$COSIGN_SHA256_ARM64"
fi
download_and_verify "$COSIGN_URL" "$COSIGN_SHA256" "/tmp/cosign"
command mv /tmp/cosign /usr/local/bin/
chmod +x /usr/local/bin/cosign

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
