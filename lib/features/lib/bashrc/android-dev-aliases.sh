
# ----------------------------------------------------------------------------
# Android Development Aliases
# ----------------------------------------------------------------------------
alias avdlist='emulator -list-avds'
alias emulator-list='emulator -list-avds'

# ----------------------------------------------------------------------------
# avd-create - Create a new Android Virtual Device
#
# Arguments:
#   $1 - AVD name (required)
#   $2 - API level (optional, defaults to highest installed)
#   $3 - Device type (optional, defaults to pixel_6)
#
# Example:
#   avd-create test-avd 34
#   avd-create pixel-test 35 pixel_6
# ----------------------------------------------------------------------------
avd-create() {
    if [ -z "$1" ]; then
        echo "Usage: avd-create <name> [api_level] [device]"
        echo ""
        echo "Available system images:"
        sdkmanager --list_installed 2>/dev/null | grep "system-images" || echo "  None found"
        return 1
    fi

    local name="$1"
    local api="${2:-35}"
    local device="${3:-pixel_6}"

    # Determine ABI based on architecture
    local abi
    case "$(uname -m)" in
        x86_64) abi="x86_64" ;;
        aarch64) abi="arm64-v8a" ;;
        *) abi="x86_64" ;;
    esac

    # Find available system image
    local image=""
    for variant in "google_apis" "google_apis_playstore" "default"; do
        image="system-images;android-${api};${variant};${abi}"
        if sdkmanager --list_installed 2>/dev/null | grep -q "$image"; then
            break
        fi
        image=""
    done

    if [ -z "$image" ]; then
        echo "No system image found for API ${api} with ABI ${abi}"
        echo "Install one with: sdkmanager --install 'system-images;android-${api};google_apis;${abi}'"
        return 1
    fi

    echo "Creating AVD: $name"
    echo "  API Level: $api"
    echo "  Device: $device"
    echo "  System Image: $image"

    echo "no" | avdmanager create avd \
        --name "$name" \
        --package "$image" \
        --device "$device" \
        --force

    echo ""
    echo "AVD created. Start with: avd-start $name"
}

# ----------------------------------------------------------------------------
# avd-start - Start an Android Virtual Device
#
# Arguments:
#   $1 - AVD name (required)
#   $2 - Additional emulator options (optional)
#
# Example:
#   avd-start test-avd
#   avd-start test-avd "-no-window -no-audio"
# ----------------------------------------------------------------------------
avd-start() {
    if [ -z "$1" ]; then
        echo "Usage: avd-start <avd_name> [options]"
        echo ""
        echo "Available AVDs:"
        emulator -list-avds
        return 1
    fi

    local name="$1"
    shift
    local options="$*"

    echo "Starting AVD: $name"

    # Check for KVM
    if [ -e "/dev/kvm" ] && [ -w "/dev/kvm" ]; then
        echo "Using KVM acceleration"
    else
        echo "Warning: KVM not available, emulator will be slower"
        options="$options -no-accel"
    fi

    # Start emulator
    emulator "@${name}" $options &

    echo "Emulator starting in background"
    echo "Use 'adb devices' to check when device is ready"
}

# ----------------------------------------------------------------------------
# avd-start-headless - Start AVD in headless mode (for CI)
#
# Arguments:
#   $1 - AVD name (required)
# ----------------------------------------------------------------------------
avd-start-headless() {
    if [ -z "$1" ]; then
        echo "Usage: avd-start-headless <avd_name>"
        return 1
    fi

    local name="$1"
    echo "Starting AVD in headless mode: $name"

    emulator "@${name}" \
        -no-window \
        -no-audio \
        -no-boot-anim \
        -gpu swiftshader_indirect \
        -no-snapshot \
        &

    echo "Headless emulator starting..."
    echo "Waiting for device to boot..."

    # Wait for device to be ready
    adb wait-for-device

    # Wait for boot completion
    local boot_complete=""
    local retries=0
    while [ "$boot_complete" != "1" ] && [ $retries -lt 120 ]; do
        boot_complete=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        sleep 2
        retries=$((retries + 1))
    done

    if [ "$boot_complete" = "1" ]; then
        echo "Device booted successfully"
    else
        echo "Warning: Device may not have fully booted"
    fi
}

# ----------------------------------------------------------------------------
# avd-delete - Delete an Android Virtual Device
#
# Arguments:
#   $1 - AVD name (required)
# ----------------------------------------------------------------------------
avd-delete() {
    if [ -z "$1" ]; then
        echo "Usage: avd-delete <avd_name>"
        echo ""
        echo "Available AVDs:"
        emulator -list-avds
        return 1
    fi

    local name="$1"
    echo "Deleting AVD: $name"
    avdmanager delete avd --name "$name"
}

# ----------------------------------------------------------------------------
# adb-logcat - Show filtered logcat output
#
# Arguments:
#   $1 - Tag filter (optional)
#   $2 - Priority (optional, default: I for Info)
# ----------------------------------------------------------------------------
adb-logcat() {
    local tag="${1:-*}"
    local priority="${2:-I}"

    echo "Showing logcat for tag '$tag' at priority '$priority'"
    echo "Press Ctrl+C to stop"
    adb logcat "${tag}:${priority}" "*:S"
}

# ----------------------------------------------------------------------------
# android-dev-version - Show development tools versions
# ----------------------------------------------------------------------------
android-dev-version() {
    echo "=== Android Development Tools ==="

    echo ""
    echo "Emulator:"
    if command -v emulator &>/dev/null; then
        emulator -version 2>&1 | head -3
    else
        echo "  Not installed"
    fi

    echo ""
    echo "Available AVDs:"
    emulator -list-avds 2>/dev/null || echo "  None created"

    echo ""
    echo "Installed System Images:"
    sdkmanager --list_installed 2>/dev/null | grep "system-images" || echo "  None"

    echo ""
    echo "KVM Status:"
    if [ -e "/dev/kvm" ]; then
        if [ -w "/dev/kvm" ]; then
            echo "  Available and writable (hardware acceleration enabled)"
        else
            echo "  Available but not writable (run with --device /dev/kvm)"
        fi
    else
        echo "  Not available (emulator will use software rendering)"
    fi

    echo ""
    echo "AVD Home: ${ANDROID_AVD_HOME:-/cache/android-avd}"
}
