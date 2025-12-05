#!/bin/bash
# User creation and setup with automatic UID/GID conflict resolution
#
# This script creates a user for the container, handling cases where the
# requested UID/GID might already exist in the base image.
#
# Parameters:
#   $1 - Username (default: developer)
#   $2 - Desired UID (default: 1000)
#   $3 - Desired GID (default: same as UID)
#   $4 - Project name (default: project)
#   $5 - Working directory (default: /workspace/project)
#   $6 - Enable passwordless sudo (default: true, production: false)
#
# Outputs:
#   - Creates user with home directory and optional sudo access
#   - Writes actual UID/GID to /tmp/build-env for use by feature scripts
#   - Sets up .bashrc.d for modular bash configuration
#
# The script automatically finds alternative UID/GID values if conflicts occur,
# ensuring the build always succeeds regardless of the base image's existing users.
set -euo pipefail

USERNAME="${1:-developer}"
USER_UID="${2:-1000}"
USER_GID="${3:-$USER_UID}"
PROJECT_NAME="${4:-project}"
WORKING_DIR="${5:-/workspace/${PROJECT_NAME}}"
ENABLE_PASSWORDLESS_SUDO="${6:-true}"

echo "=== Setting up user: ${USERNAME} (${USER_UID}:${USER_GID}) ==="

# Check if user already exists first
if id -u "${USERNAME}" > /dev/null 2>&1; then
    echo "User ${USERNAME} already exists, using existing user..."
    ACTUAL_UID=$(id -u "${USERNAME}")
    ACTUAL_GID=$(id -g "${USERNAME}")
    echo "Existing user has UID: ${ACTUAL_UID}, GID: ${ACTUAL_GID}"
    # Skip group creation for existing users
    USER_EXISTS=true
else
    USER_EXISTS=false
    # Handle group creation with existing GID check
    if ! getent group "${USERNAME}" > /dev/null 2>&1; then
        if getent group "${USER_GID}" > /dev/null 2>&1; then
            echo "GID ${USER_GID} already exists, finding a free GID..."
            FREE_GID=$(awk -F: '$3>=1000 && $3<65534 {print $3}' /etc/group | sort -n | \
                awk 'BEGIN{for(i=1;i<=NR;i++) gids[i]=0} {gids[$1]=1} END{for(i=1000;i<65534;i++) if(!gids[i]) {print i; exit}}')
            echo "Using GID: ${FREE_GID}"
            groupadd --gid "${FREE_GID}" "${USERNAME}"
            ACTUAL_GID=${FREE_GID}
        else
            groupadd --gid "${USER_GID}" "${USERNAME}"
            ACTUAL_GID=${USER_GID}
        fi
    else
        ACTUAL_GID=$(getent group "${USERNAME}" | cut -d: -f3)
    fi
fi

# Handle user creation only if user doesn't exist
if [ "$USER_EXISTS" = false ]; then
    if id "${USER_UID}" > /dev/null 2>&1; then
        echo "UID ${USER_UID} already exists, finding a free UID..."
        FREE_UID=$(awk -F: '$3>=1000 && $3<65534 {print $3}' /etc/passwd | sort -n | \
            awk 'BEGIN{for(i=1;i<=NR;i++) uids[i]=0} {uids[$1]=1} END{for(i=1000;i<65534;i++) if(!uids[i]) {print i; exit}}')
        echo "Using UID: ${FREE_UID}"
        useradd --uid "${FREE_UID}" --gid "${ACTUAL_GID}" -m "${USERNAME}" --shell /bin/bash
        ACTUAL_UID=${FREE_UID}
    else
        useradd --uid "${USER_UID}" --gid "${ACTUAL_GID}" -m "${USERNAME}" --shell /bin/bash
        ACTUAL_UID=${USER_UID}
    fi
fi

# Export actual UID/GID and USERNAME for use in subsequent scripts
{
    echo "export USERNAME=${USERNAME}"
    echo "export ACTUAL_UID=${ACTUAL_UID}"
    echo "export ACTUAL_GID=${ACTUAL_GID}"
    echo "export WORKING_DIR=${WORKING_DIR}"
} >> /tmp/build-env

# Also export as environment variables for the current build
export ACTUAL_UID="${ACTUAL_UID}"
export ACTUAL_GID="${ACTUAL_GID}"
export WORKING_DIR="${WORKING_DIR}"

# Write to a file that can be sourced by Dockerfile
echo "${ACTUAL_UID}" > /tmp/actual_uid
echo "${ACTUAL_GID}" > /tmp/actual_gid

# Add user to sudo group
usermod -aG sudo "${USERNAME}"

# Configure sudo access based on security policy
if [ "${ENABLE_PASSWORDLESS_SUDO}" = "true" ]; then
    # Use install command for atomic file creation with correct permissions
    # This prevents race condition where file briefly has wrong permissions
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" | \
        install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/"${USERNAME}"
    echo "⚠️  WARNING: Passwordless sudo enabled (development mode)"
    echo "    This allows any process as '${USERNAME}' to gain root access without password."
    echo "    Useful for local development where you need to install packages or fix permissions."
    echo "    NOT RECOMMENDED for production containers - use ENABLE_PASSWORDLESS_SUDO=false"
else
    echo "✓ Passwordless sudo disabled (production/secure mode)"
    echo "  User ${USERNAME} is in sudo group but requires password for sudo commands"
    echo "  For local development convenience, you can enable with:"
    echo "  --build-arg ENABLE_PASSWORDLESS_SUDO=true"
fi

# Create common directories (check if home exists first)
if [ -d "/home/${USERNAME}" ]; then
    echo "Home directory already exists for ${USERNAME}"
else
    echo "Creating home directory for ${USERNAME}"
    mkdir -p /home/"${USERNAME}"
fi

# Create user directories
mkdir -p /home/"${USERNAME}"/.local/bin
mkdir -p /home/"${USERNAME}"/.cache
mkdir -p /home/"${USERNAME}"/.ssh
mkdir -p "${WORKING_DIR}"

# Create cache directory for volume mounts (features will create subdirs as needed)
mkdir -p /cache
chown "${USERNAME}":"${USERNAME}" /cache
chmod 755 /cache

# Set proper permissions for SSH directory
chmod 700 /home/"${USERNAME}"/.ssh

# Set ownership
chown -R "${USERNAME}":"${USERNAME}" /home/"${USERNAME}"

# Set ownership on working directory and its parent
# Extract parent directory from WORKING_DIR
WORKSPACE_PARENT=$(dirname "${WORKING_DIR}")
if [ -d "${WORKSPACE_PARENT}" ] && [ "${WORKSPACE_PARENT}" != "/" ]; then
    # If parent exists and isn't root, chown the parent (which includes the working dir)
    chown -R "${USERNAME}":"${USERNAME}" "${WORKSPACE_PARENT}"
else
    # Otherwise just chown the working directory itself
    chown -R "${USERNAME}":"${USERNAME}" "${WORKING_DIR}"
fi

# Create user's bashrc.d directory for features to add scripts to
mkdir -p /home/"${USERNAME}"/.bashrc.d
chown "${USERNAME}":"${USERNAME}" /home/"${USERNAME}"/.bashrc.d

# Add sourcing of bashrc.d directory to user's bashrc if not already present
if ! grep -q "bashrc.d" /home/"${USERNAME}"/.bashrc; then
    {
        echo ""
        echo "# Source additional configurations from features"
        echo 'for f in ~/.bashrc.d/*; do [ -r "$f" ] && source "$f"; done'
    } >> /home/"${USERNAME}"/.bashrc
fi

# Add useful helper functions to user's bashrc
command cat >> /home/"${USERNAME}"/.bashrc << 'EOF'

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Node modules in PATH helper
add_node_modules_to_path() {
    if [[ -d "$PWD/node_modules/.bin" ]]; then
        if command -v safe_add_to_path >/dev/null 2>&1; then
            safe_add_to_path "$PWD/node_modules/.bin" 2>/dev/null || export PATH="$PWD/node_modules/.bin:${PATH##*$PWD/node_modules/.bin:}"
        else
            export PATH="$PWD/node_modules/.bin:${PATH##*$PWD/node_modules/.bin:}"
        fi
    fi
}

# SSH agent persistence
if [ -f ~/.ssh/agent.env ]; then
    . ~/.ssh/agent.env >/dev/null
    if ! ps -p $SSH_AGENT_PID >/dev/null 2>&1; then
        ssh-agent -s > ~/.ssh/agent.env
        . ~/.ssh/agent.env >/dev/null
    fi
    export SSH_AUTH_SOCK SSH_AGENT_PID
fi

# Override cd to add node_modules to PATH
cd() {
    builtin cd "$@" && add_node_modules_to_path
}

# Initialize node_modules PATH for current directory
add_node_modules_to_path

EOF

if [ "$USER_EXISTS" = true ]; then
    echo "=== User ${USERNAME} configured successfully (existing user) ==="
else
    echo "=== User ${USERNAME} created successfully ==="
fi
