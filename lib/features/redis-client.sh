#!/bin/bash
# Redis Client Tools - Command-line interface for Redis databases
#
# Description:
#   Installs Redis client tools for connecting to and managing Redis databases.
#   Includes redis-cli and other utilities for key-value store operations.
#
# Features:
#   - redis-cli: Interactive Redis command-line interface
#   - redis-benchmark: Performance testing tool
#   - redis-check-aof: AOF file repair utility
#   - redis-check-rdb: RDB file repair utility
#
# Tools Installed:
#   - redis-tools: Complete Redis client utilities package
#
# Common Usage:
#   - redis-cli -h hostname -p 6379
#   - redis-cli ping
#   - redis-cli --scan --pattern "prefix:*"
#   - redis-benchmark -h hostname -p 6379
#
# Environment Variables:
#   - REDISCLI_AUTH: Default authentication password
#   - REDISCLI_HISTFILE: History file location (default: ~/.rediscli_history)
#
# Note:
#   For production use, consider using redis-cli with --tls for secure connections.
#   Use CONFIG commands carefully as they can affect server performance.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Redis Client"

# ============================================================================
# Package Installation
# ============================================================================
log_message "Installing Redis client package..."

# Update package lists with retry logic
apt_update

# Install Redis client tools with retry logic
apt_install redis-tools

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring Redis environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide Redis configuration
write_bashrc_content /etc/bashrc.d/60-redis.sh "Redis client configuration" << 'REDIS_BASHRC_EOF'
# ----------------------------------------------------------------------------
# Redis Client Configuration and Helpers
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
# Redis Aliases - Common Redis operations
# ----------------------------------------------------------------------------
alias redis='redis-cli'
alias redis-local='redis-cli -h localhost'
alias redis-ping='redis-cli ping'
alias redis-info='redis-cli info'
alias redis-monitor='redis-cli monitor'
alias redis-keys='redis-cli --scan'

# ----------------------------------------------------------------------------
# redis-quick-connect - Connect to Redis with common defaults
#
# Arguments:
#   $1 - Host (default: localhost)
#   $2 - Port (default: 6379)
#   $3 - Database number (default: 0)
#
# Example:
#   redis-quick-connect redis.example.com 6380 1
# ----------------------------------------------------------------------------
redis-quick-connect() {
    local host="${1:-localhost}"
    local port="${2:-6379}"
    local db="${3:-0}"

    echo "Connecting to Redis at $host:$port (database $db)..."
    redis-cli -h "$host" -p "$port" -n "$db"
}

# ----------------------------------------------------------------------------
# redis-scan-keys - Scan for keys matching a pattern
#
# Arguments:
#   $1 - Pattern (required)
#   $2 - Host (default: localhost)
#
# Example:
#   redis-scan-keys "user:*"
#   redis-scan-keys "session:*" redis.example.com
# ----------------------------------------------------------------------------
redis-scan-keys() {
    if [ -z "$1" ]; then
        echo "Usage: redis-scan-keys <pattern> [host]"
        return 1
    fi

    local pattern="$1"
    local host="${2:-localhost}"

    echo "Scanning for keys matching '$pattern' on $host..."
    redis-cli -h "$host" --scan --pattern "$pattern"
}

# ----------------------------------------------------------------------------
# redis-backup - Create a backup of Redis data
#
# Arguments:
#   $1 - Output file (default: redis_backup_timestamp.rdb)
#   $2 - Host (default: localhost)
#
# Example:
#   redis-backup
#   redis-backup mybackup.rdb redis.example.com
# ----------------------------------------------------------------------------
redis-backup() {
    local output="${1:-redis_backup_$(date +%Y%m%d_%H%M%S).rdb}"
    local host="${2:-localhost}"

    echo "Creating Redis backup from $host to $output..."
    redis-cli -h "$host" --rdb "$output" && echo "Backup complete: $output"
}

# ----------------------------------------------------------------------------
# redis-load-test - Run a simple load test
#
# Arguments:
#   $1 - Number of requests (default: 10000)
#   $2 - Host (default: localhost)
#
# Example:
#   redis-load-test 50000
#   redis-load-test 100000 redis.example.com
# ----------------------------------------------------------------------------
redis-load-test() {
    local requests="${1:-10000}"
    local host="${2:-localhost}"

    echo "Running load test with $requests requests against $host..."
    redis-benchmark -h "$host" -n "$requests" -q
}

# Redis CLI customization
export REDISCLI_HISTFILE="${HOME}/.rediscli_history"


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
REDIS_BASHRC_EOF

log_command "Setting Redis bashrc script permissions" \
    chmod +x /etc/bashrc.d/60-redis.sh

# ============================================================================
# Connection Templates
# ============================================================================
log_message "Creating connection configuration templates..."

# Create connection template
log_command "Creating .redisclirc template" \
    bash -c "command cat > /etc/skel/.rediscli.template << 'EOF'
# Redis CLI configuration template
# Copy to ~/.redisclirc and uncomment/modify as needed
#
# Default connection settings:
# host 127.0.0.1
# port 6379
# auth yourpassword
# dbnum 0
#
# TLS/SSL settings:
# tls
# cacert /path/to/ca.crt
# cert /path/to/redis.crt
# key /path/to/redis.key
#
# Output formatting:
# raw  # Raw output mode
# csv  # CSV output mode
EOF"

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Redis startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/20-redis-setup.sh << 'EOF'
#!/bin/bash
# Redis client configuration
if [ ! -f ~/.redisclirc ] && [ -f ~/.rediscli.template ]; then
    echo "=== Redis Client Configuration ==="
    echo "Template .redisclirc file created at ~/.rediscli.template"
    echo "Copy and edit it to ~/.redisclirc for connection defaults"
fi

# Check for Redis environment variables
if [ -n "${REDIS_HOST}${REDIS_PORT}${REDIS_AUTH}" ]; then
    echo "Redis environment detected:"
    [ -n "$REDIS_HOST" ] && echo "  Host: $REDIS_HOST"
    [ -n "$REDIS_PORT" ] && echo "  Port: $REDIS_PORT"
    [ -n "$REDIS_AUTH" ] && echo "  Auth: [configured]"
fi

# Test Redis connectivity if host is configured
if [ -n "${REDIS_HOST}" ]; then
    echo "Testing Redis connection to ${REDIS_HOST}..."
    if redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" ping &>/dev/null; then
        echo "Redis connection successful!"
    else
        echo "Redis connection failed. Check your configuration."
    fi
fi
EOF

log_command "Setting Redis startup script permissions" \
    chmod +x /etc/container/first-startup/20-redis-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Redis verification script..."

command cat > /usr/local/bin/test-redis << 'EOF'
#!/bin/bash
echo "=== Redis Client Status ==="
if command -v redis-cli &> /dev/null; then
    echo "✓ Redis client is installed"
    echo "  Version: $(redis-cli --version)"
    echo "  Binary: $(which redis-cli)"
else
    echo "✗ Redis client is not installed"
    exit 1
fi

echo ""
echo "=== Available Tools ==="
for cmd in redis-cli redis-benchmark redis-check-aof redis-check-rdb; do
    if command -v $cmd &> /dev/null; then
        echo "✓ $cmd is available"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Environment Variables ==="
echo "  REDIS_HOST: ${REDIS_HOST:-[not set]}"
echo "  REDIS_PORT: ${REDIS_PORT:-[not set]}"
echo "  REDISCLI_AUTH: ${REDISCLI_AUTH:+[configured]}"
echo "  REDISCLI_HISTFILE: ${REDISCLI_HISTFILE:-~/.rediscli_history}"

if [ -f ~/.redisclirc ]; then
    echo "  ✓ .redisclirc file exists"
else
    echo "  ✗ .redisclirc file not found"
fi
EOF

log_command "Setting test-redis script permissions" \
    chmod +x /usr/local/bin/test-redis

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Redis client installation..."

log_command "Checking redis-cli version" \
    redis-cli --version || log_warning "Redis client not installed properly"

# Log feature summary
log_feature_summary \
    --feature "Redis Client" \
    --tools "redis-cli,redis-benchmark" \
    --paths "$HOME/.rediscli_history" \
    --env "REDIS_HOST,REDIS_PORT,REDIS_PASSWORD" \
    --commands "redis-cli,redis-benchmark,redis-quick-connect,redis-monitor,redis-flush,redis-info" \
    --next-steps "Run 'test-redis' to verify installation. Connect with 'redis-cli -h <host>' or use 'redis-quick-connect <host>'. Use 'redis-monitor' for real-time monitoring."

# End logging
log_feature_end

echo ""
echo "Run 'test-redis' to verify installation"
echo "Run 'check-build-logs.sh redis-client' to review installation logs"
