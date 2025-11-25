#!/bin/bash
# Install and configure fixuid for runtime UID/GID remapping
#
# fixuid is a Go binary that adjusts container user/group IDs at runtime
# to match the host user's UID/GID when mounting volumes. This solves the
# common problem where files created in containers have wrong ownership.
#
# This script:
#   1. Downloads and installs fixuid binary with setuid bit
#   2. Creates /etc/fixuid/config.yml pointing to the container user
#   3. The entrypoint will run fixuid if FIXUID_ENABLED=true
#
# Usage:
#   This script is called from the Dockerfile during build
#   At runtime, set FIXUID_ENABLED=true to activate UID/GID remapping
#
# Security note:
#   fixuid uses setuid to gain root privileges for remapping.
#   It should only be used in DEVELOPMENT containers, never production.
#
# See: https://github.com/boxboat/fixuid

set -euo pipefail

# Source build environment to get username
if [ -f /tmp/build-env ]; then
    # shellcheck source=/dev/null
    source /tmp/build-env
fi

# Default values
USERNAME="${USERNAME:-developer}"
FIXUID_VERSION="${FIXUID_VERSION:-0.6.0}"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  FIXUID_ARCH="amd64" ;;
    aarch64) FIXUID_ARCH="arm64" ;;
    armv7l)  FIXUID_ARCH="armhf" ;;
    *)
        echo "⚠️  fixuid: Unsupported architecture: $ARCH"
        echo "   Skipping fixuid installation"
        exit 0
        ;;
esac

echo "=== Installing fixuid v${FIXUID_VERSION} (${FIXUID_ARCH}) ==="

# Download and install fixuid
FIXUID_URL="https://github.com/boxboat/fixuid/releases/download/v${FIXUID_VERSION}/fixuid-${FIXUID_VERSION}-linux-${FIXUID_ARCH}.tar.gz"

if curl -fsSL "$FIXUID_URL" | tar -C /usr/local/bin -xzf -; then
    # Set proper ownership and setuid bit
    chown root:root /usr/local/bin/fixuid
    chmod 4755 /usr/local/bin/fixuid

    # Create config directory and file
    mkdir -p /etc/fixuid
    cat > /etc/fixuid/config.yml << EOF
# fixuid configuration
# See: https://github.com/boxboat/fixuid
user: ${USERNAME}
group: ${USERNAME}
paths:
  - /home/${USERNAME}
  - /workspace
EOF

    echo "✓ fixuid installed successfully"
    echo "  Binary: /usr/local/bin/fixuid"
    echo "  Config: /etc/fixuid/config.yml"
    echo ""
    echo "  To enable at runtime, set: FIXUID_ENABLED=true"
    echo "  Run container with: docker run -u \$(id -u):\$(id -g) ..."
else
    echo "⚠️  Warning: Failed to download fixuid"
    echo "   Container will work without UID/GID remapping"
    exit 0
fi
