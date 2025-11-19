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
source /tmp/build-scripts/features/lib/checksum-fetch.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh
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

log_command "Setting Docker GPG key permissions" \
    chmod a+r /etc/apt/keyrings/docker.gpg

# ============================================================================
# Docker CLI Installation
# ============================================================================
log_message "Installing Docker CLI tools..."

# Add Docker repository for latest CLI version
# Note: We can't use log_command here because it would include log output in the file
log_message "Adding Docker repository..."
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

# Log the result
if [ $? -eq 0 ]; then
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

# Detect architecture
ARCH=$(dpkg --print-architecture)

# Map dpkg architecture to lazydocker naming
case "$ARCH" in
    amd64)
        LAZYDOCKER_ARCH="x86_64"
        ;;
    arm64)
        LAZYDOCKER_ARCH="arm64"
        ;;
    *)
        log_error "Unsupported architecture for lazydocker: $ARCH"
        exit 1
        ;;
esac

# Version is configurable via build arg
LAZYDOCKER_VERSION="0.24.2"
LAZYDOCKER_ARCHIVE="lazydocker_${LAZYDOCKER_VERSION}_Linux_${LAZYDOCKER_ARCH}.tar.gz"
LAZYDOCKER_URL="https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/${LAZYDOCKER_ARCHIVE}"

log_message "Installing lazydocker v${LAZYDOCKER_VERSION} for ${LAZYDOCKER_ARCH}..."

# Fetch checksum dynamically from GitHub releases
log_message "Fetching lazydocker checksum from GitHub..."
LAZYDOCKER_CHECKSUMS_URL="https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/checksums.txt"

if ! LAZYDOCKER_CHECKSUM=$(fetch_github_checksums_txt "$LAZYDOCKER_CHECKSUMS_URL" "$LAZYDOCKER_ARCHIVE" 2>/dev/null); then
    log_error "Failed to fetch checksum for lazydocker ${LAZYDOCKER_VERSION}"
    log_error "Please verify version exists: https://github.com/jesseduffield/lazydocker/releases/tag/v${LAZYDOCKER_VERSION}"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${LAZYDOCKER_CHECKSUM}"

# Download and extract with checksum verification
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading and verifying lazydocker..."
download_and_extract \
    "$LAZYDOCKER_URL" \
    "$LAZYDOCKER_CHECKSUM" \
    "."

# Install binary
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

# Set dive version
DIVE_VERSION="0.13.1"

# Construct the dive package filename
DIVE_PACKAGE="dive_${DIVE_VERSION}_linux_${ARCH}.deb"
DIVE_URL="https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/${DIVE_PACKAGE}"

# Fetch checksum dynamically from GitHub releases
log_message "Fetching dive checksum from GitHub..."
DIVE_CHECKSUMS_URL="https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_checksums.txt"

if ! DIVE_CHECKSUM=$(fetch_github_checksums_txt "$DIVE_CHECKSUMS_URL" "$DIVE_PACKAGE" 2>/dev/null); then
    log_error "Failed to fetch checksum for dive ${DIVE_VERSION}"
    log_error "Please verify version exists: https://github.com/wagoodman/dive/releases/tag/v${DIVE_VERSION}"
    log_feature_end
    exit 1
fi

log_message "Expected SHA256: ${DIVE_CHECKSUM}"

# Download and verify dive with checksum verification
BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"
log_message "Downloading and verifying dive..."
download_and_verify \
    "$DIVE_URL" \
    "$DIVE_CHECKSUM" \
    "dive.deb"

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

    # Construct the cosign package filename
    COSIGN_PACKAGE="cosign_${COSIGN_VERSION}_${ARCH}.deb"
    COSIGN_URL="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/${COSIGN_PACKAGE}"

    # Fetch checksum dynamically from GitHub releases
    log_message "Fetching cosign checksum from GitHub..."
    COSIGN_CHECKSUMS_URL="https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign_checksums.txt"

    if ! COSIGN_CHECKSUM=$(fetch_github_checksums_txt "$COSIGN_CHECKSUMS_URL" "$COSIGN_PACKAGE" 2>/dev/null); then
        log_error "Failed to fetch checksum for cosign ${COSIGN_VERSION}"
        log_error "Please verify version exists: https://github.com/sigstore/cosign/releases/tag/v${COSIGN_VERSION}"
        log_feature_end
        exit 1
    fi

    log_message "Expected SHA256: ${COSIGN_CHECKSUM}"

    # Download and verify cosign with checksum verification
    BUILD_TEMP=$(create_secure_temp_dir)
    cd "$BUILD_TEMP"
    log_message "Downloading and verifying cosign..."
    download_and_verify \
        "$COSIGN_URL" \
        "$COSIGN_CHECKSUM" \
        "cosign.deb"

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

# Create system-wide Docker configuration
write_bashrc_content /etc/bashrc.d/50-docker.sh "Docker configuration" << 'DOCKER_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Docker Aliases and Functions
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

# ----------------------------------------------------------------------------
# Docker Aliases - Common container operations
# ----------------------------------------------------------------------------
alias d='docker'                           # Short alias for docker
alias dc='docker compose'                  # Docker Compose V2
alias dps='docker ps'                      # List running containers
alias dpsa='docker ps -a'                  # List all containers
alias di='docker images'                   # List images
alias dex='docker exec -it'                # Execute interactive command
alias dlog='docker logs'                   # View container logs
alias dprune='docker system prune -af'     # Clean all unused resources

# Lazydocker alias
if command -v lazydocker &> /dev/null; then
    alias lzd='lazydocker'
    alias ld='lazydocker'
fi

# ----------------------------------------------------------------------------
# docker-clean - Clean up Docker resources incrementally
#
# Removes stopped containers, unused images, networks, and volumes
# ----------------------------------------------------------------------------
docker-clean() {
    echo "Cleaning up Docker resources..."
    docker container prune -f
    docker image prune -f
    docker network prune -f
    docker volume prune -f
    echo "Docker cleanup complete"
}

# ----------------------------------------------------------------------------
# docker-stats - Show formatted container resource usage
#
# Displays CPU, memory, network, and block I/O statistics
# ----------------------------------------------------------------------------
docker-stats() {
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
}

# ----------------------------------------------------------------------------
# docker-dive - Analyze Docker image layers with dive
#
# Arguments:
#   $1 - Image name or ID (required)
#
# Example:
#   docker-dive ubuntu:latest
# ----------------------------------------------------------------------------
docker-dive() {
    if [ -z "$1" ]; then
        echo "Usage: docker-dive <image-name>"
        return 1
    fi
    dive "$1"
}

# ----------------------------------------------------------------------------
# docker-shell - Start interactive shell in a container
#
# Arguments:
#   $1 - Container name or ID (required)
#   $2 - Shell command (default: /bin/bash)
#
# Example:
#   docker-shell myapp
#   docker-shell myapp /bin/sh
# ----------------------------------------------------------------------------
docker-shell() {
    if [ -z "$1" ]; then
        echo "Usage: docker-shell <container> [shell]"
        return 1
    fi

    local container="$1"
    local shell="${2:-/bin/bash}"

    docker exec -it "$container" "$shell" || docker exec -it "$container" /bin/sh
}

# ----------------------------------------------------------------------------
# docker-compose-logs - Tail logs for all compose services
#
# Arguments:
#   $1 - Number of lines to tail (default: 100)
#
# Example:
#   docker-compose-logs
#   docker-compose-logs 500
# ----------------------------------------------------------------------------
docker-compose-logs() {
    local lines="${1:-100}"
    docker compose logs -f --tail="$lines"
}

# ----------------------------------------------------------------------------
# docker-cleanup-volumes - Remove unused Docker volumes
#
# Lists volumes first, then prompts for confirmation
# ----------------------------------------------------------------------------
docker-cleanup-volumes() {
    echo "Unused Docker volumes:"
    docker volume ls -qf dangling=true
    echo ""
    read -p "Remove all unused volumes? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        docker volume prune -f
        echo "Unused volumes removed"
    fi
}

# Docker cache configuration
export DOCKER_CONFIG="${DOCKER_CONFIG:-/cache/docker}"
export DOCKER_CLI_PLUGINS_PATH="/cache/docker/cli-plugins"

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
DOCKER_BASHRC_EOF

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
