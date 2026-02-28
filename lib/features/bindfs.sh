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
# Cron Job for FUSE Hidden File Cleanup
# ============================================================================
# FUSE filesystems defer file deletion when a process still holds the file open,
# renaming it to .fuse_hidden* until the last file descriptor closes. Stale files
# can be left behind after unclean process exits or container stops. This cron job
# cleans them up every 10 minutes (the entrypoint handles the boot-time pass).
log_message "Creating FUSE hidden file cleanup cron job..."

# Create cron.d directory if it doesn't exist
mkdir -p /etc/cron.d

# Create the wrapper script that cron will execute
command cat > /usr/local/bin/fuse-cleanup-cron << 'FUSE_CLEANUP_EOF'
#!/bin/bash
# Wrapper script for FUSE hidden file cleanup cron job
# Sources container environment and cleans stale .fuse_hidden* files
# from all FUSE/bindfs mount points.

# Load container environment (provides PATH, etc.)
if [ -f /etc/container/cron-env ]; then
    source /etc/container/cron-env
fi

# Check if disabled
if [ "${FUSE_CLEANUP_DISABLE:-false}" = "true" ]; then
    exit 0
fi

# Find all FUSE mount points (fuse, fuse.bindfs, etc.)
fuse_mounts=$(findmnt -n -r -o TARGET -t fuse,fuse.bindfs 2>/dev/null || true)

if [ -z "$fuse_mounts" ]; then
    # No FUSE mounts active, nothing to clean
    exit 0
fi

cleaned=0
while IFS= read -r mnt_target; do
    [ -z "$mnt_target" ] && continue

    while IFS= read -r -d '' hidden_file; do
        # Skip files still held open by a running process
        if command -v fuser >/dev/null 2>&1; then
            fuser "$hidden_file" >/dev/null 2>&1 && continue
        fi
        rm -f "$hidden_file" 2>/dev/null && cleaned=$((cleaned + 1))
    done < <(command find "$mnt_target" -maxdepth 3 -name '.fuse_hidden*' -print0 2>/dev/null)
done <<< "$fuse_mounts"

if [ "$cleaned" -gt 0 ]; then
    logger -t fuse-cleanup "Cleaned $cleaned stale .fuse_hidden file(s)"
fi
FUSE_CLEANUP_EOF

chmod +x /usr/local/bin/fuse-cleanup-cron

# Create the cron job in /etc/cron.d/
# Runs every 10 minutes
# Note: USERNAME is substituted at build time
command cat > /etc/cron.d/fuse-cleanup << CRON_EOF
# FUSE hidden file cleanup - remove stale .fuse_hidden* files
# Runs every 10 minutes
# Configuration via environment variables:
#   FUSE_CLEANUP_DISABLE - Set to "true" to disable

SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

*/10 * * * * ${USERNAME} /usr/local/bin/fuse-cleanup-cron
CRON_EOF

chmod 644 /etc/cron.d/fuse-cleanup

log_message "  Created /usr/local/bin/fuse-cleanup-cron"
log_message "  Created /etc/cron.d/fuse-cleanup (every 10 minutes)"

# ============================================================================
# Feature Summary
# ============================================================================

log_feature_summary \
    --feature "Bindfs" \
    --tools "bindfs,fusermount3" \
    --paths "/etc/fuse.conf,/usr/local/bin/fuse-cleanup-cron,/etc/cron.d/fuse-cleanup" \
    --env "BINDFS_ENABLED,BINDFS_SKIP_PATHS,FUSE_CLEANUP_DISABLE" \
    --next-steps "Run container with --cap-add SYS_ADMIN --device /dev/fuse. Overlays applied automatically by entrypoint."

# End logging
log_feature_end
