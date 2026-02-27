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

# Prevent multiple sourcing
if [ -n "${_VERSION_RESOLUTION_LOADED:-}" ]; then
    return 0
fi
_VERSION_RESOLUTION_LOADED=1

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

# _resolve_version_from_api - Common version resolution from API data
#
# Encapsulates the shared algorithm: full-version early return, API fetch,
# grep -oP extraction, optional sed cleanup, sort -V, and export.
#
# Arguments:
#   $1 - Language name for error messages (e.g., "Python")
#   $2 - Version string to resolve
#   $3 - API URL to fetch version data from
#   $4 - grep -oP pattern for major.minor (X.Y) matching
#   $5 - sed expression for major.minor cleanup (empty to skip)
#   $6 - grep -oP pattern for major-only (X) matching
#   $7 - sed expression for major-only cleanup (empty to skip)
#   $8 - Export variable name (e.g., "PYTHON_RESOLVED_VERSION")
_resolve_version_from_api() {
    local language="$1"
    local version="$2"
    local api_url="$3"
    local mm_grep="$4"
    local mm_sed="$5"
    local mo_grep="$6"
    local mo_sed="$7"
    local export_var="$8"

    if _is_full_version "$version"; then
        echo "$version"
        return 0
    fi

    local api_data
    api_data=$(_curl_safe "$api_url" 2>/dev/null || echo "")

    if [ -z "$api_data" ]; then
        log_error "Failed to fetch $language version list"
        return 1
    fi

    local resolved="" grep_pattern="" sed_expr=""

    if _is_major_minor "$version"; then
        grep_pattern="$mm_grep"
        sed_expr="$mm_sed"
    elif _is_major_only "$version"; then
        grep_pattern="$mo_grep"
        sed_expr="$mo_sed"
    fi

    if [ -n "$grep_pattern" ]; then
        resolved=$(echo "$api_data" | grep -oP "$grep_pattern" || true)
        if [ -n "$sed_expr" ]; then
            resolved=$(echo "$resolved" | command sed "$sed_expr")
        fi
        resolved=$(echo "$resolved" | sort -V | tail -1)
    fi

    if [ -n "$resolved" ]; then
        export "$export_var=$resolved"
        echo "$resolved"
        return 0
    fi

    log_error "Failed to resolve $language version: $version"
    return 1
}

# ============================================================================
# Python Version Resolution
# ============================================================================

# resolve_python_version - Resolve partial Python version to full version
#   "3.12" -> "3.12.8", "3" -> "3.13.1", "3.12.7" -> "3.12.7"
# Exports: PYTHON_RESOLVED_VERSION
resolve_python_version() {
    _resolve_version_from_api "Python" "$1" \
        "https://www.python.org/ftp/python/" \
        '>'"$1"'\.\d+/' \
        's/>//; s/\///' \
        '>'"$1"'\.\d+\.\d+/' \
        's/>//; s/\///' \
        "PYTHON_RESOLVED_VERSION"
}

# ============================================================================
# Node.js Version Resolution
# ============================================================================

# resolve_node_version - Resolve partial Node.js version to full version
#   "20.18" -> "20.18.3", "20" -> "20.18.3", "20.18.0" -> "20.18.0"
# Exports: NODE_RESOLVED_VERSION
resolve_node_version() {
    _resolve_version_from_api "Node.js" "$1" \
        "https://nodejs.org/dist/index.json" \
        '"version":"v\K'"$1"'\.\d+' \
        "" \
        '"version":"v\K'"$1"'\.\d+\.\d+' \
        "" \
        "NODE_RESOLVED_VERSION"
}

# ============================================================================
# Rust Version Resolution
# ============================================================================

# resolve_rust_version - Resolve partial Rust version to full version
#   "1.82" -> "1.82.0", "1" -> "1.84.0", "1.82.0" -> "1.82.0"
# Exports: RUST_RESOLVED_VERSION
resolve_rust_version() {
    _resolve_version_from_api "Rust" "$1" \
        "https://api.github.com/repos/rust-lang/rust/releases?per_page=100" \
        '"tag_name":\s*"'"$1"'\.\d+"' \
        's/"tag_name":\s*"//; s/"$//' \
        '"tag_name":\s*"'"$1"'\.\d+\.\d+"' \
        's/"tag_name":\s*"//; s/"$//' \
        "RUST_RESOLVED_VERSION"
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
#   "3.4" -> "3.4.7", "3" -> "3.4.7", "3.4.7" -> "3.4.7"
# Exports: RUBY_RESOLVED_VERSION
resolve_ruby_version() {
    _resolve_version_from_api "Ruby" "$1" \
        "https://www.ruby-lang.org/en/downloads/releases/" \
        "Ruby $1\.\d+" \
        's/Ruby //' \
        "Ruby $1\.\d+\.\d+" \
        's/Ruby //' \
        "RUBY_RESOLVED_VERSION"
}

# ============================================================================
# Go Version Resolution
# ============================================================================

# resolve_go_version - Resolve partial Go version to full version
#   "1.23" -> "1.23.5", "1" -> "1.23.5", "1.23.5" -> "1.23.5"
# Exports: GO_RESOLVED_VERSION
#
# Note: Pre-release versions (rc, beta, alpha) are excluded by the grep
# patterns requiring numeric segments after dots (e.g., \.\d+), which
# naturally rejects formats like "go1.24rc1".
resolve_go_version() {
    _resolve_version_from_api "Go" "$1" \
        "https://go.dev/dl/?mode=json&include=all" \
        '"version":\s*"go'"$1"'\.\d+"' \
        's/.*"go//; s/"$//' \
        '"version":\s*"go'"$1"'\.\d+\.\d+"' \
        's/.*"go//; s/"$//' \
        "GO_RESOLVED_VERSION"
}

# ============================================================================
# Kotlin Version Resolution
# ============================================================================

# resolve_kotlin_version - Resolve partial Kotlin version to full version
#   "2.1" -> "2.1.0", "2" -> "2.1.0", "2.1.0" -> "2.1.0"
# Exports: KOTLIN_RESOLVED_VERSION
resolve_kotlin_version() {
    _resolve_version_from_api "Kotlin" "$1" \
        "https://api.github.com/repos/JetBrains/kotlin/releases?per_page=100" \
        '"tag_name":\s*"v'"$1"'\.\d+"' \
        's/"tag_name":\s*"v//; s/"$//' \
        '"tag_name":\s*"v'"$1"'\.\d+\.\d+"' \
        's/"tag_name":\s*"v//; s/"$//' \
        "KOTLIN_RESOLVED_VERSION"
}

# ============================================================================
# Wrapper Function for All Languages
# ============================================================================

# resolve_version - Generic version resolver that delegates to language-specific functions
#
# Arguments:
#   $1 - Language (python, node, rust, ruby, java, go, kotlin)
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
        kotlin)
            resolve_kotlin_version "$version"
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
export -f resolve_kotlin_version
export -f resolve_version
