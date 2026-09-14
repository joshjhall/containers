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
source /tmp/build-scripts/base/feature-header-bootstrap.sh

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
        command sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
    elif ! grep -q "^user_allow_other" /etc/fuse.conf; then
        echo "user_allow_other" >>/etc/fuse.conf
    fi
else
    echo "user_allow_other" >/etc/fuse.conf
fi

log_message "  user_allow_other enabled in /etc/fuse.conf"

# ============================================================================
# Verification
# ============================================================================
log_message "Verifying bindfs installation..."

if bindfs --version >/dev/null 2>&1; then
    BINDFS_VER=$(bindfs --version 2>&1 | command head -1)
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

# The sweep lock (issue #950). The cron pass fires every 10 minutes and the boot
# pass can fire concurrently at startup; since #948 removed the depth bound,
# nothing else caps how long one walk runs, so two can overlap on a large tree.
# /usr/local/bin/fuse-cleanup takes a NON-BLOCKING flock on this file and skips
# when it is held — see that script's header for why skipping beats queueing.
#
# Same placement and modes as /etc/container/lock/claude-setup.lock (#943):
# root-owned 0755 directory so the path cannot be pre-planted from /tmp, and a
# 0666 lock file so any runtime UID can open it (the container user is remapped
# after build, so the runtime UID is not knowable here). `install -d` is
# idempotent, so creating the directory again here is safe whether or not
# claude-code-setup ran — the two features are independently selectable.
log_message "Creating FUSE cleanup sweep lock..."
install -d -m 755 -o root -g root /etc/container/lock
install -m 666 -o root -g root /dev/null \
    /etc/container/lock/fuse-cleanup.lock

# Create the wrapper script that cron will execute
command cat >/usr/local/bin/fuse-cleanup-cron <<'FUSE_CLEANUP_EOF'
#!/bin/bash
# Wrapper script for FUSE hidden file cleanup cron job
# Sources container environment, then delegates to the shared GC.
#
# The sweep itself lives in /usr/local/bin/fuse-cleanup, shared with the
# boot-time pass in lib/runtime/lib/setup-bindfs.sh. This used to be a second
# near-identical copy, and the two had already drifted on the root they walked
# and on what their depth bound meant (issue #948). This leg now only supplies
# the cron environment and the reporting voice.
#
# Output goes to stdout/stderr, which the /etc/cron.d entry redirects to
# /var/log/fuse-cleanup.log. NOT piped to logger: these images ship no syslog
# daemon, so there is no /dev/log to receive it and logger would discard the
# message and still exit 0 - the same silent-failure class this leg is being
# fixed for (issue #951).

# Load container environment (provides PATH, etc.)
if [ -f /etc/container/cron-env ]; then
    source /etc/container/cron-env
fi

FUSE_CLEANUP_BIN="${FUSE_CLEANUP_BIN:-/usr/local/bin/fuse-cleanup}"

if [ ! -x "$FUSE_CLEANUP_BIN" ]; then
    # Shared GC not installed. Report it and exit 0: a missing GC is not a cron
    # failure, but an UNREPORTED one leaves this leg permanently disabled while
    # looking like a clean run - which is how the stranded .fuse_hidden* files
    # of issue #948 became invisible in the first place (issue #951).
    command echo "$(command date -Is) fuse-cleanup: $FUSE_CLEANUP_BIN missing or not executable - sweep skipped"
    exit 0
fi

cleaned=$("$FUSE_CLEANUP_BIN" 2>/dev/null || echo 0)

if [ "${cleaned:-0}" -gt 0 ] 2>/dev/null; then
    command echo "$(command date -Is) fuse-cleanup: cleaned $cleaned stale .fuse_hidden file(s)"
fi
FUSE_CLEANUP_EOF

chmod +x /usr/local/bin/fuse-cleanup-cron

# Create the cron job in /etc/cron.d/
# Runs every 10 minutes
# Note: USERNAME is substituted at build time
command cat >/etc/cron.d/fuse-cleanup <<CRON_EOF
# FUSE hidden file cleanup - remove stale .fuse_hidden* files
# Runs every 10 minutes
# Configuration via environment variables:
#   FUSE_CLEANUP_DISABLE - Set to "true" to disable
#
# Output is appended to /var/log/fuse-cleanup.log, group-owned by the container
# user so a plain \`tail\` works without sudo. NOT piped to logger: these images
# ship no syslog daemon, so logger would discard the message and still exit 0 -
# the silent-failure class issue #951 exists to close. A plain redirect also
# keeps cron seeing the job's own exit status rather than a pipeline's.

SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=""

*/10 * * * * ${USERNAME} /usr/local/bin/fuse-cleanup-cron >> /var/log/fuse-cleanup.log 2>&1
CRON_EOF

chmod 644 /etc/cron.d/fuse-cleanup

# Create the log file with group ownership so the container user can read it
# without sudo (root:root 640 would be unreadable to them). Same trio the
# workspace-fs-health cron entry uses in the Dockerfile.
touch /var/log/fuse-cleanup.log
chgrp "${USERNAME}" /var/log/fuse-cleanup.log
chmod 640 /var/log/fuse-cleanup.log

log_message "  Created /usr/local/bin/fuse-cleanup-cron"
log_message "  Created /etc/cron.d/fuse-cleanup (every 10 minutes)"
log_message "  Created /var/log/fuse-cleanup.log"

# ============================================================================
# Feature Summary
# ============================================================================

log_feature_summary \
    --feature "Bindfs" \
    --tools "bindfs,fusermount3" \
    --paths "/etc/fuse.conf,/usr/local/bin/fuse-cleanup-cron,/etc/cron.d/fuse-cleanup,/etc/container/lock/fuse-cleanup.lock,/var/log/fuse-cleanup.log" \
    --env "BINDFS_ENABLED,BINDFS_SKIP_PATHS,FUSE_CLEANUP_DISABLE,FUSE_CLEANUP_LOCK" \
    --next-steps "Run container with --cap-add SYS_ADMIN --device /dev/fuse. Overlays applied automatically by entrypoint."

# End logging
log_feature_end
