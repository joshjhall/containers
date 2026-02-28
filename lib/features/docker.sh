#!/bin/bash
# Docker CLI Tools - Container management without daemon installation
#
# Description:
#   Installs Docker CLI tools for container management in development environments.
#   This installation includes only client tools - the Docker daemon must be
#   available via socket mount or DOCKER_HOST.
#
# ⚠️  SECURITY WARNING: Docker Socket Access
# ============================================================================
#   Mounting the Docker socket provides ROOT-EQUIVALENT access to the host:
#
#   RISKS:
#     - Container escape: Can break out of container isolation
#     - Host filesystem access: Can mount any host directory
#     - Privilege escalation: Can start privileged containers
#     - Process manipulation: Can kill or inspect any container
#
#   ONLY USE IN TRUSTED DEVELOPMENT ENVIRONMENTS
#
#   ✅ APPROPRIATE FOR:
#     - Local development workstations
#     - Managing dependency containers (databases, Redis, etc.)
#     - Testing Docker-based applications
#     - CI/CD with isolated runners
#
#   ❌ NEVER USE FOR:
#     - Production deployments
#     - Multi-tenant environments
#     - Untrusted code execution
#     - Shared development servers
#
#   SAFER ALTERNATIVES FOR PRODUCTION:
#     - Sysbox: Rootless container runtime with Docker-in-Docker
#     - Podman: Daemonless container engine (no socket required)
#     - Kaniko: Build container images without Docker daemon
#     - BuildKit: Rootless mode for secure image builds
# ============================================================================
#
# Features:
#   - Docker CLI: Complete container management interface
#   - Docker Compose V2: Multi-container application orchestration
#   - Docker Buildx: Advanced build capabilities with BuildKit
#   - lazydocker: Terminal UI for Docker management
#   - dive: Docker image layer analysis tool
#   - cosign: Container image signing and verification (Sigstore)
#   - Helper functions for common operations
#   - Automatic user group configuration
#
# Tools Installed:
#   - docker-ce-cli: Latest Docker CLI from official repository
#   - docker-compose-plugin: Docker Compose V2 as plugin
#   - docker-buildx-plugin: Docker Buildx for advanced builds
#   - lazydocker: Terminal UI for Docker management
#   - dive: Docker image layer analysis tool
#   - cosign: Sigstore container image signing and verification
#
# Requirements:
#   - Docker socket: Mount with -v /var/run/docker.sock:/var/run/docker.sock
#   - Or DOCKER_HOST: Set to remote Docker daemon endpoint
#
# Common Commands:
#   - docker ps: List running containers
#   - docker compose up: Start services defined in compose file
#   - lazydocker: Launch terminal UI
#   - dive <image>: Analyze image layers
#
# Note:
#   User is automatically added to docker group for socket access.
#   Socket permissions may require container restart to take effect.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source checksum utilities for secure binary downloads
source /tmp/build-scripts/base/checksum-fetch.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh

# Source 4-tier checksum verification system
source /tmp/build-scripts/base/checksum-verification.sh
source /tmp/build-scripts/base/cache-utils.sh

# Start logging
log_feature_start "Docker CLI Tools"

# ============================================================================
# Repository Configuration
# ============================================================================
log_message "Configuring Docker repository..."

# Prepare directory for Docker GPG key
log_command "Creating keyrings directory" \
    install -m 0755 -d /etc/apt/keyrings

log_message "Adding Docker GPG key"
retry_with_backoff curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Docker GPG key fingerprint
# Source: https://docs.docker.com/engine/install/debian/#install-using-the-repository
DOCKER_GPG_FINGERPRINT="9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"

log_message "Verifying Docker GPG key fingerprint..."
IMPORTED_FINGERPRINT=$(gpg --no-default-keyring \
    --keyring /etc/apt/keyrings/docker.gpg \
    --list-keys --with-colons 2>/dev/null \
    | command grep '^fpr:' | command head -1 | command cut -d: -f10)
EXPECTED_FINGERPRINT=$(echo "${DOCKER_GPG_FINGERPRINT}" | command tr -d ' ')

if [ "$IMPORTED_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]; then
    log_error "Docker GPG key fingerprint mismatch!"
    log_error "Expected: ${EXPECTED_FINGERPRINT}"
    log_error "Got:      ${IMPORTED_FINGERPRINT}"
    command rm -f /etc/apt/keyrings/docker.gpg
    exit 1
fi

log_message "✓ Docker GPG key fingerprint verified"

log_command "Setting Docker GPG key permissions" \
    chmod a+r /etc/apt/keyrings/docker.gpg

# ============================================================================
# Docker CLI Installation
# ============================================================================
log_message "Installing Docker CLI tools..."

# Add Docker repository for latest CLI version
# Note: We can't use log_command here because it would include log output in the file
log_message "Adding Docker repository..."
if echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
command tee /etc/apt/sources.list.d/docker.list > /dev/null; then
    log_message "✓ Docker repository added successfully"
else
    log_error "Failed to add Docker repository"
    exit 1
fi

# Update and install Docker CLI only
log_message "Installing Docker CLI, Compose, and Buildx plugins..."

# Update package lists with retry logic
apt_update

# Install Docker CLI, Compose, and Buildx plugins with retry logic
apt_install docker-ce-cli docker-compose-plugin docker-buildx-plugin

# ============================================================================
# User Configuration
# ============================================================================
log_message "Configuring user access to Docker..."

# Add user to docker group for socket access
log_command "Creating docker group" \
    groupadd docker || true

log_command "Adding user to docker group" \
    usermod -aG docker "${USERNAME}"

# Fix Docker socket permissions if it exists
if [ -S /var/run/docker.sock ]; then
    log_message "Docker socket detected, configuring permissions..."
    log_command "Setting Docker socket group ownership" \
        chgrp docker /var/run/docker.sock || true
    log_command "Setting Docker socket permissions" \
        chmod g+rw /var/run/docker.sock || true
fi

# ============================================================================
# Lazydocker Installation
# ============================================================================
log_message "Installing lazydocker (terminal UI for Docker)..."

# Detect architecture for lazydocker
LAZYDOCKER_ARCH=$(map_arch "x86_64" "arm64")

# Version is configurable via environment variable
LAZYDOCKER_VERSION="${LAZYDOCKER_VERSION:-0.24.4}"
LAZYDOCKER_ARCHIVE="lazydocker_${LAZYDOCKER_VERSION}_Linux_${LAZYDOCKER_ARCH}.tar.gz"
LAZYDOCKER_URL="https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/${LAZYDOCKER_ARCHIVE}"

log_message "Installing lazydocker v${LAZYDOCKER_VERSION} for ${LAZYDOCKER_ARCH}..."

# Register Tier 3 fetcher for lazydocker
_fetch_lazydocker_checksum() {
    local _ver="$1"
    local _arch="$2"
    local _lz_arch
    case "$_arch" in
        amd64) _lz_arch="x86_64" ;;
        arm64) _lz_arch="arm64" ;;
        *) _lz_arch="$_arch" ;;
    esac
    local _archive="lazydocker_${_ver}_Linux_${_lz_arch}.tar.gz"
    local _url="https://github.com/jesseduffield/lazydocker/releases/download/v${_ver}/checksums.txt"
    fetch_github_checksums_txt "$_url" "$_archive" 2>/dev/null
}
register_tool_checksum_fetcher "lazydocker" "_fetch_lazydocker_checksum"

# Download lazydocker
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading lazydocker..."
if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "lazydocker.tar.gz" "$LAZYDOCKER_URL"; then
    log_error "Failed to download lazydocker ${LAZYDOCKER_VERSION}"
    cd /
    log_feature_end
    exit 1
fi

# Run 4-tier verification
verify_rc=0
verify_download "tool" "lazydocker" "$LAZYDOCKER_VERSION" "lazydocker.tar.gz" "$(dpkg --print-architecture)" || verify_rc=$?
if [ "$verify_rc" -eq 1 ]; then
    log_error "Verification failed for lazydocker ${LAZYDOCKER_VERSION}"
    cd /
    log_feature_end
    exit 1
fi

# Extract and install
log_command "Extracting lazydocker" \
    tar -xzf lazydocker.tar.gz

log_command "Installing lazydocker binary" \
    command mv ./lazydocker /usr/local/bin/

log_command "Setting lazydocker permissions" \
    chmod +x /usr/local/bin/lazydocker

log_message "✓ lazydocker v${LAZYDOCKER_VERSION} installed successfully"

cd /
log_command "Cleaning up build directory" \
    command rm -rf "$BUILD_TEMP"

# ============================================================================
# Dive Installation
# ============================================================================
log_message "Installing dive (Docker image layer analysis tool)..."

# Set dive version (configurable via environment variable)
DIVE_VERSION="${DIVE_VERSION:-0.13.1}"

# Detect architecture for dive
DIVE_ARCH=$(map_arch "amd64" "arm64")

# Construct the dive package filename
DIVE_PACKAGE="dive_${DIVE_VERSION}_linux_${DIVE_ARCH}.deb"
DIVE_URL="https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/${DIVE_PACKAGE}"

# Register Tier 3 fetcher for dive
_fetch_dive_checksum() {
    local _ver="$1"
    local _arch="$2"
    local _pkg="dive_${_ver}_linux_${_arch}.deb"
    local _url="https://github.com/wagoodman/dive/releases/download/v${_ver}/dive_${_ver}_checksums.txt"
    fetch_github_checksums_txt "$_url" "$_pkg" 2>/dev/null
}
register_tool_checksum_fetcher "dive" "_fetch_dive_checksum"

# Download dive
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading dive..."
if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "dive.deb" "$DIVE_URL"; then
    log_error "Failed to download dive ${DIVE_VERSION}"
    cd /
    log_feature_end
    exit 1
fi

# Run 4-tier verification
verify_rc=0
verify_download "tool" "dive" "$DIVE_VERSION" "dive.deb" "$(dpkg --print-architecture)" || verify_rc=$?
if [ "$verify_rc" -eq 1 ]; then
    log_error "Verification failed for dive ${DIVE_VERSION}"
    cd /
    log_feature_end
    exit 1
fi

log_message "✓ dive v${DIVE_VERSION} verified successfully"

# Install the verified package
log_command "Installing dive package" \
    dpkg -i dive.deb

cd /
log_command "Cleaning up build directory" \
    command rm -rf "$BUILD_TEMP"

# ============================================================================
# Cosign Installation (Container Image Signing)
# ============================================================================
if ! command -v cosign &> /dev/null; then
    log_message "Installing cosign (container image signing and verification)..."

    # Set cosign version
    COSIGN_VERSION="3.0.2"

    # Detect architecture for cosign
    COSIGN_ARCH=$(map_arch "amd64" "arm64")

    # Construct the cosign package filename
    COSIGN_PACKAGE="cosign_${COSIGN_VERSION}_${COSIGN_ARCH}.deb"
    COSIGN_URL="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/${COSIGN_PACKAGE}"

    # Register Tier 3 fetcher for cosign
    _fetch_cosign_checksum() {
        local _ver="$1"
        local _arch="$2"
        local _pkg="cosign_${_ver}_${_arch}.deb"
        local _url="https://github.com/sigstore/cosign/releases/download/v${_ver}/cosign_checksums.txt"
        fetch_github_checksums_txt "$_url" "$_pkg" 2>/dev/null
    }
    register_tool_checksum_fetcher "cosign" "_fetch_cosign_checksum"

    # Download cosign
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading cosign..."
    if ! command curl -L -f --retry 3 --retry-delay 2 --retry-all-errors --progress-bar -o "cosign.deb" "$COSIGN_URL"; then
        log_error "Failed to download cosign ${COSIGN_VERSION}"
        cd /
        log_feature_end
        exit 1
    fi

    # Run 4-tier verification
    verify_rc=0
    verify_download "tool" "cosign" "$COSIGN_VERSION" "cosign.deb" "$(dpkg --print-architecture)" || verify_rc=$?
    if [ "$verify_rc" -eq 1 ]; then
        log_error "Verification failed for cosign ${COSIGN_VERSION}"
        cd /
        log_feature_end
        exit 1
    fi

    log_message "✓ cosign v${COSIGN_VERSION} verified successfully"

    # Install the verified package
    log_command "Installing cosign package" \
        dpkg -i cosign.deb

    cd /
    log_command "Cleaning up build directory" \
        command rm -rf "$BUILD_TEMP"
else
    log_message "cosign already installed, skipping..."
fi

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring Docker cache directories..."

# Docker uses several cache directories that we can optimize
DOCKER_CACHE_DIR="/cache/docker"
DOCKER_CLI_PLUGINS_DIR="${DOCKER_CACHE_DIR}/cli-plugins"

# Create cache directories using shared utility
create_cache_directories "${DOCKER_CACHE_DIR}" "${DOCKER_CLI_PLUGINS_DIR}"

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Docker environment and aliases..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Docker configuration (content in lib/bashrc/docker.sh)
write_bashrc_content /etc/bashrc.d/50-docker.sh "Docker configuration" \
    < /tmp/build-scripts/features/lib/bashrc/docker.sh

log_command "Setting Docker bashrc script permissions" \
    chmod +x /etc/bashrc.d/50-docker.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Docker startup scripts..."

# Create startup directories if they don't exist
log_command "Creating container startup directories" \
    mkdir -p /etc/container/first-startup /etc/container/startup

# First-time startup script - runs once
command cat > /etc/container/first-startup/20-docker-setup.sh << 'DOCKER_STARTUP_EOF'
#!/bin/bash
# Check if Docker socket is mounted
if [ -S /var/run/docker.sock ]; then
    echo "=== Docker Configuration ==="
    echo "Docker socket is mounted - Docker commands will work"
    docker version --format '{{.Server.Version}}' 2>/dev/null && echo "Connected to Docker daemon"
else
    echo "=== Docker Configuration ==="
    echo "Docker CLI is installed but no Docker socket is mounted"
    echo "To use Docker, mount the socket: -v /var/run/docker.sock:/var/run/docker.sock"
fi

# Check for docker-compose files
if [ -f ${WORKING_DIR}/docker-compose.yml ] || [ -f ${WORKING_DIR}/docker-compose.yaml ]; then
    echo "Docker Compose file detected in workspace"
fi
DOCKER_STARTUP_EOF
log_command "Setting Docker first-startup script permissions" \
    chmod +x /etc/container/first-startup/20-docker-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Docker verification script..."

command cat > /usr/local/bin/test-docker << 'DOCKER_TEST_EOF'
#!/bin/bash
echo "=== Docker CLI Status ==="

if command -v docker &> /dev/null; then
    echo "✓ Docker CLI is installed"
    echo "  Version: $(docker --version)"
    echo "  Binary: $(which docker)"
else
    echo "✗ Docker CLI is not installed"
    exit 1
fi

echo ""
echo "=== Docker Compose Status ==="
if docker compose version &> /dev/null 2>&1; then
    echo "✓ Docker Compose V2 is installed"
    docker compose version
else
    echo "✗ Docker Compose is not installed"
fi

echo ""
echo "=== Docker Tools ==="
for tool in lazydocker dive cosign; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed at $(which $tool)"
    else
        echo "✗ $tool is not found"
    fi
done

echo ""
echo "=== Docker Socket Status ==="
if [ -S /var/run/docker.sock ]; then
    echo "✓ Docker socket is mounted"
    if docker version &> /dev/null 2>&1; then
        echo "✓ Connected to Docker daemon"
        echo "  Server version: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    else
        echo "✗ Cannot connect to Docker daemon"
        echo "  Check socket permissions or run as root/docker group member"
    fi
else
    echo "✗ Docker socket is not mounted"
    echo "  Mount with: -v /var/run/docker.sock:/var/run/docker.sock"
fi

echo ""
echo "=== Cache Configuration ==="
echo "  DOCKER_CONFIG: ${DOCKER_CONFIG:-/cache/docker}"
echo "  DOCKER_CLI_PLUGINS_PATH: ${DOCKER_CLI_PLUGINS_PATH:-/cache/docker/cli-plugins}"

if [ -d "${DOCKER_CONFIG:-/cache/docker}" ]; then
    echo "  ✓ Docker cache directory exists"
else
    echo "  ✗ Docker cache directory missing"
fi

echo ""
echo "=== User Configuration ==="
if groups ${USER} | grep -q docker; then
    echo "✓ User '${USER}' is in docker group"
else
    echo "✗ User '${USER}' is not in docker group"
    echo "  Run: usermod -aG docker ${USER}"
fi
DOCKER_TEST_EOF

log_command "Setting test-docker script permissions" \
    chmod +x /usr/local/bin/test-docker

# ============================================================================
# Feature Summary
# ============================================================================

# Set variables for feature summary (these are also set in bashrc for runtime)
export DOCKER_CONFIG="${DOCKER_CONFIG:-/cache/docker}"
export DOCKER_CLI_PLUGINS_PATH="/cache/docker/cli-plugins"

log_feature_summary \
    --feature "Docker" \
    --tools "docker,docker-compose,lazydocker,dive,cosign" \
    --paths "${DOCKER_CONFIG},${DOCKER_CLI_PLUGINS_PATH}" \
    --env "DOCKER_CONFIG,DOCKER_CLI_PLUGINS_PATH" \
    --commands "docker,docker compose,lazydocker,dive,cosign" \
    --next-steps "Run 'test-docker' to verify installation. Mount Docker socket with -v /var/run/docker.sock:/var/run/docker.sock to use Docker commands. Use 'cosign' to sign and verify container images."

# End logging
log_feature_end
