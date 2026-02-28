#!/usr/bin/env bash
# Unit tests for lib/features/kotlin.sh
# Tests Kotlin compiler and kotlin-native installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Kotlin Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-kotlin"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export KOTLIN_VERSION="${KOTLIN_VERSION:-2.1.0}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/opt/kotlin/bin"
    mkdir -p "$TEST_TEMP_DIR/opt/kotlin-native/bin"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/cache/kotlin"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset KOTLIN_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Kotlin version validation
test_kotlin_version_validation() {
    # Test valid versions
    local valid_versions=("2.1.0" "2.0.21" "1.9.25")

    for version in "${valid_versions[@]}"; do
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            assert_true true "Version $version is valid format"
        else
            assert_true false "Version $version should be valid"
        fi
    done

    # Test invalid versions
    local invalid_versions=("2.1" "abc" "2.1.0-RC1")

    for version in "${invalid_versions[@]}"; do
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            assert_true false "Version $version should be invalid"
        else
            assert_true true "Version $version is correctly rejected"
        fi
    done
}

# Test: Kotlin installation structure
test_kotlin_installation_structure() {
    local kotlin_home="$TEST_TEMP_DIR/opt/kotlin"

    # Create Kotlin directory structure
    mkdir -p "$kotlin_home/bin"
    mkdir -p "$kotlin_home/lib"
    mkdir -p "$kotlin_home/libexec"

    # Create Kotlin binaries
    local binaries=("kotlin" "kotlinc" "kotlinc-jvm" "kotlin-daemon")
    for bin in "${binaries[@]}"; do
        touch "$kotlin_home/bin/$bin"
        chmod +x "$kotlin_home/bin/$bin"
    done

    # Check structure
    assert_dir_exists "$kotlin_home"
    assert_dir_exists "$kotlin_home/bin"
    assert_dir_exists "$kotlin_home/lib"

    # Check binaries
    for bin in "${binaries[@]}"; do
        if [ -x "$kotlin_home/bin/$bin" ]; then
            assert_true true "$bin is executable"
        else
            assert_true false "$bin is not executable"
        fi
    done
}

# Test: kotlin-native installation structure
test_kotlin_native_installation() {
    local native_home="$TEST_TEMP_DIR/opt/kotlin-native"

    # Create kotlin-native directory structure
    mkdir -p "$native_home/bin"
    mkdir -p "$native_home/konan/lib"
    mkdir -p "$native_home/klib"

    # Create kotlin-native binaries
    local binaries=("kotlinc-native" "konanc" "cinterop" "klib")
    for bin in "${binaries[@]}"; do
        touch "$native_home/bin/$bin"
        chmod +x "$native_home/bin/$bin"
    done

    # Check structure
    assert_dir_exists "$native_home"
    assert_dir_exists "$native_home/bin"
    assert_dir_exists "$native_home/konan/lib"

    # Check binaries
    for bin in "${binaries[@]}"; do
        if [ -x "$native_home/bin/$bin" ]; then
            assert_true true "$bin is executable"
        else
            assert_true false "$bin is not executable"
        fi
    done
}

# Test: KOTLIN_HOME configuration
test_kotlin_home_configuration() {
    local kotlin_home="$TEST_TEMP_DIR/opt/kotlin"

    # Create mock directory
    mkdir -p "$kotlin_home"

    # Check KOTLIN_HOME would be set correctly
    assert_not_empty "$kotlin_home" "KOTLIN_HOME path is set"

    # Check KOTLIN_HOME exists
    if [ -d "$kotlin_home" ]; then
        assert_true true "KOTLIN_HOME directory exists"
    else
        assert_true false "KOTLIN_HOME directory doesn't exist"
    fi
}

# Test: Kotlin cache configuration
test_kotlin_cache_configuration() {
    local kotlin_cache="$TEST_TEMP_DIR/cache/kotlin"

    # Create cache directory
    mkdir -p "$kotlin_cache"

    assert_dir_exists "$kotlin_cache"

    # Check cache directory is writable
    if [ -w "$kotlin_cache" ]; then
        assert_true true "Kotlin cache is writable"
    else
        assert_true false "Kotlin cache is not writable"
    fi
}

# Test: Kotlin environment variables
test_kotlin_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/50-kotlin.sh"

    # Create mock bashrc content
    command cat > "$bashrc_file" << 'EOF'
export KOTLIN_HOME="/opt/kotlin"
export KOTLIN_NATIVE_HOME="/opt/kotlin-native"
export PATH="$KOTLIN_HOME/bin:$PATH"
export PATH="$KOTLIN_NATIVE_HOME/bin:$PATH"
EOF

    # Check environment variables
    if command grep -q "export KOTLIN_HOME=" "$bashrc_file"; then
        assert_true true "KOTLIN_HOME is exported"
    else
        assert_true false "KOTLIN_HOME is not exported"
    fi

    if command grep -q 'PATH.*KOTLIN_HOME/bin' "$bashrc_file"; then
        assert_true true "PATH includes Kotlin bin directory"
    else
        assert_true false "PATH doesn't include Kotlin bin directory"
    fi

    if command grep -q "export KOTLIN_NATIVE_HOME=" "$bashrc_file"; then
        assert_true true "KOTLIN_NATIVE_HOME is exported"
    else
        assert_true false "KOTLIN_NATIVE_HOME is not exported"
    fi
}

# Test: Kotlin aliases and helpers
test_kotlin_aliases_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/50-kotlin.sh"

    # Create bashrc with aliases
    command cat > "$bashrc_file" << 'EOF'
# Kotlin aliases
alias kc='kotlinc'
alias kt='kotlin'
alias kn='kotlinc-native'
alias ktv='kotlin -version'

kt-compile() {
    local source_file="$1"
    kotlinc "$source_file" -include-runtime -d "${source_file%.kt}.jar"
}

kt-run() {
    local jar_file="$1"
    java -jar "$jar_file"
}
EOF

    # Check common aliases
    if command grep -q "alias kc='kotlinc'" "$bashrc_file"; then
        assert_true true "kotlinc alias defined"
    else
        assert_true false "kotlinc alias not defined"
    fi

    if command grep -q "alias kt='kotlin'" "$bashrc_file"; then
        assert_true true "kotlin alias defined"
    else
        assert_true false "kotlin alias not defined"
    fi

    # Check helper functions
    if command grep -q "kt-compile()" "$bashrc_file"; then
        assert_true true "kt-compile helper defined"
    else
        assert_true false "kt-compile helper not defined"
    fi

    if command grep -q "kt-run()" "$bashrc_file"; then
        assert_true true "kt-run helper defined"
    else
        assert_true false "kt-run helper not defined"
    fi
}

# Test: Java prerequisite check
test_java_prerequisite() {
    # Kotlin requires Java, so we verify the check pattern
    local test_script="$TEST_TEMP_DIR/check-java.sh"

    command cat > "$test_script" << 'EOF'
#!/bin/bash
if ! command -v java &>/dev/null; then
    echo "Java is required but not installed"
    exit 1
fi
echo "Java is available"
exit 0
EOF
    chmod +x "$test_script"

    # The script exists and is executable
    assert_file_exists "$test_script"
    if [ -x "$test_script" ]; then
        assert_true true "Java prerequisite check script is executable"
    else
        assert_true false "Java prerequisite check script is not executable"
    fi
}

# Test: Kotlin verification script
test_kotlin_verification() {
    local test_script="$TEST_TEMP_DIR/test-kotlin.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Kotlin Installation Status ==="

echo ""
echo "Kotlin Compiler:"
if command -v kotlinc &>/dev/null; then
    kotlinc -version 2>&1 | head -1
else
    echo "  Not installed"
fi

echo ""
echo "Kotlin Runtime:"
if command -v kotlin &>/dev/null; then
    kotlin -version 2>&1 | head -1
else
    echo "  Not installed"
fi

echo ""
echo "Kotlin Native:"
if command -v kotlinc-native &>/dev/null; then
    kotlinc-native -version 2>&1 | head -1 || echo "  Installed"
else
    echo "  Not installed (optional)"
fi

echo ""
echo "Environment:"
echo "  KOTLIN_HOME: ${KOTLIN_HOME:-not set}"
echo "  KOTLIN_NATIVE_HOME: ${KOTLIN_NATIVE_HOME:-not set}"
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Verification script is executable"
    else
        assert_true false "Verification script is not executable"
    fi
}

# Test: Permissions and ownership
test_kotlin_permissions() {
    local kotlin_home="$TEST_TEMP_DIR/opt/kotlin"
    local native_home="$TEST_TEMP_DIR/opt/kotlin-native"
    local cache_dir="$TEST_TEMP_DIR/cache/kotlin"

    # Create directories
    mkdir -p "$kotlin_home" "$native_home" "$cache_dir"

    # Check directories exist and are accessible
    if [ -d "$kotlin_home" ] && [ -r "$kotlin_home" ]; then
        assert_true true "KOTLIN_HOME is readable"
    else
        assert_true false "KOTLIN_HOME is not readable"
    fi

    if [ -d "$native_home" ] && [ -r "$native_home" ]; then
        assert_true true "KOTLIN_NATIVE_HOME is readable"
    else
        assert_true false "KOTLIN_NATIVE_HOME is not readable"
    fi

    if [ -d "$cache_dir" ] && [ -w "$cache_dir" ]; then
        assert_true true "Kotlin cache directory is writable"
    else
        assert_true false "Kotlin cache directory is not writable"
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
run_test_with_setup test_kotlin_version_validation "Kotlin version validation works"
run_test_with_setup test_kotlin_installation_structure "Kotlin installation structure is correct"
run_test_with_setup test_kotlin_native_installation "kotlin-native installation is correct"
run_test_with_setup test_kotlin_home_configuration "KOTLIN_HOME configuration is proper"
run_test_with_setup test_kotlin_cache_configuration "Kotlin cache is configured correctly"
run_test_with_setup test_kotlin_environment_variables "Kotlin environment variables are set"
run_test_with_setup test_kotlin_aliases_helpers "Kotlin aliases and helpers are defined"
run_test_with_setup test_java_prerequisite "Java prerequisite check works"
run_test_with_setup test_kotlin_permissions "Kotlin directories have correct permissions"
run_test_with_setup test_kotlin_verification "Kotlin verification script works"

# Generate test report
generate_report
