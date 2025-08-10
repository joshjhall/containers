#!/bin/bash
# Set up startup script directories
set -euo pipefail

echo "=== Setting up startup script system ==="

# Create directories for startup scripts
mkdir -p /etc/container/first-startup
mkdir -p /etc/container/startup

# Make directories readable by all users
chmod 755 /etc/container
chmod 755 /etc/container/first-startup
chmod 755 /etc/container/startup

echo "=== Startup system configured ==="