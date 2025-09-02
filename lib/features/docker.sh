#!/bin/bash
# Docker CLI Tools - Container management without daemon installation
#
# Description:
#   Installs Docker CLI tools for container management in development environments.
#   This installation includes only client tools - the Docker daemon must be
#   available via socket mount or DOCKER_HOST.
#
# Features:
#   - Docker CLI: Complete container management interface
#   - Docker Compose V2: Multi-container application orchestration
#   - lazydocker: Terminal UI for Docker management
#   - dive: Docker image layer analysis tool
#   - Helper functions for common operations
#   - Automatic user group configuration
#
# Tools Installed:
#   - docker-ce-cli: Latest Docker CLI from official repository
#   - docker-compose-plugin: Docker Compose V2 as plugin
#   - lazydocker: Terminal UI for Docker management
#   - dive: Docker image layer analysis tool
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

# Start logging
log_feature_start "Docker CLI Tools"

# ============================================================================
# Repository Configuration
# ============================================================================
log_message "Configuring Docker repository..."

# Prepare directory for Docker GPG key
log_command "Creating keyrings directory" \
    install -m 0755 -d /etc/apt/keyrings

log_command "Adding Docker GPG key" \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

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
log_command "Updating package lists" \
    apt-get update

log_command "Installing Docker CLI and Compose plugin" \
    apt-get install -y docker-ce-cli docker-compose-plugin

# ============================================================================
# User Configuration
# ============================================================================
log_message "Configuring user access to Docker..."

# Add user to docker group for socket access
log_command "Creating docker group" \
    groupadd docker || true

log_command "Adding user to docker group" \
    usermod -aG docker ${USERNAME}

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

# Detect architecture and set version
ARCH=$(dpkg --print-architecture)
LAZYDOCKER_VERSION="0.24.1"

# Download and install lazydocker
log_message "Downloading lazydocker..."
cd /tmp

if [ "$ARCH" = "amd64" ]; then
    log_command "Downloading lazydocker for amd64" \
        curl -fsSL -o lazydocker.tar.gz https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/lazydocker_${LAZYDOCKER_VERSION}_Linux_x86_64.tar.gz
elif [ "$ARCH" = "arm64" ]; then
    log_command "Downloading lazydocker for arm64" \
        curl -fsSL -o lazydocker.tar.gz https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/lazydocker_${LAZYDOCKER_VERSION}_Linux_arm64.tar.gz
fi

log_command "Extracting lazydocker" \
    tar xzf lazydocker.tar.gz

log_command "Installing lazydocker binary" \
    mv lazydocker /usr/local/bin/

log_command "Setting lazydocker permissions" \
    chmod +x /usr/local/bin/lazydocker

log_command "Cleaning up lazydocker archive" \
    rm -f lazydocker.tar.gz

cd /

# ============================================================================
# Dive Installation
# ============================================================================
log_message "Installing dive (Docker image layer analysis tool)..."

# Set dive version
DIVE_VERSION="0.13.1"

# Download and install dive
log_message "Downloading dive..."
cd /tmp

if [ "$ARCH" = "amd64" ]; then
    log_command "Downloading dive for amd64" \
        curl -fsSL -o dive.deb https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_amd64.deb
elif [ "$ARCH" = "arm64" ]; then
    log_command "Downloading dive for arm64" \
        curl -fsSL -o dive.deb https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_arm64.deb
fi

if [ -f dive.deb ]; then
    log_command "Installing dive package" \
        dpkg -i dive.deb
    log_command "Cleaning up dive package" \
        rm -f dive.deb
fi

cd /

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring Docker cache directories..."

# Docker uses several cache directories that we can optimize
DOCKER_CACHE_DIR="/cache/docker"
DOCKER_CLI_PLUGINS_DIR="${DOCKER_CACHE_DIR}/cli-plugins"

# Create cache directories
log_command "Creating Docker cache directories" \
    mkdir -p "${DOCKER_CACHE_DIR}" "${DOCKER_CLI_PLUGINS_DIR}"

log_command "Setting cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${DOCKER_CACHE_DIR}"

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
cat > /etc/container/first-startup/20-docker-setup.sh << 'DOCKER_STARTUP_EOF'
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

# Every-boot startup script - runs on each container start to fix socket permissions
cat > /etc/container/startup/10-docker-socket-fix.sh << 'DOCKER_FIX_EOF'
#!/bin/bash
# Docker Socket Permission Fix
# Ensures Docker socket has proper permissions at runtime

# Check if Docker socket exists
if [ -S /var/run/docker.sock ]; then
    # Check if current user can access docker
    if ! docker version &>/dev/null 2>&1; then
        echo "Fixing Docker socket permissions..."
        
        # Try to fix permissions with sudo if available
        if command -v sudo &>/dev/null 2>&1; then
            sudo chgrp docker /var/run/docker.sock 2>/dev/null || true
            sudo chmod g+rw /var/run/docker.sock 2>/dev/null || true
        fi
        
        # Test if it works now
        if docker version &>/dev/null 2>&1; then
            echo "Docker socket is now accessible"
        else
            echo "Note: Docker commands may require sudo"
        fi
    fi
fi
DOCKER_FIX_EOF
log_command "Setting Docker socket fix script permissions" \
    chmod +x /etc/container/startup/10-docker-socket-fix.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Docker verification script..."

cat > /usr/local/bin/test-docker << 'DOCKER_TEST_EOF'
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
for tool in lazydocker dive; do
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

# End logging
log_feature_end

echo ""
echo "Run 'test-docker' to verify installation"
echo "Run 'check-build-logs.sh docker-cli-tools' to review installation logs"
