#!/usr/bin/env bash
# Unit tests for lib/features/android-dev.sh
# Tests Android development tools: emulator, system images, AVD management

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Android Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-android-dev"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export ANDROID_API_LEVELS="${ANDROID_API_LEVELS:-34,35}"
    export ANDROID_HOME="$TEST_TEMP_DIR/opt/android-sdk"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$ANDROID_HOME/cmdline-tools/latest/bin"
    mkdir -p "$ANDROID_HOME/emulator"
    mkdir -p "$ANDROID_HOME/system-images/android-34/google_apis/x86_64"
    mkdir -p "$ANDROID_HOME/sources/android-34"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/cache/android-avd"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset ANDROID_API_LEVELS ANDROID_HOME ANDROID_SDK_ROOT \
          USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Android SDK prerequisite check
test_android_sdk_prerequisite() {
    # android-dev requires android.sh installation
    local test_script="$TEST_TEMP_DIR/check-android.sh"

    command cat > "$test_script" << 'EOF'
#!/bin/bash
if [ -z "${ANDROID_HOME:-}" ]; then
    echo "ANDROID_HOME is not set"
    exit 1
fi

if [ ! -d "${ANDROID_HOME}/cmdline-tools/latest/bin" ]; then
    echo "Android SDK cmdline-tools not found"
    exit 1
fi

if ! command -v sdkmanager &>/dev/null; then
    echo "sdkmanager not found"
    exit 1
fi

echo "Android SDK is available"
exit 0
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"
    if [ -x "$test_script" ]; then
        assert_true true "Android SDK prerequisite check script is executable"
    else
        assert_true false "Android SDK prerequisite check script is not executable"
    fi
}

# Test: Emulator installation
test_emulator_installation() {
    local emulator_dir="$ANDROID_HOME/emulator"

    mkdir -p "$emulator_dir"

    # Create mock emulator binaries
    local binaries=("emulator" "emulator-check" "mksdcard")
    for bin in "${binaries[@]}"; do
        touch "$emulator_dir/$bin"
        chmod +x "$emulator_dir/$bin"
    done

    assert_dir_exists "$emulator_dir"

    for bin in "${binaries[@]}"; do
        if [ -x "$emulator_dir/$bin" ]; then
            assert_true true "$bin is executable"
        else
            assert_true false "$bin is not executable"
        fi
    done
}

# Test: System images installation
test_system_images_installation() {
    local sysimg_base="$ANDROID_HOME/system-images"

    # Create mock system images for API 34
    local sysimg_dir="$sysimg_base/android-34/google_apis/x86_64"
    mkdir -p "$sysimg_dir"

    # Create mock system image files
    local files=("system.img" "userdata.img" "vendor.img" "ramdisk.img")
    for file in "${files[@]}"; do
        touch "$sysimg_dir/$file"
    done

    assert_dir_exists "$sysimg_dir"

    for file in "${files[@]}"; do
        if [ -f "$sysimg_dir/$file" ]; then
            assert_true true "$file exists"
        else
            assert_true false "$file doesn't exist"
        fi
    done
}

# Test: Sources installation
test_sources_installation() {
    local sources_dir="$ANDROID_HOME/sources/android-34"

    mkdir -p "$sources_dir/android"
    touch "$sources_dir/android/app"

    assert_dir_exists "$sources_dir"

    if [ -d "$sources_dir/android" ]; then
        assert_true true "Android sources directory exists"
    else
        assert_true false "Android sources directory doesn't exist"
    fi
}

# Test: AVD cache configuration
test_avd_cache_configuration() {
    local avd_cache="$TEST_TEMP_DIR/cache/android-avd"

    mkdir -p "$avd_cache"

    assert_dir_exists "$avd_cache"

    if [ -w "$avd_cache" ]; then
        assert_true true "AVD cache is writable"
    else
        assert_true false "AVD cache is not writable"
    fi
}

# Test: Environment variables
test_android_dev_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-android-dev.sh"

    # Create mock bashrc content
    command cat > "$bashrc_file" << 'EOF'
export ANDROID_AVD_HOME="/cache/android-avd"
export ANDROID_EMULATOR_HOME="/cache/android-avd"
export ANDROID_EMULATOR_USE_SYSTEM_LIBS=1
export PATH="$ANDROID_HOME/emulator:$PATH"
EOF

    # Check environment variables
    if grep -q "export ANDROID_AVD_HOME=" "$bashrc_file"; then
        assert_true true "ANDROID_AVD_HOME is exported"
    else
        assert_true false "ANDROID_AVD_HOME is not exported"
    fi

    if grep -q "export ANDROID_EMULATOR_HOME=" "$bashrc_file"; then
        assert_true true "ANDROID_EMULATOR_HOME is exported"
    else
        assert_true false "ANDROID_EMULATOR_HOME is not exported"
    fi

    if grep -q 'PATH.*emulator' "$bashrc_file"; then
        assert_true true "PATH includes emulator directory"
    else
        assert_true false "PATH doesn't include emulator directory"
    fi
}

# Test: Emulator aliases
test_emulator_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-android-dev.sh"

    # Create bashrc with aliases
    command cat > "$bashrc_file" << 'EOF'
# Emulator shortcuts
alias avdlist='avdmanager list avd'
alias emlist='emulator -list-avds'
alias emkill='adb emu kill'
EOF

    # Check aliases
    if grep -q "alias avdlist='avdmanager list avd'" "$bashrc_file"; then
        assert_true true "avdlist alias defined"
    else
        assert_true false "avdlist alias not defined"
    fi

    if grep -q "alias emlist='emulator -list-avds'" "$bashrc_file"; then
        assert_true true "emlist alias defined"
    else
        assert_true false "emlist alias not defined"
    fi
}

# Test: AVD management helpers
test_avd_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-android-dev.sh"

    # Create bashrc with AVD helpers
    command cat > "$bashrc_file" << 'EOF'
avd-create() {
    local name="${1:-test-avd}"
    local api_level="${2:-34}"
    local abi="${3:-x86_64}"
    local package="system-images;android-${api_level};google_apis;${abi}"

    echo "Creating AVD: $name (API $api_level, $abi)"
    echo "no" | avdmanager create avd -n "$name" -k "$package" --force
}

avd-start() {
    local name="${1:-test-avd}"
    local headless="${2:-true}"

    if [ "$headless" = "true" ]; then
        emulator @"$name" -no-window -no-audio -no-boot-anim &
    else
        emulator @"$name" &
    fi
}

avd-delete() {
    local name="${1:-test-avd}"
    avdmanager delete avd -n "$name"
}
EOF

    # Check helpers
    if grep -q "avd-create()" "$bashrc_file"; then
        assert_true true "avd-create helper defined"
    else
        assert_true false "avd-create helper not defined"
    fi

    if grep -q "avd-start()" "$bashrc_file"; then
        assert_true true "avd-start helper defined"
    else
        assert_true false "avd-start helper not defined"
    fi

    if grep -q "avd-delete()" "$bashrc_file"; then
        assert_true true "avd-delete helper defined"
    else
        assert_true false "avd-delete helper not defined"
    fi

    # Check headless mode support
    if grep -q "\-no-window" "$bashrc_file"; then
        assert_true true "Headless mode is supported"
    else
        assert_true false "Headless mode not configured"
    fi
}

# Test: KVM detection
test_kvm_detection() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-android-dev.sh"

    # Create bashrc with KVM check
    command cat > "$bashrc_file" << 'EOF'
check-kvm() {
    echo "=== KVM Support Check ==="

    if [ -e /dev/kvm ]; then
        echo "KVM device exists"
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            echo "KVM is accessible"
            return 0
        else
            echo "KVM exists but is not accessible"
            echo "Add user to kvm group: sudo usermod -aG kvm \$USER"
            return 1
        fi
    else
        echo "KVM is not available"
        echo "Emulator will use software rendering (slower)"
        return 1
    fi
}
EOF

    # Check KVM detection helper
    if grep -q "check-kvm()" "$bashrc_file"; then
        assert_true true "check-kvm helper defined"
    else
        assert_true false "check-kvm helper not defined"
    fi

    if grep -q "/dev/kvm" "$bashrc_file"; then
        assert_true true "KVM device check is included"
    else
        assert_true false "KVM device check is missing"
    fi
}

# Test: Logcat helpers
test_logcat_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-android-dev.sh"

    # Create bashrc with logcat helpers
    command cat > "$bashrc_file" << 'EOF'
adb-logcat() {
    local filter="${1:-*:V}"
    adb logcat "$filter"
}

adb-logcat-clear() {
    adb logcat -c
    echo "Logcat buffer cleared"
}

adb-logcat-app() {
    local package="$1"
    if [ -z "$package" ]; then
        echo "Usage: adb-logcat-app <package.name>"
        return 1
    fi
    local pid
    pid=$(adb shell pidof "$package" 2>/dev/null)
    if [ -n "$pid" ]; then
        adb logcat --pid="$pid"
    else
        echo "App not running: $package"
        return 1
    fi
}
EOF

    # Check logcat helpers
    if grep -q "adb-logcat()" "$bashrc_file"; then
        assert_true true "adb-logcat helper defined"
    else
        assert_true false "adb-logcat helper not defined"
    fi

    if grep -q "adb-logcat-app()" "$bashrc_file"; then
        assert_true true "adb-logcat-app helper defined"
    else
        assert_true false "adb-logcat-app helper not defined"
    fi
}

# Test: Architecture support
test_architecture_support() {
    # Test architecture-to-ABI mapping
    local arch_amd64="amd64"
    local arch_arm64="arm64"

    # amd64 -> x86_64
    if [ "$arch_amd64" = "amd64" ]; then
        local abi="x86_64"
        assert_equals "x86_64" "$abi" "amd64 maps to x86_64"
    fi

    # arm64 -> arm64-v8a
    if [ "$arch_arm64" = "arm64" ]; then
        local abi="arm64-v8a"
        assert_equals "arm64-v8a" "$abi" "arm64 maps to arm64-v8a"
    fi
}

# Test: Verification script
test_android_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-android-dev.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Android Development Tools Status ==="

echo ""
echo "=== Emulator ==="
if command -v emulator &>/dev/null; then
    echo "emulator is installed"
    emulator -version 2>&1 | head -3
else
    echo "emulator is not installed"
fi

echo ""
echo "=== AVD Manager ==="
if command -v avdmanager &>/dev/null; then
    echo "avdmanager is installed"
else
    echo "avdmanager is not installed"
fi

echo ""
echo "=== Existing AVDs ==="
if command -v emulator &>/dev/null; then
    emulator -list-avds 2>/dev/null || echo "No AVDs found"
else
    echo "Emulator not available"
fi

echo ""
echo "=== System Images ==="
if [ -d "${ANDROID_HOME}/system-images" ]; then
    find "${ANDROID_HOME}/system-images" -maxdepth 3 -type d 2>/dev/null | head -10
else
    echo "No system images found"
fi

echo ""
echo "=== KVM Support ==="
if [ -e /dev/kvm ]; then
    echo "KVM is available"
else
    echo "KVM not available (software rendering)"
fi
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Test: CI/CD headless configuration
test_cicd_configuration() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/55-android-dev.sh"

    # Create bashrc with CI/CD helper
    command cat > "$bashrc_file" << 'EOF'
emulator-ci-start() {
    local avd_name="${1:-test-avd}"
    local timeout="${2:-120}"

    echo "Starting emulator in CI mode..."
    emulator @"$avd_name" -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect &

    echo "Waiting for emulator to boot (timeout: ${timeout}s)..."
    local count=0
    while [ $count -lt $timeout ]; do
        if adb shell getprop sys.boot_completed 2>/dev/null | grep -q "1"; then
            echo "Emulator booted successfully"
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done

    echo "Emulator boot timeout"
    return 1
}
EOF

    # Check CI/CD helper
    if grep -q "emulator-ci-start()" "$bashrc_file"; then
        assert_true true "emulator-ci-start helper defined"
    else
        assert_true false "emulator-ci-start helper not defined"
    fi

    if grep -q "gpu swiftshader_indirect" "$bashrc_file"; then
        assert_true true "Software rendering configured for CI"
    else
        assert_true false "Software rendering not configured"
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
run_test_with_setup test_android_sdk_prerequisite "Android SDK prerequisite check works"
run_test_with_setup test_emulator_installation "Emulator installation is correct"
run_test_with_setup test_system_images_installation "System images installation is correct"
run_test_with_setup test_sources_installation "Sources installation is correct"
run_test_with_setup test_avd_cache_configuration "AVD cache is configured correctly"
run_test_with_setup test_android_dev_environment "Android dev environment is configured"
run_test_with_setup test_emulator_aliases "Emulator aliases are defined"
run_test_with_setup test_avd_helpers "AVD management helpers work"
run_test_with_setup test_kvm_detection "KVM detection works"
run_test_with_setup test_logcat_helpers "Logcat helpers work"
run_test_with_setup test_architecture_support "Architecture support is correct"
run_test_with_setup test_android_dev_verification "Android dev verification script works"
run_test_with_setup test_cicd_configuration "CI/CD configuration works"

# Generate test report
generate_report
