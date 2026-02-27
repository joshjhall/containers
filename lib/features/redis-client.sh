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

# Create system-wide Redis configuration (content in lib/bashrc/redis-client.sh)
write_bashrc_content /etc/bashrc.d/60-redis.sh "Redis client configuration" \
    < /tmp/build-scripts/features/lib/bashrc/redis-client.sh

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
