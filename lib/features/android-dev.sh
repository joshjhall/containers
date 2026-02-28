#!/bin/bash
# Android Development Tools - Emulator, System Images, and Sources
#
# Description:
#   Installs Android development tools including the emulator, system images
#   for running virtual devices, and source code for debugging.
#
# Features:
#   - Android Emulator: Run Android virtual devices
#   - System Images: Google APIs system images for testing
#   - Android Sources: Source code for SDK debugging
#   - AVD creation helpers
#   - KVM support detection for hardware acceleration
#
# Tools Installed:
#   - emulator: Android emulator
#   - System images for configured API levels
#   - Source packages for debugging
#
# Environment Variables:
#   - ANDROID_API_LEVELS: API levels for system images (from android.sh)
#   - ANDROID_EMULATOR_USE_SYSTEM_LIBS: Use system libraries for emulator
#
# Prerequisites:
#   - Android SDK must be installed (INCLUDE_ANDROID=true)
#   - Java must be installed
#   - For hardware acceleration: KVM support on host
#
# Common Commands:
#   - emulator -list-avds: List available AVDs
#   - avd-create <name> <api>: Create new AVD
#   - avd-start <name>: Start an AVD
#   - emulator @<name>: Run emulator with AVD
#
# Note:
#   Emulator requires significant resources. For CI/CD, consider using
#   headless mode: emulator @avd -no-window -no-audio -no-boot-anim
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

# Source jdtls installation utilities
source /tmp/build-scripts/features/lib/install-jdtls.sh

# ============================================================================
# Configuration
# ============================================================================
# Get API levels from environment (set by android.sh or Dockerfile)
ANDROID_API_LEVELS="${ANDROID_API_LEVELS:-34,35}"

# Parse API levels into array
IFS=',' read -ra API_LEVELS_ARRAY <<< "$ANDROID_API_LEVELS"

# Start logging
log_feature_start "Android Dev Tools" "APIs=${ANDROID_API_LEVELS}"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check for Android SDK installation
if [ ! -d "/opt/android-sdk" ]; then
    log_error "Android SDK is required but not installed"
    log_error "Enable INCLUDE_ANDROID=true first"
    exit 1
fi

export ANDROID_HOME="/opt/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

if ! command -v sdkmanager &>/dev/null; then
    log_error "sdkmanager not found. Android SDK may not be installed correctly."
    exit 1
fi

log_message "Found Android SDK at ${ANDROID_HOME}"

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Android emulator..."

apt_update

# Emulator dependencies
apt_install \
    libpulse0 \
    libasound2 \
    libgl1 \
    libxcb1 \
    libx11-6 \
    libxext6 \
    libxrender1 \
    libxtst6 \
    libxi6 \
    libxrandr2 \
    libxfixes3 \
    libxcursor1 \
    libxcomposite1 \
    libxdamage1 \
    libxss1 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libnss3

# ============================================================================
# Architecture Detection
# ============================================================================
ARCH=$(dpkg --print-architecture)
log_message "Detected architecture: $ARCH"

SYSTEM_IMAGE_ABI=$(map_arch_or_skip "x86_64" "arm64-v8a")
if [ -n "$SYSTEM_IMAGE_ABI" ]; then
    EMULATOR_SUPPORTED=true
else
    log_warning "Emulator may not be fully supported on architecture: $ARCH"
    SYSTEM_IMAGE_ABI="x86_64"
    EMULATOR_SUPPORTED=false
fi

# ============================================================================
# Check KVM Support
# ============================================================================
log_message "Checking KVM support..."

KVM_AVAILABLE=false
if [ -e "/dev/kvm" ]; then
    log_message "KVM device found - hardware acceleration available"
    KVM_AVAILABLE=true
elif [ -w "/dev/kvm" ]; then
    log_message "KVM device is writable - hardware acceleration available"
    KVM_AVAILABLE=true
else
    log_warning "KVM not available - emulator will run without hardware acceleration"
    log_warning "For better performance, ensure KVM is enabled on the host"
fi

# ============================================================================
# Install Emulator
# ============================================================================
SDKMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"

if [ "$EMULATOR_SUPPORTED" = true ]; then
    log_message "Installing Android emulator..."
    # Use echo "y" instead of yes to avoid SIGPIPE with pipefail
    echo "y" | "$SDKMANAGER" --install "emulator" || {
        log_warning "Failed to install emulator package"
    }
else
    log_warning "Skipping emulator installation - not supported on $ARCH"
fi

# Export KVM status for runtime scripts
export ANDROID_KVM_AVAILABLE="$KVM_AVAILABLE"

# ============================================================================
# Install System Images and Sources
# ============================================================================
log_message "Installing system images and sources..."

for API_LEVEL in "${API_LEVELS_ARRAY[@]}"; do
    API_LEVEL=$(echo "$API_LEVEL" | command tr -d ' ')  # Trim whitespace

    log_message "Installing system image and sources for API ${API_LEVEL}..."

    # Install Google APIs system image
    # Use echo "y" instead of yes to avoid SIGPIPE with pipefail
    SYSTEM_IMAGE="system-images;android-${API_LEVEL};google_apis;${SYSTEM_IMAGE_ABI}"

    if echo "y" | "$SDKMANAGER" --install "$SYSTEM_IMAGE" 2>/dev/null; then
        log_message "Installed: $SYSTEM_IMAGE"
    else
        # Try Google APIs Playstore version
        SYSTEM_IMAGE="system-images;android-${API_LEVEL};google_apis_playstore;${SYSTEM_IMAGE_ABI}"
        if echo "y" | "$SDKMANAGER" --install "$SYSTEM_IMAGE" 2>/dev/null; then
            log_message "Installed: $SYSTEM_IMAGE"
        else
            # Try default system image
            SYSTEM_IMAGE="system-images;android-${API_LEVEL};default;${SYSTEM_IMAGE_ABI}"
            echo "y" | "$SDKMANAGER" --install "$SYSTEM_IMAGE" 2>/dev/null || \
                log_warning "Could not install system image for API ${API_LEVEL}"
        fi
    fi

    # Install sources for debugging
    echo "y" | "$SDKMANAGER" --install "sources;android-${API_LEVEL}" 2>/dev/null || \
        log_warning "Could not install sources for API ${API_LEVEL}"
done

# ============================================================================
# Install Additional Dev Tools
# ============================================================================
log_message "Installing additional development tools..."

# Use echo "y" instead of yes to avoid SIGPIPE with pipefail
# Android Debug Bridge extras
echo "y" | "$SDKMANAGER" --install "extras;google;usb_driver" 2>/dev/null || true

# Google Play services (for testing)
echo "y" | "$SDKMANAGER" --install "extras;google;google_play_services" 2>/dev/null || true

# Android Auto
echo "y" | "$SDKMANAGER" --install "extras;google;auto" 2>/dev/null || true

# ============================================================================
# Create Emulator Symlink
# ============================================================================
log_message "Creating emulator symlinks..."

if [ -f "${ANDROID_HOME}/emulator/emulator" ]; then
    create_symlink "${ANDROID_HOME}/emulator/emulator" \
        "/usr/local/bin/emulator" "Android emulator"
fi

# ============================================================================
# AVD Configuration
# ============================================================================
log_message "Configuring AVD directories..."

AVD_HOME="/cache/android-avd"
create_cache_directories "${AVD_HOME}"

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring Android dev environment..."

log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Android dev tools configuration (content in lib/bashrc/android-dev-config.sh)
write_bashrc_content /etc/bashrc.d/55-android-dev.sh "Android dev tools configuration" \
    < /tmp/build-scripts/features/lib/bashrc/android-dev-config.sh

log_command "Setting Android dev bashrc permissions" \
    chmod +x /etc/bashrc.d/55-android-dev.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Android dev aliases and helpers..."

# Android dev aliases and helpers (content in lib/bashrc/android-dev-aliases.sh)
write_bashrc_content /etc/bashrc.d/55-android-dev.sh "Android dev aliases and helpers" \
    < /tmp/build-scripts/features/lib/bashrc/android-dev-aliases.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating Android dev startup script..."

command cat > /etc/container/first-startup/31-android-dev-setup.sh << 'EOF'
#!/bin/bash
# Android development environment setup

# Create AVD directory if needed
mkdir -p "${ANDROID_AVD_HOME:-/cache/android-avd}"

# Check KVM availability
if [ -e "/dev/kvm" ]; then
    if [ -w "/dev/kvm" ]; then
        echo "KVM acceleration is available for Android emulator"
    else
        echo "Note: KVM exists but is not writable. Run container with --device /dev/kvm"
    fi
fi

# Show available system images
echo ""
echo "=== Installed System Images ==="
sdkmanager --list_installed 2>/dev/null | grep "system-images" | head -5 || echo "None installed"

echo ""
echo "Create an AVD with: avd-create <name> <api_level>"
echo "Start an AVD with:  avd-start <name>"
EOF

log_command "Setting Android dev startup script permissions" \
    chmod +x /etc/container/first-startup/31-android-dev-setup.sh

# ============================================================================
# Eclipse JDT Language Server (jdtls)
# ============================================================================
# Install jdtls for Java/Kotlin IDE support in Android projects
# This is installed idempotently - skipped if already present
log_message "Installing Eclipse JDT Language Server for Android development..."
install_jdtls
configure_jdtls_env

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating Android dev verification script..."

command cat > /usr/local/bin/test-android-dev << 'EOF'
#!/bin/bash
echo "=== Android Development Tools Status ==="

echo ""
echo "=== Emulator ==="
if command -v emulator &>/dev/null; then
    echo "✓ Emulator is installed"
    emulator -version 2>&1 | head -1 | command sed 's/^/  /'
else
    echo "✗ Emulator is not installed"
fi

echo ""
echo "=== KVM Acceleration ==="
if [ -e "/dev/kvm" ]; then
    if [ -w "/dev/kvm" ]; then
        echo "✓ KVM is available and writable"
    else
        echo "⚠ KVM exists but not writable"
        echo "  Run with: --device /dev/kvm"
    fi
else
    echo "✗ KVM is not available"
    echo "  Emulator will use software rendering (slower)"
fi

echo ""
echo "=== Available AVDs ==="
if emulator -list-avds 2>/dev/null | grep -q .; then
    emulator -list-avds 2>/dev/null | command sed 's/^/  /'
else
    echo "  No AVDs created"
    echo "  Create one with: avd-create <name> <api_level>"
fi

echo ""
echo "=== Installed System Images ==="
sdkmanager --list_installed 2>/dev/null | grep "system-images" | command sed 's/^/  /' || echo "  None found"

echo ""
echo "=== Installed Sources ==="
sdkmanager --list_installed 2>/dev/null | grep "sources" | command sed 's/^/  /' || echo "  None found"

echo ""
echo "=== Language Server ==="
if [ -d "/opt/jdtls" ]; then
    echo "✓ jdtls (Eclipse JDT Language Server) is installed"
    echo "  For Java/Kotlin IDE support in Android projects"
else
    echo "✗ jdtls is not installed"
fi

echo ""
echo "=== Helper Commands ==="
echo "  avd-create <name> <api>  - Create new AVD"
echo "  avd-start <name>         - Start AVD with GUI"
echo "  avd-start-headless <name>- Start AVD for CI"
echo "  avd-delete <name>        - Delete AVD"
echo "  adb-logcat [tag]         - View filtered logs"
echo "  android-dev-version      - Show all versions"

echo ""
echo "=== Directories ==="
echo "AVD Home: ${ANDROID_AVD_HOME:-/cache/android-avd}"
echo "Emulator Home: ${ANDROID_EMULATOR_HOME:-/cache/android-avd}"
EOF

log_command "Setting test-android-dev script permissions" \
    chmod +x /usr/local/bin/test-android-dev

# ============================================================================
# Fix Permissions
# ============================================================================
log_message "Setting Android dev permissions..."

log_command "Setting AVD directory ownership" \
    chown -R "${USER_UID}:${USER_GID}" "${AVD_HOME}" || true

# Ensure emulator directory is accessible
log_command "Setting emulator ownership" \
    chown -R "${USER_UID}:${USER_GID}" "${ANDROID_HOME}/emulator" 2>/dev/null || true

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying Android dev tools installation..."

if command -v emulator &>/dev/null; then
    log_command "Checking emulator" \
        emulator -version || log_warning "Emulator not working properly"
fi

# Log feature summary
log_feature_summary \
    --feature "Android Dev Tools" \
    --version "APIs=${ANDROID_API_LEVELS}" \
    --tools "emulator,avdmanager" \
    --paths "${AVD_HOME}" \
    --env "ANDROID_AVD_HOME,ANDROID_EMULATOR_HOME" \
    --commands "emulator,avd-create,avd-start,avd-start-headless,avd-delete,adb-logcat,android-dev-version" \
    --next-steps "Run 'test-android-dev' to verify. Create AVD with 'avd-create <name> <api>'. For CI, use 'avd-start-headless'."

# End logging
log_feature_end

echo ""
echo "Run 'test-android-dev' to verify Android dev tools installation"
echo "Run 'check-build-logs.sh android-dev' to review installation logs"
