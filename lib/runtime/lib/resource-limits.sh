#!/bin/bash
# Resource limit configuration for container startup
#
# Sets ulimit values to prevent resource exhaustion: file descriptors,
# max processes, and core dump size. All configurable via environment
# variables with sensible defaults.

# Prevent multiple sourcing
if [ -n "${_RESOURCE_LIMITS_LOADED:-}" ]; then
    return 0
fi
_RESOURCE_LIMITS_LOADED=1

# File descriptors (open files)
# Default 4096: 4x the typical Linux default (1024); accommodates dev tooling
# (LSP servers, file watchers, test runners) without being excessive
FILE_DESCRIPTOR_LIMIT="${FILE_DESCRIPTOR_LIMIT:-4096}"
ulimit -n "$FILE_DESCRIPTOR_LIMIT" 2>/dev/null || {
    echo "⚠️  Warning: Could not set file descriptor limit to $FILE_DESCRIPTOR_LIMIT"
    echo "   Current limit: $(ulimit -n 2>/dev/null || echo 'unknown')"
}

# Max user processes (prevent fork bombs)
# Default 2048: generous ceiling for dev containers; prevents accidental fork
# bombs while allowing parallel test runners and build tools
MAX_USER_PROCESSES="${MAX_USER_PROCESSES:-2048}"
ulimit -u "$MAX_USER_PROCESSES" 2>/dev/null || {
    echo "⚠️  Warning: Could not set max user processes limit to $MAX_USER_PROCESSES"
    echo "   Current limit: $(ulimit -u 2>/dev/null || echo 'unknown')"
}

# Core dump size (disabled by default for security)
CORE_DUMP_SIZE="${CORE_DUMP_SIZE:-0}"
ulimit -c "$CORE_DUMP_SIZE" 2>/dev/null || true
