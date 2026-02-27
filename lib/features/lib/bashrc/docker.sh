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


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
