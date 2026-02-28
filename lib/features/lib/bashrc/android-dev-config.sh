# ----------------------------------------------------------------------------
# Android Development Tools Configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u
set +e

if [[ $- != *i* ]]; then
    return 0
fi

# Source base utilities
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Add emulator to PATH
if [ -d "${ANDROID_HOME:-/opt/android-sdk}/emulator" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "${ANDROID_HOME:-/opt/android-sdk}/emulator" 2>/dev/null || \
            export PATH="${ANDROID_HOME:-/opt/android-sdk}/emulator:$PATH"
    else
        export PATH="${ANDROID_HOME:-/opt/android-sdk}/emulator:$PATH"
    fi
fi

# AVD home directory
export ANDROID_AVD_HOME="/cache/android-avd"
export ANDROID_EMULATOR_HOME="/cache/android-avd"

# Emulator settings for container/headless use
export ANDROID_EMULATOR_USE_SYSTEM_LIBS=1

# KVM acceleration (if available)
if [ -e "/dev/kvm" ] && [ -w "/dev/kvm" ]; then
    export ANDROID_EMULATOR_KVM=1
fi
