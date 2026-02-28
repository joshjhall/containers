#!/bin/bash
# Android SDK - Command-line tools, Platform Tools, Build Tools, and NDK
#
# Description:
#   Installs the Android SDK for CI/CD builds and command-line development.
#   Includes essential tools for building Android applications without Android Studio.
#
# Features:
#   - Android SDK Command-line Tools: sdkmanager, avdmanager
#   - Android Platform Tools: adb, fastboot
#   - Android Build Tools: aapt, apksigner, zipalign, d8, etc.
#   - Android NDK: Native development kit for C/C++ code
#   - Pre-accepted licenses for CI/CD automation
#   - Multiple API level support
#   - Cache optimization for Gradle builds
#
# Tools Installed:
#   - sdkmanager: SDK package manager
#   - avdmanager: Android Virtual Device manager
#   - adb: Android Debug Bridge
#   - fastboot: Flash tool
#   - aapt/aapt2: Android Asset Packaging Tool
#   - apksigner: APK signing tool
#   - zipalign: APK alignment tool
#   - ndk-build: NDK build tool
#
# Environment Variables:
#   - ANDROID_CMDLINE_TOOLS_VERSION: Cmdline tools version (default: 11076708)
#   - ANDROID_API_LEVELS: Comma-separated API levels (default: 34,35)
#   - ANDROID_NDK_VERSION: NDK version (default: 27.2.12479018)
#   - ANDROID_HOME: SDK installation directory
#   - ANDROID_SDK_ROOT: Alias for ANDROID_HOME
#
# Prerequisites:
#   - Java must be installed (INCLUDE_JAVA=true or auto-triggered)
#
# Common Commands:
#   - sdkmanager --list: List available packages
#   - sdkmanager --list_installed: List installed packages
#   - adb devices: List connected devices
#   - ./gradlew assembleDebug: Build debug APK
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source cache utilities
source /tmp/build-scripts/base/cache-utils.sh

# Source path utilities for secure PATH management
source /tmp/build-scripts/base/path-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
# Android SDK Command-line Tools version (from https://developer.android.com/studio)
ANDROID_CMDLINE_TOOLS_VERSION="${ANDROID_CMDLINE_TOOLS_VERSION:-11076708}"

# API levels to install (comma-separated)
ANDROID_API_LEVELS="${ANDROID_API_LEVELS:-34,35}"

# NDK version
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-27.2.12479018}"

# Parse API levels into array
IFS=',' read -ra API_LEVELS_ARRAY <<< "$ANDROID_API_LEVELS"

# Start logging
log_feature_start "Android SDK" "cmdline-tools=${ANDROID_CMDLINE_TOOLS_VERSION}, APIs=${ANDROID_API_LEVELS}"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check for Java installation
if [ ! -f "/usr/lib/jvm/default-java/bin/java" ] && ! command -v java &>/dev/null; then
    log_error "Java is required but not installed"
    log_error "Enable INCLUDE_JAVA=true or INCLUDE_ANDROID=true triggers Java automatically"
    exit 1
fi

JAVA_VERSION_OUTPUT=$(java -version 2>&1 | command head -n 1)
log_message "Found Java: $JAVA_VERSION_OUTPUT"

# Ensure JAVA_HOME is set
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/default-java}"
log_message "JAVA_HOME: $JAVA_HOME"

# ============================================================================
# Architecture Detection
# ============================================================================
ARCH=$(dpkg --print-architecture)
log_message "Detected architecture: $ARCH"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Android SDK..."

apt_update

# Base dependencies (all architectures)
apt_install \
    wget \
    unzip \
    ca-certificates \
    libncurses5 \
    libbz2-1.0 \
    libncursesw6

# 32-bit libraries only needed on amd64 for some Android tools
if [ "$ARCH" = "amd64" ]; then
    log_message "Installing 32-bit libraries for amd64..."
    apt_install lib32stdc++6 lib32z1 || log_warning "Some 32-bit libraries may not be available"
fi

# ============================================================================
# Android SDK Installation
# ============================================================================
ANDROID_SDK_ROOT="/opt/android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_SDK_ROOT

log_message "Installing Android SDK to ${ANDROID_SDK_ROOT}..."

# Create SDK directories
log_command "Creating Android SDK directories" \
    mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools"

# Download command-line tools
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip"

BUILD_TEMP=$(create_secure_temp_dir)
cd "$BUILD_TEMP"

log_message "Downloading Android command-line tools..."
retry_with_backoff wget -q "${CMDLINE_TOOLS_URL}" -O cmdline-tools.zip || {
    log_error "Failed to download Android command-line tools"
    exit 1
}

log_command "Extracting command-line tools" \
    unzip -q cmdline-tools.zip

# Move to correct location (cmdline-tools/latest structure)
log_command "Installing command-line tools" \
    mv cmdline-tools "${ANDROID_SDK_ROOT}/cmdline-tools/latest"

# ============================================================================
# Pre-accept SDK Licenses
# ============================================================================
log_message "Pre-accepting Android SDK licenses..."

# Create licenses directory
mkdir -p "${ANDROID_SDK_ROOT}/licenses"

# Accept all standard licenses
# These are SHA1 hashes of the license texts
echo "24333f8a63b6825ea9c5514f83c2829b004d1fee" > "${ANDROID_SDK_ROOT}/licenses/android-sdk-license"
echo "84831b9409646a918e30573bab4c9c91346d8abd" >> "${ANDROID_SDK_ROOT}/licenses/android-sdk-license"
echo "d56f5187479451eabf01fb78af6dfcb131a6481e" >> "${ANDROID_SDK_ROOT}/licenses/android-sdk-license"

echo "84831b9409646a918e30573bab4c9c91346d8abd" > "${ANDROID_SDK_ROOT}/licenses/android-sdk-preview-license"

echo "33b6a2b64607f11b759f320ef9dff4ae5c47d97a" > "${ANDROID_SDK_ROOT}/licenses/google-gdk-license"

# Intel HAXM license
echo "d975f751698a77b662f1254ddbeed3901e976f5a" > "${ANDROID_SDK_ROOT}/licenses/intel-android-extra-license"

# Android NDK license
echo "8933bad161af4178b1185d1a37fbf41ea5269c55" > "${ANDROID_SDK_ROOT}/licenses/android-ndk-license"

log_message "SDK licenses accepted"

# ============================================================================
# Install SDK Components
# ============================================================================
SDKMANAGER="${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/sdkmanager"

# Ensure sdkmanager is executable
chmod +x "$SDKMANAGER"

log_message "Installing platform-tools..."
# Use echo "y" instead of yes to avoid SIGPIPE with pipefail
# Licenses are pre-accepted, so this is just a safety measure
echo "y" | "$SDKMANAGER" --install "platform-tools" || true

log_message "Installing SDK components for API levels: ${ANDROID_API_LEVELS}..."

for API_LEVEL in "${API_LEVELS_ARRAY[@]}"; do
    API_LEVEL=$(echo "$API_LEVEL" | command tr -d ' ')  # Trim whitespace

    log_message "Installing components for API level ${API_LEVEL}..."

    # Install platform (licenses pre-accepted, use echo for any prompts)
    echo "y" | "$SDKMANAGER" --install "platforms;android-${API_LEVEL}" || true

    # Install build-tools (use API level as minor version for build-tools)
    # Build tools versions follow pattern: API.0.0 for latest
    BUILD_TOOLS_VERSION="${API_LEVEL}.0.0"
    if echo "y" | "$SDKMANAGER" --install "build-tools;${BUILD_TOOLS_VERSION}" 2>/dev/null; then
        log_message "Installed build-tools;${BUILD_TOOLS_VERSION}"
    else
        # Try with .0.1 suffix as fallback
        BUILD_TOOLS_VERSION="${API_LEVEL}.0.1"
        echo "y" | "$SDKMANAGER" --install "build-tools;${BUILD_TOOLS_VERSION}" 2>/dev/null || \
            log_warning "Could not install build-tools for API ${API_LEVEL}"
    fi
done

# ============================================================================
# Install Android NDK
# ============================================================================
log_message "Installing Android NDK ${ANDROID_NDK_VERSION}..."

# Use echo "y" instead of yes to avoid SIGPIPE issues with pipefail
# NDK is large (~1.5GB), so this may take a while
if echo "y" | "$SDKMANAGER" --install "ndk;${ANDROID_NDK_VERSION}" 2>/dev/null; then
    export ANDROID_NDK_HOME="${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_VERSION}"
    log_message "NDK installed at ${ANDROID_NDK_HOME}"
else
    log_warning "Failed to install NDK ${ANDROID_NDK_VERSION}, trying without version..."
    # Try to install latest NDK
    LATEST_NDK=$("$SDKMANAGER" --list 2>/dev/null | command grep "ndk;" | command tail -1 | command awk '{print $1}')
    if [ -n "$LATEST_NDK" ]; then
        echo "y" | "$SDKMANAGER" --install "$LATEST_NDK" || log_warning "Could not install NDK"
    fi
fi

# Install CMake (commonly needed with NDK)
log_message "Installing CMake for NDK..."
echo "y" | "$SDKMANAGER" --install "cmake;3.22.1" 2>/dev/null || \
    log_warning "Could not install CMake"

# Clean up temp directory
cd /
rm -rf "$BUILD_TEMP"

# ============================================================================
# Create Symlinks
# ============================================================================
log_message "Creating Android SDK symlinks..."

# Main tools
for cmd in sdkmanager avdmanager; do
    if [ -f "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/${cmd}" ]; then
        create_symlink "${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin/${cmd}" \
            "/usr/local/bin/${cmd}" "${cmd} tool"
    fi
done

# Platform tools
for cmd in adb fastboot; do
    if [ -f "${ANDROID_SDK_ROOT}/platform-tools/${cmd}" ]; then
        create_symlink "${ANDROID_SDK_ROOT}/platform-tools/${cmd}" \
            "/usr/local/bin/${cmd}" "${cmd} tool"
    fi
done

# Find and link build-tools (use highest version available)
BUILD_TOOLS_DIR=$(command find "${ANDROID_SDK_ROOT}/build-tools/" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | command sort -V | command tail -1)
if [ -n "$BUILD_TOOLS_DIR" ] && [ -d "$BUILD_TOOLS_DIR" ]; then
    for cmd in aapt aapt2 apksigner zipalign d8 dexdump; do
        if [ -f "${BUILD_TOOLS_DIR}/${cmd}" ]; then
            create_symlink "${BUILD_TOOLS_DIR}/${cmd}" \
                "/usr/local/bin/${cmd}" "${cmd} tool"
        fi
    done
fi

# NDK tools
if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "${ANDROID_NDK_HOME}" ]; then
    if [ -f "${ANDROID_NDK_HOME}/ndk-build" ]; then
        create_symlink "${ANDROID_NDK_HOME}/ndk-build" \
            "/usr/local/bin/ndk-build" "NDK build tool"
    fi
fi

# ============================================================================
# Cache Configuration
# ============================================================================
log_message "Configuring Android cache directories..."

ANDROID_CACHE_DIR="/cache/android-sdk"
ANDROID_GRADLE_CACHE="/cache/android-gradle"

log_message "Android cache paths:"
log_message "  SDK Cache: ${ANDROID_CACHE_DIR}"
log_message "  Gradle Cache: ${ANDROID_GRADLE_CACHE}"

create_cache_directories "${ANDROID_CACHE_DIR}" "${ANDROID_GRADLE_CACHE}"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide Android environment..."

log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Android SDK environment configuration (content in lib/bashrc/android-env.sh)
write_bashrc_content /etc/bashrc.d/50-android.sh "Android SDK environment configuration" \
    < /tmp/build-scripts/features/lib/bashrc/android-env.sh

log_command "Setting Android bashrc permissions" \
    chmod +x /etc/bashrc.d/50-android.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Android aliases and helpers..."

# Android aliases and helpers (content in lib/bashrc/android-aliases.sh)
write_bashrc_content /etc/bashrc.d/50-android.sh "Android aliases and helpers" \
    < /tmp/build-scripts/features/lib/bashrc/android-aliases.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Android startup script..."

log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

install -m 755 /tmp/build-scripts/features/lib/android/30-android-setup.sh \
    /etc/container/first-startup/30-android-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Android verification script..."

install -m 755 /tmp/build-scripts/features/lib/android/test-android.sh \
    /usr/local/bin/test-android

# ============================================================================
# Fix Permissions
# ============================================================================
log_message "Setting Android SDK permissions..."

# Make SDK accessible to container user
log_command "Setting SDK ownership" \
    chown -R "${USER_UID}:${USER_GID}" "${ANDROID_SDK_ROOT}" || true

log_command "Setting cache ownership" \
    chown -R "${USER_UID}:${USER_GID}" "${ANDROID_CACHE_DIR}" "${ANDROID_GRADLE_CACHE}" || true

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Android SDK installation..."

log_command "Checking sdkmanager" \
    /usr/local/bin/sdkmanager --version || log_warning "sdkmanager not working properly"

log_command "Checking adb" \
    /usr/local/bin/adb version || log_warning "adb not working properly"

# Log feature summary
log_feature_summary \
    --feature "Android SDK" \
    --version "cmdline-tools=${ANDROID_CMDLINE_TOOLS_VERSION}, APIs=${ANDROID_API_LEVELS}, NDK=${ANDROID_NDK_VERSION}" \
    --tools "sdkmanager,avdmanager,adb,fastboot,aapt,apksigner,zipalign,ndk-build" \
    --paths "${ANDROID_SDK_ROOT},${ANDROID_CACHE_DIR},${ANDROID_GRADLE_CACHE}" \
    --env "ANDROID_HOME,ANDROID_SDK_ROOT,ANDROID_NDK_HOME" \
    --commands "sdkmanager,adb,android-version,android-install-api,gab,gar" \
    --next-steps "Run 'test-android' to verify installation. Use 'sdkmanager --list' to see available packages."

# End logging
log_feature_end

echo ""
echo "Run 'test-android' to verify Android SDK installation"
echo "Run 'check-build-logs.sh android' to review installation logs"
