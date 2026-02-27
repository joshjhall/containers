
# ----------------------------------------------------------------------------
# Android Aliases
# ----------------------------------------------------------------------------
alias sdk='sdkmanager'
alias sdklist='sdkmanager --list'
alias sdkinstalled='sdkmanager --list_installed'
alias sdkupdate='sdkmanager --update'

# ADB shortcuts
alias adbdevices='adb devices -l'
alias adbrestart='adb kill-server && adb start-server'
alias adblog='adb logcat'
alias adblogclear='adb logcat -c'

# ----------------------------------------------------------------------------
# android-version - Show Android SDK version information
# ----------------------------------------------------------------------------
android-version() {
    echo "=== Android SDK Environment ==="
    echo "ANDROID_HOME: ${ANDROID_HOME:-not set}"
    echo "ANDROID_SDK_ROOT: ${ANDROID_SDK_ROOT:-not set}"

    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        echo "ANDROID_NDK_HOME: ${ANDROID_NDK_HOME}"
    fi

    echo ""
    echo "=== Installed Components ==="
    if command -v sdkmanager &>/dev/null; then
        sdkmanager --list_installed 2>/dev/null | head -20
        echo "..."
        echo "(Run 'sdkmanager --list_installed' for full list)"
    fi

    echo ""
    echo "=== Build Tools ==="
    ls -1 "${ANDROID_HOME:-/opt/android-sdk}/build-tools/" 2>/dev/null || echo "None installed"

    echo ""
    echo "=== Platform Tools ==="
    if command -v adb &>/dev/null; then
        adb version 2>&1 | head -1
    fi
}

# ----------------------------------------------------------------------------
# android-install-api - Install components for a specific API level
#
# Arguments:
#   $1 - API level (required)
# ----------------------------------------------------------------------------
android-install-api() {
    if [ -z "$1" ]; then
        echo "Usage: android-install-api <api_level>"
        echo "Example: android-install-api 35"
        return 1
    fi

    local api="$1"
    echo "Installing Android SDK components for API level $api..."

    yes | sdkmanager --install \
        "platforms;android-$api" \
        "build-tools;$api.0.0" \
        "sources;android-$api" 2>/dev/null || \
        echo "Some components may not be available"
}

# ----------------------------------------------------------------------------
# adb-install - Install APK on connected device
#
# Arguments:
#   $1 - APK file path (required)
# ----------------------------------------------------------------------------
adb-install() {
    if [ -z "$1" ]; then
        echo "Usage: adb-install <apk_file>"
        return 1
    fi

    if [ ! -f "$1" ]; then
        echo "APK file not found: $1"
        return 1
    fi

    echo "Installing $1..."
    adb install -r "$1"
}

# ----------------------------------------------------------------------------
# adb-screenshot - Take screenshot from connected device
#
# Arguments:
#   $1 - Output file name (optional, defaults to screenshot_TIMESTAMP.png)
# ----------------------------------------------------------------------------
adb-screenshot() {
    local output="${1:-screenshot_$(date +%Y%m%d_%H%M%S).png}"
    adb exec-out screencap -p > "$output"
    echo "Screenshot saved to: $output"
}

# ----------------------------------------------------------------------------
# gradle-android - Common Gradle Android build commands
# ----------------------------------------------------------------------------
alias gab='./gradlew assembleDebug'
alias gar='./gradlew assembleRelease'
alias gtest='./gradlew test'
alias gclean='./gradlew clean'
alias glint='./gradlew lint'
