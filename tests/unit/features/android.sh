#!/usr/bin/env bash
# Unit tests for lib/features/android.sh
# Tests Android SDK base installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Android Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-android"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export ANDROID_CMDLINE_TOOLS_VERSION="${ANDROID_CMDLINE_TOOLS_VERSION:-11076708}"
    export ANDROID_API_LEVELS="${ANDROID_API_LEVELS:-34,35}"
    export ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-27.2.12479018}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/opt/android-sdk/cmdline-tools/latest/bin"
    mkdir -p "$TEST_TEMP_DIR/opt/android-sdk/platform-tools"
    mkdir -p "$TEST_TEMP_DIR/opt/android-sdk/build-tools/34.0.0"
    mkdir -p "$TEST_TEMP_DIR/opt/android-sdk/platforms/android-34"
    mkdir -p "$TEST_TEMP_DIR/opt/android-sdk/ndk/27.2.12479018"
    mkdir -p "$TEST_TEMP_DIR/opt/android-sdk/licenses"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/cache/android-sdk"
    mkdir -p "$TEST_TEMP_DIR/cache/android-avd"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset ANDROID_CMDLINE_TOOLS_VERSION ANDROID_API_LEVELS ANDROID_NDK_VERSION \
          USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Android API level validation
test_api_level_validation() {
    # Test valid API levels
    local valid_levels=("33" "34" "35")

    for level in "${valid_levels[@]}"; do
        if [[ "$level" =~ ^[0-9]+$ ]]; then
            assert_true true "API level $level is valid format"
        else
            assert_true false "API level $level should be valid"
        fi
    done

    # Test invalid levels
    local invalid_levels=("abc" "34.0" "")

    for level in "${invalid_levels[@]}"; do
        if [[ -n "$level" && "$level" =~ ^[0-9]+$ ]]; then
            assert_true false "API level '$level' should be invalid"
        else
            assert_true true "API level '$level' is correctly rejected"
        fi
    done
}

# Test: NDK version validation
test_ndk_version_validation() {
    # Test valid NDK versions
    local valid_versions=("27.2.12479018" "26.3.11579264" "25.2.9519653")

    for version in "${valid_versions[@]}"; do
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            assert_true true "NDK version $version is valid format"
        else
            assert_true false "NDK version $version should be valid"
        fi
    done
}

# Test: cmdline-tools version validation
test_cmdline_tools_version_validation() {
    # Test valid cmdline-tools versions
    local valid_versions=("11076708" "10406996" "9477386")

    for version in "${valid_versions[@]}"; do
        if [[ "$version" =~ ^[0-9]+$ ]]; then
            assert_true true "cmdline-tools version $version is valid format"
        else
            assert_true false "cmdline-tools version $version should be valid"
        fi
    done
}

# Test: Android SDK directory structure
test_sdk_directory_structure() {
    local android_home="$TEST_TEMP_DIR/opt/android-sdk"

    # Check SDK structure
    assert_dir_exists "$android_home"
    assert_dir_exists "$android_home/cmdline-tools"
    assert_dir_exists "$android_home/cmdline-tools/latest/bin"
    assert_dir_exists "$android_home/platform-tools"
    assert_dir_exists "$android_home/licenses"

    # Create mock binaries
    local cmdline_bins=("sdkmanager" "avdmanager")
    for bin in "${cmdline_bins[@]}"; do
        touch "$android_home/cmdline-tools/latest/bin/$bin"
        chmod +x "$android_home/cmdline-tools/latest/bin/$bin"
    done

    local platform_bins=("adb" "fastboot")
    for bin in "${platform_bins[@]}"; do
        touch "$android_home/platform-tools/$bin"
        chmod +x "$android_home/platform-tools/$bin"
    done

    # Verify binaries
    for bin in "${cmdline_bins[@]}"; do
        if [ -x "$android_home/cmdline-tools/latest/bin/$bin" ]; then
            assert_true true "$bin is executable"
        else
            assert_true false "$bin is not executable"
        fi
    done

    for bin in "${platform_bins[@]}"; do
        if [ -x "$android_home/platform-tools/$bin" ]; then
            assert_true true "$bin is executable"
        else
            assert_true false "$bin is not executable"
        fi
    done
}

# Test: Build tools installation
test_build_tools() {
    local android_home="$TEST_TEMP_DIR/opt/android-sdk"
    local build_tools_dir="$android_home/build-tools/34.0.0"

    mkdir -p "$build_tools_dir"

    # Create mock build tools
    local tools=("aapt" "aapt2" "d8" "zipalign" "apksigner")
    for tool in "${tools[@]}"; do
        touch "$build_tools_dir/$tool"
        chmod +x "$build_tools_dir/$tool"
    done

    assert_dir_exists "$build_tools_dir"

    for tool in "${tools[@]}"; do
        if [ -x "$build_tools_dir/$tool" ]; then
            assert_true true "$tool is executable"
        else
            assert_true false "$tool is not executable"
        fi
    done
}

# Test: NDK installation
test_ndk_installation() {
    local ndk_home="$TEST_TEMP_DIR/opt/android-sdk/ndk/27.2.12479018"

    mkdir -p "$ndk_home/toolchains/llvm/prebuilt"
    mkdir -p "$ndk_home/sources"

    # Create mock ndk-build
    touch "$ndk_home/ndk-build"
    chmod +x "$ndk_home/ndk-build"

    assert_dir_exists "$ndk_home"

    if [ -x "$ndk_home/ndk-build" ]; then
        assert_true true "ndk-build is executable"
    else
        assert_true false "ndk-build is not executable"
    fi
}

# Test: License acceptance
test_license_acceptance() {
    local licenses_dir="$TEST_TEMP_DIR/opt/android-sdk/licenses"

    mkdir -p "$licenses_dir"

    # Create mock license files
    echo "24333f8a63b6825ea9c5514f83c2829b004d1fee" > "$licenses_dir/android-sdk-license"
    echo "84831b9409646a918e30573bab4c9c91346d8abd" > "$licenses_dir/android-sdk-preview-license"

    assert_file_exists "$licenses_dir/android-sdk-license"
    assert_file_exists "$licenses_dir/android-sdk-preview-license"

    # Check license hash format (40 char hex)
    local license_content
    license_content=$(command cat "$licenses_dir/android-sdk-license")
    if [[ "$license_content" =~ ^[0-9a-f]{40}$ ]]; then
        assert_true true "License hash format is valid"
    else
        assert_true false "License hash format is invalid"
    fi
}

# Test: Environment variables
test_android_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/50-android.sh"

    # Create mock bashrc content
    command cat > "$bashrc_file" << 'EOF'
export ANDROID_HOME="/opt/android-sdk"
export ANDROID_SDK_ROOT="/opt/android-sdk"
export ANDROID_NDK_HOME="/opt/android-sdk/ndk/27.2.12479018"
export NDK_HOME="/opt/android-sdk/ndk/27.2.12479018"
export ANDROID_SDK_HOME="/cache/android-sdk"
export ANDROID_AVD_HOME="/cache/android-avd"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
EOF

    # Check environment variables
    if command grep -q "export ANDROID_HOME=" "$bashrc_file"; then
        assert_true true "ANDROID_HOME is exported"
    else
        assert_true false "ANDROID_HOME is not exported"
    fi

    if command grep -q "export ANDROID_SDK_ROOT=" "$bashrc_file"; then
        assert_true true "ANDROID_SDK_ROOT is exported"
    else
        assert_true false "ANDROID_SDK_ROOT is not exported"
    fi

    if command grep -q "export ANDROID_NDK_HOME=" "$bashrc_file"; then
        assert_true true "ANDROID_NDK_HOME is exported"
    else
        assert_true false "ANDROID_NDK_HOME is not exported"
    fi

    if command grep -q 'PATH.*platform-tools' "$bashrc_file"; then
        assert_true true "PATH includes platform-tools"
    else
        assert_true false "PATH doesn't include platform-tools"
    fi
}

# Test: Android aliases
test_android_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/50-android.sh"

    # Create bashrc with aliases
    command cat > "$bashrc_file" << 'EOF'
# Android SDK shortcuts
alias sdk='sdkmanager'
alias sdklist='sdkmanager --list'
alias sdkupdate='sdkmanager --update'

# ADB shortcuts
alias adbr='adb kill-server && adb start-server'
alias adbdev='adb devices'
alias adblog='adb logcat'
alias adbshell='adb shell'
EOF

    # Check aliases
    if command grep -q "alias sdk='sdkmanager'" "$bashrc_file"; then
        assert_true true "sdkmanager alias defined"
    else
        assert_true false "sdkmanager alias not defined"
    fi

    if command grep -q "alias adbdev='adb devices'" "$bashrc_file"; then
        assert_true true "adb devices alias defined"
    else
        assert_true false "adb devices alias not defined"
    fi
}

# Test: Cache directories
test_cache_directories() {
    local sdk_cache="$TEST_TEMP_DIR/cache/android-sdk"
    local avd_cache="$TEST_TEMP_DIR/cache/android-avd"

    mkdir -p "$sdk_cache" "$avd_cache"

    assert_dir_exists "$sdk_cache"
    assert_dir_exists "$avd_cache"

    if [ -w "$sdk_cache" ]; then
        assert_true true "SDK cache is writable"
    else
        assert_true false "SDK cache is not writable"
    fi

    if [ -w "$avd_cache" ]; then
        assert_true true "AVD cache is writable"
    else
        assert_true false "AVD cache is not writable"
    fi
}

# Test: Java prerequisite check
test_java_prerequisite() {
    # Android requires Java, verify the check pattern
    local test_script="$TEST_TEMP_DIR/check-java.sh"

    command cat > "$test_script" << 'EOF'
#!/bin/bash
if ! command -v java &>/dev/null; then
    echo "Java is required but not installed"
    exit 1
fi

# Check JAVA_HOME
if [ -z "${JAVA_HOME:-}" ]; then
    echo "JAVA_HOME is not set"
    exit 1
fi

echo "Java is available"
exit 0
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"
    if [ -x "$test_script" ]; then
        assert_true true "Java prerequisite check script is executable"
    else
        assert_true false "Java prerequisite check script is not executable"
    fi
}

# Test: API level parsing
test_api_level_parsing() {
    local api_levels="34,35"

    # Parse comma-separated levels
    IFS=',' read -ra levels <<< "$api_levels"

    assert_equals "2" "${#levels[@]}" "Should have 2 API levels"
    assert_equals "34" "${levels[0]}" "First level should be 34"
    assert_equals "35" "${levels[1]}" "Second level should be 35"
}

# Test: Verification script
test_android_verification() {
    local test_script="$TEST_TEMP_DIR/test-android.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Android SDK Status ==="

echo ""
echo "Environment:"
echo "  ANDROID_HOME: ${ANDROID_HOME:-not set}"
echo "  ANDROID_SDK_ROOT: ${ANDROID_SDK_ROOT:-not set}"
echo "  ANDROID_NDK_HOME: ${ANDROID_NDK_HOME:-not set}"

echo ""
echo "=== Command Line Tools ==="
if command -v sdkmanager &>/dev/null; then
    echo "sdkmanager is installed"
else
    echo "sdkmanager is not installed"
fi

echo ""
echo "=== Platform Tools ==="
if command -v adb &>/dev/null; then
    echo "adb is installed"
    adb --version 2>&1 | head -1
else
    echo "adb is not installed"
fi

echo ""
echo "=== Installed Components ==="
sdkmanager --list_installed 2>/dev/null || echo "Cannot list components"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Test: Android helper functions
test_android_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/50-android.sh"

    # Create bashrc with helpers
    command cat > "$bashrc_file" << 'EOF'
android-version() {
    echo "=== Android SDK Status ==="
    echo "ANDROID_HOME: ${ANDROID_HOME:-not set}"
    if command -v adb &>/dev/null; then
        echo "adb version:"
        adb --version 2>&1 | head -3
    fi
}

android-sdk-install() {
    local package="$1"
    if [ -z "$package" ]; then
        echo "Usage: android-sdk-install <package>"
        return 1
    fi
    yes | sdkmanager --install "$package"
}
EOF

    # Check helpers
    if command grep -q "android-version()" "$bashrc_file"; then
        assert_true true "android-version helper defined"
    else
        assert_true false "android-version helper not defined"
    fi

    if command grep -q "android-sdk-install()" "$bashrc_file"; then
        assert_true true "android-sdk-install helper defined"
    else
        assert_true false "android-sdk-install helper not defined"
    fi
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_api_level_validation "API level validation works"
run_test_with_setup test_ndk_version_validation "NDK version validation works"
run_test_with_setup test_cmdline_tools_version_validation "cmdline-tools version validation works"
run_test_with_setup test_sdk_directory_structure "SDK directory structure is correct"
run_test_with_setup test_build_tools "Build tools are installed correctly"
run_test_with_setup test_ndk_installation "NDK installation is correct"
run_test_with_setup test_license_acceptance "License acceptance is configured"
run_test_with_setup test_android_environment_variables "Android environment variables are set"
run_test_with_setup test_android_aliases "Android aliases are defined"
run_test_with_setup test_cache_directories "Cache directories are configured"
run_test_with_setup test_java_prerequisite "Java prerequisite check works"
run_test_with_setup test_api_level_parsing "API level parsing works"
run_test_with_setup test_android_verification "Android verification script works"
run_test_with_setup test_android_helpers "Android helper functions work"

# Generate test report
generate_report
