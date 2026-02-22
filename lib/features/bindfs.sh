#!/bin/bash
# Bindfs - FUSE overlay for host bind mount permission fixes
#
# Description:
#   Installs bindfs and fuse3 to enable in-place FUSE overlays on host bind
#   mounts. Fixes permission issues common with macOS VirtioFS where APFS
#   lacks full Linux permission semantics, causing execute bits to drop and
#   ownership to appear incorrect.
#
# Features:
#   - bindfs + fuse3 package installation
#   - /etc/fuse.conf configured with user_allow_other
#   - Automatic overlay applied by entrypoint at container startup
#
# Environment Variables (runtime):
#   - BINDFS_ENABLED: auto (default), true, or false
#     - auto: probe permissions on each mount, apply only if broken
#     - true: always apply bindfs to all bind mounts under /workspace
#     - false: disable bindfs entirely
#   - BINDFS_SKIP_PATHS: comma-separated paths to exclude
#     (e.g., /workspace/.git,/workspace/node_modules)
#
# Runtime Requirements:
#   Container must be run with:
#   - --cap-add SYS_ADMIN (or --privileged)
#   - --device /dev/fuse
#
# Example docker-compose.yml:
#   services:
#     dev:
#       build:
#         args:
#           INCLUDE_BINDFS: "true"
#       cap_add:
#         - SYS_ADMIN
#       devices:
#         - /dev/fuse
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Bindfs"

# ============================================================================
# Package Installation
# ============================================================================
log_message "Installing bindfs and fuse3..."

apt_update
apt_install bindfs fuse3

# ============================================================================
# FUSE Configuration
# ============================================================================
log_message "Configuring /etc/fuse.conf..."

# Enable user_allow_other so non-root users can use the allow_other mount option
if [ -f /etc/fuse.conf ]; then
    if grep -q "^#user_allow_other" /etc/fuse.conf; then
        sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
    elif ! grep -q "^user_allow_other" /etc/fuse.conf; then
        echo "user_allow_other" >> /etc/fuse.conf
    fi
else
    echo "user_allow_other" > /etc/fuse.conf
fi

log_message "  user_allow_other enabled in /etc/fuse.conf"

# ============================================================================
# Verification
# ============================================================================
log_message "Verifying bindfs installation..."

if bindfs --version >/dev/null 2>&1; then
    BINDFS_VER=$(bindfs --version 2>&1 | head -1)
    log_message "  $BINDFS_VER"
else
    log_error "bindfs installation verification failed"
    exit 1
fi

if fusermount3 --version >/dev/null 2>&1; then
    log_message "  fusermount3 available"
else
    log_error "fusermount3 not available"
    exit 1
fi

# ============================================================================
# Feature Summary
# ============================================================================

log_feature_summary \
    --feature "Bindfs" \
    --tools "bindfs,fusermount3" \
    --paths "/etc/fuse.conf" \
    --env "BINDFS_ENABLED,BINDFS_SKIP_PATHS" \
    --next-steps "Run container with --cap-add SYS_ADMIN --device /dev/fuse. Overlays applied automatically by entrypoint."

# End logging
log_feature_end
