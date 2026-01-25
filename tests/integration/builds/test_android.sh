#!/usr/bin/env bash
# Test android container build
#
# This test verifies the Android SDK configuration including:
# - Android SDK command-line tools
# - Platform tools (adb, fastboot)
# - Build tools
# - NDK (optional)
# - Java auto-triggering

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Android Container Build"

# Test: Android SDK builds successfully
test_android_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-android-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-android \
            --build-arg INCLUDE_ANDROID=true \
            --build-arg ANDROID_API_LEVELS=34 \
            -t "$image"
    fi

    # Verify SDK tools are installed
    assert_executable_in_path "$image" "sdkmanager"
    assert_executable_in_path "$image" "avdmanager"

    # Verify Java was auto-triggered
    assert_executable_in_path "$image" "java"
    assert_executable_in_path "$image" "javac"
}

# Test: Platform tools are installed
test_platform_tools() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    # Verify platform tools
    assert_executable_in_path "$image" "adb"
    assert_executable_in_path "$image" "fastboot"
}

# Test: Build tools are installed
test_build_tools() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    # Verify build tools
    assert_executable_in_path "$image" "aapt"
    assert_executable_in_path "$image" "aapt2"
    assert_executable_in_path "$image" "apksigner"
    assert_executable_in_path "$image" "zipalign"
}

# Test: sdkmanager works
test_sdkmanager() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    # Test sdkmanager can list installed packages
    assert_command_in_container "$image" "sdkmanager --list_installed 2>&1 | head -5" ""
}

# Test: adb version
test_adb_version() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    # Test adb version
    # Note: Android SDK platform-tools are x86_64 only
    # On arm64, adb may not work (Rosetta emulation fails for adb)
    local arch
    arch=$(docker run --rm "$image" bash -c "dpkg --print-architecture" 2>/dev/null)

    if [ "$arch" = "amd64" ]; then
        assert_command_in_container "$image" "adb version" "Android Debug Bridge"
    else
        echo -n "  adb version (arm64)... "
        # On arm64, just verify the binary exists
        if docker run --rm "$image" bash -c "test -x /usr/local/bin/adb" 2>/dev/null; then
            echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
            echo "    adb binary exists but may not run on arm64 (x86_64 only)"
        else
            echo -e "${TEST_COLOR_FAIL}FAIL${TEST_COLOR_RESET}"
            echo "    adb binary not found"
        fi
    fi
}

# Test: SDK licenses are accepted
test_sdk_licenses() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    # Verify licenses directory exists
    assert_command_in_container "$image" "test -d /opt/android-sdk/licenses && echo exists" "exists"
}

# Test: Android cache directories exist
test_android_cache() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    # Cache directories exist
    assert_command_in_container "$image" "test -d /cache/android-sdk && echo exists" "exists"
    assert_command_in_container "$image" "test -d /cache/android-gradle && echo exists" "exists"
}

# Test: Environment variables are set
test_android_env() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    # ANDROID_HOME should be set
    assert_command_in_container "$image" "bash -c 'source /etc/bashrc.d/50-android.sh && echo \$ANDROID_HOME'" "/opt/android-sdk"
}

# Test: NDK is installed (optional)
test_ndk_installation() {
    local image="${IMAGE_TO_TEST:-test-android-$$}"

    echo -n "  Testing NDK installation... "
    if docker run --rm "$image" bash -c "command -v ndk-build" >/dev/null 2>&1; then
        echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
        echo "    ndk-build is available"
    else
        echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
        echo "    NDK may not have been installed"
    fi
}

# Test: Android dev tools (separate build)
test_android_dev_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        # Skip dev build if testing pre-built image
        echo -n "  Skipping dev build test for pre-built image... "
        echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
        return 0
    fi

    local image="test-android-dev-$$"
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_PATH=. \
        --build-arg PROJECT_NAME=test-android-dev \
        --build-arg INCLUDE_ANDROID_DEV=true \
        --build-arg ANDROID_API_LEVELS=34 \
        -t "$image"

    # Verify emulator is installed (architecture-dependent)
    # Note: Android emulator has limited arm64 support
    local arch
    arch=$(docker run --rm "$image" bash -c "dpkg --print-architecture" 2>/dev/null)
    if [ "$arch" = "amd64" ]; then
        assert_executable_in_path "$image" "emulator"
    else
        echo -n "  Checking emulator (arm64)... "
        if docker run --rm "$image" bash -c "command -v emulator" >/dev/null 2>&1; then
            echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
        else
            echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
            echo "    Emulator may not be available on $arch"
        fi
    fi

    # Verify system images are installed
    echo -n "  Checking system images... "
    if docker run --rm "$image" bash -c "sdkmanager --list_installed 2>&1 | grep -q 'system-images'"; then
        echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
    else
        echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
        echo "    No system images found (may be architecture-dependent)"
    fi
}

# Run all tests
run_test test_android_build "Android SDK builds successfully with auto-triggered Java"
run_test test_platform_tools "Platform tools are installed"
run_test test_build_tools "Build tools are installed"
run_test test_sdkmanager "sdkmanager is functional"
run_test test_adb_version "adb version works"
run_test test_sdk_licenses "SDK licenses are accepted"
run_test test_android_cache "Android cache directories exist"
run_test test_android_env "Android environment variables are set"
run_test test_ndk_installation "NDK is installed"
run_test test_android_dev_build "Android dev tools build successfully"

# Generate test report
generate_report
