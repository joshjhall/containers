#!/bin/bash
# Architecture mapping utilities
#
# Maps dpkg architecture names to tool-specific architecture identifiers.
# Supports amd64 and arm64 architectures.
#
# Functions provided:
#   map_arch          - Map architecture, error on unsupported
#   map_arch_or_skip  - Map architecture, return empty on unsupported
#
# This is a sub-module of feature-header.sh — source feature-header.sh
# instead of this file directly to get the full feature header system.

# Prevent multiple sourcing
if [ -n "${_ARCH_UTILS_LOADED:-}" ]; then
    return 0
fi
_ARCH_UTILS_LOADED=1

# Map dpkg architecture to tool-specific name (exits on unsupported arch)
# Usage: NODE_ARCH=$(map_arch "x64" "arm64")
map_arch() {
    local amd64_val="$1"
    local arm64_val="$2"
    local arch
    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64) echo "$amd64_val" ;;
        arm64) echo "$arm64_val" ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
}

# Map dpkg architecture, returning empty string for unsupported (skip pattern)
# Usage: TOOL_ARCH=$(map_arch_or_skip "x86_64" "arm64")
map_arch_or_skip() {
    local amd64_val="$1"
    local arm64_val="$2"
    local arch
    arch=$(dpkg --print-architecture)
    case "$arch" in
        amd64) echo "$amd64_val" ;;
        arm64) echo "$arm64_val" ;;
        *) echo "" ;;
    esac
}
