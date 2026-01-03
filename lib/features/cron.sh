#!/bin/bash
# Cron Daemon - Scheduled task execution for containers
#
# Description:
#   Installs the cron daemon and provides infrastructure for scheduled tasks
#   within development containers. The cron daemon starts automatically on
#   container boot via the startup script system.
#
# Features:
#   - cron package installation
#   - Automatic daemon startup via /etc/container/startup/
#   - Environment file for cron jobs (/etc/container/cron-env)
#   - Support for user crontabs and system /etc/cron.d/
#   - Helper aliases for cron management
#
# Environment Variables:
#   - CRON_LOG_LEVEL: Logging verbosity for crond (default: 0)
#
# Important Notes:
#   Cron jobs do NOT inherit the login shell environment. Jobs that need
#   container environment variables (PATH, CARGO_HOME, etc.) should source
#   /etc/container/cron-env at the start of the job script.
#
# Auto-trigger:
#   This feature is automatically enabled when INCLUDE_RUST_DEV=true or
#   INCLUDE_DEV_TOOLS=true, as scheduled tasks are commonly needed in
#   development environments.
#
# Requirements:
#   The cron daemon requires root privileges to start. To enable automatic
#   startup, build with ENABLE_PASSWORDLESS_SUDO=true. Otherwise, start
#   manually with: sudo service cron start
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Cron Daemon"

# ============================================================================
# Package Installation
# ============================================================================
log_message "Installing cron package..."

apt_update
apt_install cron

# ============================================================================
# Environment File for Cron Jobs
# ============================================================================
log_message "Creating cron environment file..."

# Ensure container directory exists
log_command "Creating container config directory" \
    mkdir -p /etc/container

# Create environment file that cron jobs can source
# This provides the container's runtime environment to cron jobs
command cat > /etc/container/cron-env << 'CRON_ENV_EOF'
#!/bin/bash
# Cron Environment File
# Source this file at the start of cron job scripts to get container environment
#
# Usage in cron job scripts:
#   #!/bin/bash
#   source /etc/container/cron-env
#   # rest of script...

# Standard paths
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# Home directory (will be set based on user running the job)
export HOME="${HOME:-/home/${USER:-root}}"

# Workspace directory
export WORKING_DIR="${WORKING_DIR:-/workspace}"

# Rust environment (if installed)
if [ -d "/cache/cargo" ]; then
    export CARGO_HOME="/cache/cargo"
    export RUSTUP_HOME="/cache/rustup"
    export PATH="${CARGO_HOME}/bin:${PATH}"
fi

# Python environment (if installed)
if [ -d "/cache/pip" ]; then
    export PIP_CACHE_DIR="/cache/pip"
fi

# Node.js environment (if installed)
if [ -d "/cache/npm" ]; then
    export NPM_CONFIG_CACHE="/cache/npm"
fi

# Go environment (if installed)
if [ -d "/cache/go" ]; then
    export GOPATH="/cache/go"
    export PATH="${GOPATH}/bin:${PATH}"
fi
CRON_ENV_EOF

log_command "Setting cron-env permissions" \
    chmod 644 /etc/container/cron-env

# ============================================================================
# Daemon Startup Script
# ============================================================================
log_message "Creating cron daemon startup script..."

# Create startup directories if they don't exist
log_command "Creating container startup directories" \
    mkdir -p /etc/container/startup

# Create startup script (early number to start before jobs that need it)
command cat > /etc/container/startup/05-cron.sh << 'CRON_STARTUP_EOF'
#!/bin/bash
# Start cron daemon on container boot
#
# This script is idempotent - safe to run multiple times
# Note: cron daemon requires root privileges to start

# Check if cron is already running
if pgrep -x "cron" > /dev/null 2>&1; then
    echo "cron: Daemon already running"
    exit 0
fi

# Check if cron is installed
if ! command -v cron &> /dev/null; then
    echo "cron: Not installed, skipping"
    exit 0
fi

# Function to start cron daemon
start_cron() {
    if command -v service &> /dev/null; then
        service cron start > /dev/null 2>&1
    else
        cron
    fi
}

# Start the cron daemon - requires root privileges
if [ "$(id -u)" = "0" ]; then
    # Running as root, start directly
    start_cron
elif command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
    # Sudo available without password, use it
    sudo service cron start > /dev/null 2>&1 || sudo cron
else
    echo "cron: Cannot start daemon (requires root or passwordless sudo)"
    echo "cron: Enable with ENABLE_PASSWORDLESS_SUDO=true at build time"
    echo "cron: Or start manually with: sudo service cron start"
    exit 0
fi

# Verify it started
if pgrep -x "cron" > /dev/null 2>&1; then
    echo "cron: Daemon started successfully"
else
    echo "cron: Warning - daemon may not have started"
fi
CRON_STARTUP_EOF

log_command "Setting cron startup script permissions" \
    chmod +x /etc/container/startup/05-cron.sh

# ============================================================================
# Bashrc Configuration
# ============================================================================
log_message "Configuring cron shell helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide cron configuration
write_bashrc_content /etc/bashrc.d/10-cron.sh "Cron configuration" << 'CRON_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Cron Aliases and Functions
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
# Cron Aliases
# ----------------------------------------------------------------------------

# List user's crontab
alias cron-list='crontab -l 2>/dev/null || echo "No crontab for current user"'

# Edit user's crontab
alias cron-edit='crontab -e'

# List system cron jobs
alias cron-system='ls -la /etc/cron.d/ 2>/dev/null'

# Show cron daemon status
alias cron-status='pgrep -x cron > /dev/null && echo "cron: running" || echo "cron: not running"'

# ----------------------------------------------------------------------------
# cron-logs - View recent cron log entries
#
# Arguments:
#   $1 - Number of lines to show (default: 20)
# ----------------------------------------------------------------------------
cron-logs() {
    local lines="${1:-20}"
    if [ -f /var/log/syslog ]; then
        grep -i cron /var/log/syslog | tail -n "$lines"
    elif [ -f /var/log/cron.log ]; then
        tail -n "$lines" /var/log/cron.log
    else
        echo "No cron logs found"
        echo "Try: journalctl -u cron (if using systemd)"
    fi
}

# Note: We leave set +u and set +e in place for interactive shells
CRON_BASHRC_EOF

log_command "Setting cron bashrc script permissions" \
    chmod +x /etc/bashrc.d/10-cron.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating cron verification script..."

command cat > /usr/local/bin/test-cron << 'CRON_TEST_EOF'
#!/bin/bash
echo "=== Cron Status ==="

# Check if cron is installed
if command -v cron &> /dev/null; then
    echo "cron: Installed"
    echo "  Binary: $(which cron)"
else
    echo "cron: Not installed"
    exit 1
fi

# Check if crontab is available
if command -v crontab &> /dev/null; then
    echo "crontab: Available"
else
    echo "crontab: Not available"
fi

echo ""
echo "=== Daemon Status ==="
if pgrep -x "cron" > /dev/null 2>&1; then
    echo "cron daemon: Running (PID: $(pgrep -x cron))"
else
    echo "cron daemon: Not running"
    echo "  Start with: service cron start"
fi

echo ""
echo "=== Environment File ==="
if [ -f /etc/container/cron-env ]; then
    echo "cron-env: Present at /etc/container/cron-env"
else
    echo "cron-env: Not found"
fi

echo ""
echo "=== User Crontab ==="
if crontab -l &> /dev/null; then
    echo "Entries:"
    crontab -l | grep -v '^#' | grep -v '^$' || echo "  (no entries)"
else
    echo "No crontab for current user"
fi

echo ""
echo "=== System Cron Jobs (/etc/cron.d/) ==="
if [ -d /etc/cron.d ] && [ "$(ls -A /etc/cron.d 2>/dev/null)" ]; then
    ls -la /etc/cron.d/
else
    echo "  (no custom jobs)"
fi

echo ""
echo "=== Startup Script ==="
if [ -x /etc/container/startup/05-cron.sh ]; then
    echo "Startup script: Present and executable"
else
    echo "Startup script: Missing or not executable"
fi
CRON_TEST_EOF

log_command "Setting test-cron script permissions" \
    chmod +x /usr/local/bin/test-cron

# ============================================================================
# Feature Summary
# ============================================================================

log_feature_summary \
    --feature "Cron" \
    --tools "cron,crontab" \
    --paths "/etc/cron.d,/etc/container/cron-env" \
    --env "CRON_LOG_LEVEL" \
    --commands "crontab,cron-list,cron-status,cron-logs" \
    --next-steps "Run 'test-cron' to verify. Use 'cron-list' to view jobs. Cron jobs should source /etc/container/cron-env for container environment."

# End logging
log_feature_end
