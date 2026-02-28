#!/bin/bash
echo "=== Android SDK Installation Status ==="

echo ""
echo "=== SDK Location ==="
echo "ANDROID_HOME: ${ANDROID_HOME:-/opt/android-sdk}"
echo "ANDROID_SDK_ROOT: ${ANDROID_SDK_ROOT:-not set}"
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    echo "ANDROID_NDK_HOME: ${ANDROID_NDK_HOME}"
fi

echo ""
echo "=== Command-line Tools ==="
for cmd in sdkmanager avdmanager; do
    if command -v $cmd &>/dev/null; then
        echo "✓ $cmd is available"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Platform Tools ==="
for cmd in adb fastboot; do
    if command -v $cmd &>/dev/null; then
        echo "✓ $cmd is available"
        case $cmd in
            adb) adb version 2>&1 | command head -1 | command sed 's/^/  /' ;;
        esac
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Build Tools ==="
for cmd in aapt aapt2 apksigner zipalign d8; do
    if command -v $cmd &>/dev/null; then
        echo "✓ $cmd is available"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== NDK Tools ==="
for cmd in ndk-build cmake; do
    if command -v $cmd &>/dev/null; then
        echo "✓ $cmd is available"
    else
        echo "- $cmd not installed (optional)"
    fi
done

echo ""
echo "=== Installed Platforms ==="
command ls -1 "${ANDROID_HOME:-/opt/android-sdk}/platforms/" 2>/dev/null || echo "None found"

echo ""
echo "=== Installed Build Tools ==="
command ls -1 "${ANDROID_HOME:-/opt/android-sdk}/build-tools/" 2>/dev/null || echo "None found"

echo ""
echo "=== Licenses ==="
if [ -d "${ANDROID_HOME:-/opt/android-sdk}/licenses" ]; then
    echo "✓ SDK licenses are accepted"
else
    echo "✗ SDK licenses directory not found"
fi

echo ""
echo "=== Cache Directories ==="
echo "SDK Cache: /cache/android-sdk"
echo "Gradle Cache: /cache/android-gradle"
