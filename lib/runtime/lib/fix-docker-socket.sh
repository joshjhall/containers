#!/bin/bash
# Docker Socket Access Fix
# Sourced by entrypoint.sh — do not execute directly
#
# Automatically configures Docker socket access if the socket exists.
# Creates/uses a 'docker' group, chowns the socket to that group, and adds
# the user. This is more secure than chmod 666 as it limits access to group
# members only.
#
# Works in two modes:
#   1. Running as root: directly modify socket permissions
#   2. Running as non-root with sudo: use sudo for privileged operations
#
# Depends on globals from entrypoint.sh:
#   RUNNING_AS_ROOT, USERNAME, run_privileged()

configure_docker_socket() {
    [ -S /var/run/docker.sock ] || return 0

    # Check if we can already access the socket
    if test -r /var/run/docker.sock -a -w /var/run/docker.sock 2>/dev/null; then
        return 0
    fi

    echo "🔧 Configuring Docker socket access..."

    # Determine if we can perform privileged operations
    local can_sudo=false
    if [ "$RUNNING_AS_ROOT" = "true" ]; then
        can_sudo=true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        can_sudo=true
    fi

    if [ "$can_sudo" = "true" ]; then
        # Create docker group if it doesn't exist
        if ! getent group docker >/dev/null 2>&1; then
            run_privileged groupadd docker 2>/dev/null || {
                echo "⚠️  Warning: Could not create docker group"
            }
        fi

        # Change socket ownership to root:docker with 660 permissions
        if ! run_privileged chown root:docker /var/run/docker.sock 2>/dev/null || \
           ! run_privileged chmod 660 /var/run/docker.sock 2>/dev/null; then
            echo "⚠️  Warning: Could not change Docker socket ownership/permissions"
        fi

        # Add user to docker group
        run_privileged usermod -aG docker "$USERNAME" 2>/dev/null || {
            echo "⚠️  Warning: Could not add $USERNAME to docker group"
        }

        echo "✓ Docker socket access configured (user added to docker group)"

        # If running as non-root, we need to re-exec with new group membership
        # The sg command runs a command with a supplementary group
        if [ "$RUNNING_AS_ROOT" = "false" ] && [ -n "$*" ]; then
            # Mark that we've already configured docker so we don't loop
            export DOCKER_SOCKET_CONFIGURED=true
        fi
    else
        echo "⚠️  Warning: Cannot configure Docker socket - no root access or sudo"
        echo "   Docker commands may fail. Run container as root or enable passwordless sudo."
    fi
}
