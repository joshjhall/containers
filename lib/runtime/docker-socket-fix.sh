#!/bin/bash
# Docker Socket Permission Fix
# 
# This script ensures Docker socket has proper permissions at runtime.
# It runs during container startup to handle cases where the socket
# is mounted after the container is built.

set -euo pipefail

# Only run if we're in a container environment
if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ]; then
    exit 0
fi

# Check if Docker socket exists
if [ -S /var/run/docker.sock ]; then
    # Check if current user can access docker
    if ! docker version &>/dev/null 2>&1; then
        echo "Docker socket detected but not accessible, attempting to fix permissions..."
        
        # Try to fix permissions (will fail silently if not root)
        if [ "$(id -u)" = "0" ]; then
            # Running as root, can fix permissions
            chgrp docker /var/run/docker.sock 2>/dev/null || true
            chmod g+rw /var/run/docker.sock 2>/dev/null || true
            echo "Docker socket permissions updated"
        else
            # Not root, try with sudo if available
            if command -v sudo &>/dev/null 2>&1; then
                sudo chgrp docker /var/run/docker.sock 2>/dev/null || true
                sudo chmod g+rw /var/run/docker.sock 2>/dev/null || true
                echo "Docker socket permissions updated via sudo"
            else
                echo "Warning: Cannot fix Docker socket permissions (not root and sudo not available)"
                echo "You may need to run Docker commands with sudo or restart the container"
            fi
        fi
        
        # Test if it works now
        if docker version &>/dev/null 2>&1; then
            echo "Docker socket is now accessible"
        else
            echo "Docker socket still not accessible. You may need to:"
            echo "  1. Run Docker commands with sudo"
            echo "  2. Restart the container"
            echo "  3. Mount the socket with proper permissions"
        fi
    else
        echo "Docker socket is accessible"
    fi
fi