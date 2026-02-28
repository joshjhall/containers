#!/bin/bash
# Android SDK environment setup

# Check for Android projects
if [ -f ${WORKING_DIR}/build.gradle ] || [ -f ${WORKING_DIR}/build.gradle.kts ]; then
    if grep -q "android" ${WORKING_DIR}/build.gradle* 2>/dev/null; then
        echo "=== Android Project Detected ==="
        echo "Android project found. Common commands:"
        echo "  ./gradlew assembleDebug     - Build debug APK"
        echo "  ./gradlew assembleRelease   - Build release APK"
        echo "  ./gradlew test              - Run unit tests"
        echo "  ./gradlew lint              - Run lint checks"
        echo ""
        echo "APKs will be in: app/build/outputs/apk/"
    fi
fi

# Show Android environment
android-version 2>/dev/null || {
    echo "Android SDK: ${ANDROID_HOME:-/opt/android-sdk}"
    sdkmanager --list_installed 2>/dev/null | command head -10 || true
}
