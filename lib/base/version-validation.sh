#!/bin/bash
# Version Validation Utilities
#
# Description:
#   Provides validation functions for version number formats to prevent
#   shell injection attacks via malicious version strings in build arguments.
#
# Security:
#   Validates that version strings contain only numbers and dots in expected
#   formats before they are used in URLs, file paths, or shell commands.
#
# Usage:
#   source /tmp/build-scripts/base/version-validation.sh
#   validate_semver "$PYTHON_VERSION" "PYTHON_VERSION" || exit 1
#

# Source logging utilities if available
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# Validate strict semantic version format (X.Y.Z)
# Used for: Python, Rust, Ruby, Java, Mojo
#
# Args:
#   $1: version string to validate
#   $2: variable name for error messages (optional, default: "VERSION")
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_semver "3.13.5" "PYTHON_VERSION" || exit 1
validate_semver() {
    local version="$1"
    local variable_name="${2:-VERSION}"

    if [ -z "$version" ]; then
        log_error "Empty $variable_name provided"
        return 1
    fi

    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid $variable_name format: $version"
        log_error "Expected format: X.Y.Z (e.g., 3.13.5)"
        log_error "Only digits and dots allowed, no other characters"
        return 1
    fi

    return 0
}

# Validate version with optional patch (X.Y or X.Y.Z)
# Used for: Node.js, Go
#
# Args:
#   $1: version string to validate
#   $2: variable name for error messages (optional, default: "VERSION")
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_version_flexible "20.18" "NODE_VERSION" || exit 1
#   validate_version_flexible "1.23.5" "GO_VERSION" || exit 1
validate_version_flexible() {
    local version="$1"
    local variable_name="${2:-VERSION}"

    if [ -z "$version" ]; then
        log_error "Empty $variable_name provided"
        return 1
    fi

    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Invalid $variable_name format: $version"
        log_error "Expected format: X.Y or X.Y.Z (e.g., 20.18 or 1.23.5)"
        log_error "Only digits and dots allowed, no other characters"
        return 1
    fi

    return 0
}

# Validate R version format (X.Y.Z)
# R uses semantic versioning like Python
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_r_version "4.4.0" || exit 1
validate_r_version() {
    validate_semver "$1" "R_VERSION"
}

# Validate Go version format (X.Y or X.Y.Z)
# Go typically uses X.Y but sometimes X.Y.Z for patches
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_go_version "1.23" || exit 1
#   validate_go_version "1.23.5" || exit 1
validate_go_version() {
    validate_version_flexible "$1" "GO_VERSION"
}

# Validate Node.js version format (X, X.Y or X.Y.Z)
# Node.js can use major version only or full version
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_node_version "22" || exit 1
#   validate_node_version "20.18" || exit 1
#   validate_node_version "20.18.1" || exit 1
validate_node_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Empty NODE_VERSION provided"
        return 1
    fi

    # Allow single number (22) or X.Y or X.Y.Z format
    if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+(\.[0-9]+)?)?$ ]]; then
        log_error "Invalid NODE_VERSION format: $version"
        log_error "Expected format: X, X.Y, or X.Y.Z (e.g., 22, 20.18, or 20.18.1)"
        log_error "Only digits and dots allowed, no other characters"
        return 1
    fi

    return 0
}

# Validate Python version format (X.Y.Z)
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_python_version "3.13.5" || exit 1
validate_python_version() {
    validate_semver "$1" "PYTHON_VERSION"
}

# Validate Rust version format (X.Y.Z)
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_rust_version "1.82.0" || exit 1
validate_rust_version() {
    validate_semver "$1" "RUST_VERSION"
}

# Validate Ruby version format (X.Y.Z)
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_ruby_version "3.3.6" || exit 1
validate_ruby_version() {
    validate_semver "$1" "RUBY_VERSION"
}

# Validate Java version format (flexible for different distributions)
# Java versions can be: 8, 11, 17, 21, or 1.8, 11.0.1, etc.
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_java_version "21" || exit 1
#   validate_java_version "11.0.21" || exit 1
validate_java_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Empty JAVA_VERSION provided"
        return 1
    fi

    # Allow single number (8, 11, 17, 21) or X.Y.Z format
    if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+(\.[0-9]+)?)?$ ]]; then
        log_error "Invalid JAVA_VERSION format: $version"
        log_error "Expected format: X, X.Y, or X.Y.Z (e.g., 21, 11.0, or 11.0.21)"
        log_error "Only digits and dots allowed, no other characters"
        return 1
    fi

    return 0
}

# Validate Mojo version format (X.Y.Z)
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_mojo_version "24.5.0" || exit 1
validate_mojo_version() {
    validate_semver "$1" "MOJO_VERSION"
}

# Validate Kotlin version format (X.Y.Z)
# Kotlin uses semantic versioning
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_kotlin_version "2.1.0" || exit 1
validate_kotlin_version() {
    validate_semver "$1" "KOTLIN_VERSION"
}

# Validate Android API level format (integer)
# API levels are simple integers like 34, 35
#
# Args:
#   $1: API level to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_android_api_level "35" || exit 1
validate_android_api_level() {
    local level="$1"

    if [ -z "$level" ]; then
        log_error "Empty ANDROID_API_LEVEL provided"
        return 1
    fi

    if ! [[ "$level" =~ ^[0-9]+$ ]]; then
        log_error "Invalid ANDROID_API_LEVEL format: $level"
        log_error "Expected format: integer (e.g., 34, 35)"
        return 1
    fi

    return 0
}

# Validate Android cmdline-tools version format (integer)
# Cmdline tools versions are integers like 11076708
#
# Args:
#   $1: version to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_android_cmdline_tools_version "11076708" || exit 1
validate_android_cmdline_tools_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Empty ANDROID_CMDLINE_TOOLS_VERSION provided"
        return 1
    fi

    if ! [[ "$version" =~ ^[0-9]+$ ]]; then
        log_error "Invalid ANDROID_CMDLINE_TOOLS_VERSION format: $version"
        log_error "Expected format: integer (e.g., 11076708)"
        return 1
    fi

    return 0
}

# Validate Android NDK version format (X.Y.Z or X.Y.ZZZZZZZ)
# NDK versions can be like 27.2.12479018
#
# Args:
#   $1: version to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_android_ndk_version "27.2.12479018" || exit 1
validate_android_ndk_version() {
    local version="$1"

    if [ -z "$version" ]; then
        log_error "Empty ANDROID_NDK_VERSION provided"
        return 1
    fi

    # NDK uses X.Y.ZZZZZZZ format
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid ANDROID_NDK_VERSION format: $version"
        log_error "Expected format: X.Y.Z (e.g., 27.2.12479018)"
        return 1
    fi

    return 0
}

# Validate ktlint version format (X.Y.Z)
# ktlint uses semantic versioning
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_ktlint_version "1.5.0" || exit 1
validate_ktlint_version() {
    validate_semver "$1" "KTLINT_VERSION"
}

# Validate detekt version format (X.Y.Z)
# detekt uses semantic versioning
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_detekt_version "1.23.7" || exit 1
validate_detekt_version() {
    validate_semver "$1" "DETEKT_VERSION"
}

# Validate kotlin-language-server version format (X.Y.Z)
# KLS uses semantic versioning
#
# Args:
#   $1: version string to validate
#
# Returns:
#   0 if valid, 1 if invalid
#
# Example:
#   validate_kls_version "1.3.12" || exit 1
validate_kls_version() {
    validate_semver "$1" "KLS_VERSION"
}
