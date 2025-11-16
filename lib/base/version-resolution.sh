#!/bin/bash
# Version Resolution System
#
# Provides standardized version resolution for all languages.
# Supports partial versions like "3.12" or "20" and resolves to latest patch.
#
# Usage:
#   source /tmp/build-scripts/base/version-resolution.sh
#   resolved=$(resolve_python_version "3.12")  # Returns "3.12.7"
#   echo "$PYTHON_RESOLVED_VERSION"            # Exported variable

set -euo pipefail

# Source logging utilities
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# ============================================================================
# Internal Helper Functions
# ============================================================================

# _curl_safe - Wrapper for curl with standard timeouts
_curl_safe() {
    command curl --connect-timeout 10 --max-time 30 -fsSL "$@"
}

# _is_full_version - Check if version is complete (X.Y.Z)
_is_full_version() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# _is_major_minor - Check if version is major.minor (X.Y)
_is_major_minor() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]
}

# _is_major_only - Check if version is just major (X)
_is_major_only() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+$ ]]
}

# ============================================================================
# Python Version Resolution
# ============================================================================

# resolve_python_version - Resolve partial Python version to full version
#
# Arguments:
#   $1 - Python version (e.g., "3", "3.12", "3.12.7")
#
# Returns:
#   Full version string (e.g., "3.12.7")
#
# Exports:
#   PYTHON_RESOLVED_VERSION - The resolved version if partial
#
# Supports:
#   "3.12.7" -> "3.12.7" (no change)
#   "3.12" -> "3.12.8" (latest patch)
#   "3" -> "3.13.1" (latest stable)
#
# Example:
#   resolved=$(resolve_python_version "3.12")
#   if [ -n "$PYTHON_RESOLVED_VERSION" ]; then
#       log_message "Resolved Python 3.12 -> $PYTHON_RESOLVED_VERSION"
#   fi
resolve_python_version() {
    local version="$1"

    # If already full version, return as-is
    if _is_full_version "$version"; then
        echo "$version"
        return 0
    fi

    # Try to fetch from python.org FTP directory listing
    local python_ftp="https://www.python.org/ftp/python/"
    local versions_page
    versions_page=$(_curl_safe "$python_ftp" 2>/dev/null || echo "")

    if [ -z "$versions_page" ]; then
        log_error "Failed to fetch Python version list from python.org"
        return 1
    fi

    local resolved

    if _is_major_minor "$version"; then
        # Major.minor like "3.12" -> find latest "3.12.X"
        resolved=$(echo "$versions_page" | \
            grep -oP ">${version}\.\d+/" | \
            command sed 's/>//; s/\///' | \
            sort -V | \
            tail -1)
    elif _is_major_only "$version"; then
        # Major only like "3" -> find latest "3.X.Y"
        resolved=$(echo "$versions_page" | \
            grep -oP ">${version}\.\d+\.\d+/" | \
            command sed 's/>//; s/\///' | \
            sort -V | \
            tail -1)
    fi

    if [ -n "$resolved" ]; then
        export PYTHON_RESOLVED_VERSION="$resolved"
        echo "$resolved"
        return 0
    fi

    log_error "Failed to resolve Python version: $version"
    return 1
}

# ============================================================================
# Node.js Version Resolution
# ============================================================================

# resolve_node_version - Resolve partial Node.js version to full version
#
# Arguments:
#   $1 - Node version (e.g., "20", "20.18", "20.18.0")
#
# Returns:
#   Full version string (e.g., "20.18.0")
#
# Exports:
#   NODE_RESOLVED_VERSION - The resolved version if partial
#
# Supports:
#   "20.18.0" -> "20.18.0" (no change)
#   "20.18" -> "20.18.3" (latest patch)
#   "20" -> "20.18.3" (latest minor+patch)
#
# Example:
#   resolved=$(resolve_node_version "20")
resolve_node_version() {
    local version="$1"

    # If already full version, return as-is
    if _is_full_version "$version"; then
        echo "$version"
        return 0
    fi

    # Fetch Node.js version index
    local index_url="https://nodejs.org/dist/index.json"
    local versions_json
    versions_json=$(_curl_safe "$index_url" 2>/dev/null || echo "")

    if [ -z "$versions_json" ]; then
        log_error "Failed to fetch Node.js version list"
        return 1
    fi

    local resolved

    if _is_major_minor "$version"; then
        # Major.minor like "20.18" -> find latest "20.18.X"
        resolved=$(echo "$versions_json" | \
            grep -oP '"version":"v\K'"${version}"'\.\d+' | \
            sort -V | \
            tail -1)
    elif _is_major_only "$version"; then
        # Major only like "20" -> find latest "20.X.Y"
        resolved=$(echo "$versions_json" | \
            grep -oP '"version":"v\K'"${version}"'\.\d+\.\d+' | \
            sort -V | \
            tail -1)
    fi

    if [ -n "$resolved" ]; then
        export NODE_RESOLVED_VERSION="$resolved"
        echo "$resolved"
        return 0
    fi

    log_error "Failed to resolve Node.js version: $version"
    return 1
}

# ============================================================================
# Rust Version Resolution
# ============================================================================

# resolve_rust_version - Resolve partial Rust version to full version
#
# Arguments:
#   $1 - Rust version (e.g., "1", "1.82", "1.82.0")
#
# Returns:
#   Full version string (e.g., "1.82.0")
#
# Exports:
#   RUST_RESOLVED_VERSION - The resolved version if partial
#
# Supports:
#   "1.82.0" -> "1.82.0" (no change)
#   "1.82" -> "1.82.0" (latest patch)
#   "1" -> "1.84.0" (latest stable)
#
# Example:
#   resolved=$(resolve_rust_version "1.82")
resolve_rust_version() {
    local version="$1"

    # If already full version, return as-is
    if _is_full_version "$version"; then
        echo "$version"
        return 0
    fi

    # Fetch Rust versions from GitHub releases
    local releases_url="https://api.github.com/repos/rust-lang/rust/releases?per_page=100"
    local releases_json
    releases_json=$(_curl_safe "$releases_url" 2>/dev/null || echo "")

    if [ -z "$releases_json" ]; then
        log_error "Failed to fetch Rust version list"
        return 1
    fi

    local resolved

    if _is_major_minor "$version"; then
        # Major.minor like "1.82" -> find latest "1.82.X"
        # Format in JSON: "tag_name": "1.82.0",
        resolved=$(echo "$releases_json" | \
            grep -oP '"tag_name":\s*"'"${version}"'\.\d+"' | \
            command sed 's/"tag_name":\s*"//; s/"$//' | \
            sort -V | \
            tail -1)
    elif _is_major_only "$version"; then
        # Major only like "1" -> find latest "1.X.Y"
        resolved=$(echo "$releases_json" | \
            grep -oP '"tag_name":\s*"'"${version}"'\.\d+\.\d+"' | \
            command sed 's/"tag_name":\s*"//; s/"$//' | \
            sort -V | \
            tail -1)
    fi

    if [ -n "$resolved" ]; then
        export RUST_RESOLVED_VERSION="$resolved"
        echo "$resolved"
        return 0
    fi

    log_error "Failed to resolve Rust version: $version"
    return 1
}

# ============================================================================
# Java Version Resolution
# ============================================================================

# resolve_java_version - Resolve partial Java version to full version
#
# Arguments:
#   $1 - Java version (e.g., "21", "21.0", "21.0.1")
#
# Returns:
#   Full version string (e.g., "21.0.1")
#
# Exports:
#   JAVA_RESOLVED_VERSION - The resolved version if partial
#
# Supports:
#   "21.0.1" -> "21.0.1" (no change)
#   "21.0" -> "21.0.5" (latest patch)
#   "21" -> "21.0.5" (latest minor+patch)
#
# Example:
#   resolved=$(resolve_java_version "21")
resolve_java_version() {
    local version="$1"

    # If already full version, return as-is
    if _is_full_version "$version"; then
        echo "$version"
        return 0
    fi

    # Fetch from Adoptium API
    local api_url="https://api.adoptium.net/v3/assets/feature_releases/${version}/ga"
    local versions_json
    versions_json=$(_curl_safe "$api_url" 2>/dev/null || echo "")

    if [ -z "$versions_json" ]; then
        log_error "Failed to fetch Java version list"
        return 1
    fi

    local resolved

    # Extract version_data.semver and find latest
    resolved=$(echo "$versions_json" | \
        grep '"semver"' | \
        command sed 's/.*"semver": "//; s/".*//' | \
        command sed 's/+.*//' | \
        grep "^${version}" | \
        sort -V | \
        tail -1)

    if [ -n "$resolved" ]; then
        export JAVA_RESOLVED_VERSION="$resolved"
        echo "$resolved"
        return 0
    fi

    log_error "Failed to resolve Java version: $version"
    return 1
}

# ============================================================================
# Ruby Version Resolution
# ============================================================================

# resolve_ruby_version - Resolve partial Ruby version to full version
#
# Arguments:
#   $1 - Ruby version (e.g., "3", "3.4", "3.4.7")
#
# Returns:
#   Full version string (e.g., "3.4.7")
#
# Exports:
#   RUBY_RESOLVED_VERSION - The resolved version if partial
#
# Supports:
#   "3.4.7" -> "3.4.7" (no change)
#   "3.4" -> "3.4.7" (latest patch)
#   "3" -> "3.4.7" (latest stable)
#
# Example:
#   resolved=$(resolve_ruby_version "3.4")
resolve_ruby_version() {
    local version="$1"

    # If already full version, return as-is
    if _is_full_version "$version"; then
        echo "$version"
        return 0
    fi

    # Fetch Ruby releases from ruby-lang.org downloads page
    local downloads_url="https://www.ruby-lang.org/en/downloads/releases/"
    local releases_page
    releases_page=$(_curl_safe "$downloads_url" 2>/dev/null || echo "")

    if [ -z "$releases_page" ]; then
        log_error "Failed to fetch Ruby version list from ruby-lang.org"
        return 1
    fi

    local resolved

    if _is_major_minor "$version"; then
        # Major.minor like "3.4" -> find latest "3.4.X"
        resolved=$(echo "$releases_page" | \
            grep -oP "Ruby ${version}\.\d+" | \
            command sed 's/Ruby //' | \
            sort -V | \
            tail -1)
    elif _is_major_only "$version"; then
        # Major only like "3" -> find latest "3.X.Y"
        resolved=$(echo "$releases_page" | \
            grep -oP "Ruby ${version}\.\d+\.\d+" | \
            command sed 's/Ruby //' | \
            sort -V | \
            tail -1)
    fi

    if [ -n "$resolved" ]; then
        export RUBY_RESOLVED_VERSION="$resolved"
        echo "$resolved"
        return 0
    fi

    log_error "Failed to resolve Ruby version: $version"
    return 1
}

# ============================================================================
# Go Version Resolution
# ============================================================================

# resolve_go_version - Resolve partial Go version to full version
#
# Arguments:
#   $1 - Go version (e.g., "1", "1.23", "1.23.5")
#
# Returns:
#   Full version string (e.g., "1.23.5")
#
# Exports:
#   GO_RESOLVED_VERSION - The resolved version if partial
#
# Supports:
#   "1.23.5" -> "1.23.5" (no change)
#   "1.23" -> "1.23.5" (latest patch)
#   "1" -> "1.23.5" (latest stable)
#
# Example:
#   resolved=$(resolve_go_version "1.23")
resolve_go_version() {
    local version="$1"

    # If already full version, return as-is
    if _is_full_version "$version"; then
        echo "$version"
        return 0
    fi

    # Fetch Go version list from go.dev
    local versions_url="https://go.dev/dl/?mode=json&include=all"
    local versions_json
    versions_json=$(_curl_safe "$versions_url" 2>/dev/null || echo "")

    if [ -z "$versions_json" ]; then
        log_error "Failed to fetch Go version list from go.dev"
        return 1
    fi

    local resolved

    if _is_major_minor "$version"; then
        # Major.minor like "1.23" -> find latest "1.23.X"
        resolved=$(echo "$versions_json" | \
            grep '"version"' | \
            command sed 's/.*"version": "go//; s/".*//' | \
            grep "^${version}\." | \
            sort -V | \
            tail -1)
    elif _is_major_only "$version"; then
        # Major only like "1" -> find latest "1.X.Y"
        resolved=$(echo "$versions_json" | \
            grep '"version"' | \
            command sed 's/.*"version": "go//; s/".*//' | \
            grep "^${version}\." | \
            sort -V | \
            tail -1)
    fi

    if [ -n "$resolved" ]; then
        export GO_RESOLVED_VERSION="$resolved"
        echo "$resolved"
        return 0
    fi

    log_error "Failed to resolve Go version: $version"
    return 1
}

# ============================================================================
# Wrapper Function for All Languages
# ============================================================================

# resolve_version - Generic version resolver that delegates to language-specific functions
#
# Arguments:
#   $1 - Language (python, node, rust, ruby, java, go)
#   $2 - Version string
#
# Returns:
#   Resolved version string
#
# Example:
#   resolved=$(resolve_version "python" "3.12")
resolve_version() {
    local language="$1"
    local version="$2"

    case "$language" in
        python)
            resolve_python_version "$version"
            ;;
        node|nodejs)
            resolve_node_version "$version"
            ;;
        rust)
            resolve_rust_version "$version"
            ;;
        java)
            resolve_java_version "$version"
            ;;
        ruby)
            resolve_ruby_version "$version"
            ;;
        go|golang)
            resolve_go_version "$version"
            ;;
        *)
            log_error "Unknown language for version resolution: $language"
            echo "$version"
            return 1
            ;;
    esac
}

# Export functions for use in feature scripts
export -f resolve_python_version
export -f resolve_node_version
export -f resolve_rust_version
export -f resolve_java_version
export -f resolve_ruby_version
export -f resolve_go_version
export -f resolve_version
