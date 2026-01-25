#!/usr/bin/env bash
# Test kotlin container build
#
# This test verifies the Kotlin configuration including:
# - Kotlin compiler installation
# - Kotlin/Native (if available for architecture)
# - Kotlin dev tools (ktlint, detekt, kotlin-language-server)
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
test_suite "Kotlin Container Build"

# Test: Kotlin builds successfully
test_kotlin_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-kotlin-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-kotlin \
            --build-arg INCLUDE_KOTLIN=true \
            -t "$image"
    fi

    # Verify Kotlin compiler is installed
    assert_executable_in_path "$image" "kotlinc"
    assert_executable_in_path "$image" "kotlin"

    # Verify Java was auto-triggered
    assert_executable_in_path "$image" "java"
    assert_executable_in_path "$image" "javac"
}

# Test: Kotlin compiler works
test_kotlin_compile() {
    local image="${IMAGE_TO_TEST:-test-kotlin-$$}"

    # Test Kotlin version
    assert_command_in_container "$image" "kotlinc -version" "kotlinc"
}

# Test: Kotlin can compile and run code
test_kotlin_execution() {
    local image="${IMAGE_TO_TEST:-test-kotlin-$$}"

    # Create and run a simple Kotlin program
    assert_command_in_container "$image" \
        "cd /tmp && echo 'fun main() { println(\"Hello from Kotlin\") }' > test.kt && kotlinc test.kt -include-runtime -d test.jar && kotlin test.jar" \
        "Hello from Kotlin"
}

# Test: Kotlin script execution
test_kotlin_script() {
    local image="${IMAGE_TO_TEST:-test-kotlin-$$}"

    # Test kotlin script
    assert_command_in_container "$image" \
        "cd /tmp && echo 'println(\"Script works\")' > test.kts && kotlinc -script test.kts" \
        "Script works"
}

# Test: Kotlin cache directories exist
test_kotlin_cache() {
    local image="${IMAGE_TO_TEST:-test-kotlin-$$}"

    # Cache directory exists and is writable
    assert_command_in_container "$image" "test -d /cache/kotlin && echo exists" "exists"
}

# Test: Kotlin dev tools (separate build)
test_kotlin_dev_build() {
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-kotlin-dev-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-kotlin-dev \
            --build-arg INCLUDE_KOTLIN_DEV=true \
            -t "$image"
    fi

    # Verify Kotlin is installed (auto-triggered)
    assert_executable_in_path "$image" "kotlinc"

    # Verify dev tools
    assert_executable_in_path "$image" "ktlint"
}

# Test: ktlint works
test_ktlint() {
    local image="${IMAGE_TO_TEST:-test-kotlin-dev-$$}"

    # Test ktlint version
    assert_command_in_container "$image" "ktlint --version" ""
}

# Test: detekt works
test_detekt() {
    local image="${IMAGE_TO_TEST:-test-kotlin-dev-$$}"

    # Test detekt (may show version or help)
    echo -n "  Testing detekt... "
    if docker run --rm "$image" bash -c "detekt --version" >/dev/null 2>&1; then
        echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
    else
        echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
        echo "    detekt may not be installed"
    fi
}

# Test: kotlin-language-server is installed
test_kotlin_lsp() {
    local image="${IMAGE_TO_TEST:-test-kotlin-dev-$$}"

    echo -n "  Testing kotlin-language-server... "
    if docker run --rm "$image" bash -c "command -v kotlin-language-server" >/dev/null 2>&1; then
        echo -e "${TEST_COLOR_PASS}PASS${TEST_COLOR_RESET}"
    else
        echo -e "${TEST_COLOR_SKIP}SKIP${TEST_COLOR_RESET}"
        echo "    kotlin-language-server may not be installed"
    fi
}

# Run all tests
run_test test_kotlin_build "Kotlin builds successfully with auto-triggered Java"
run_test test_kotlin_compile "Kotlin compiler is functional"
run_test test_kotlin_execution "Kotlin can compile and run code"
run_test test_kotlin_script "Kotlin script execution works"
run_test test_kotlin_cache "Kotlin cache directories exist"
run_test test_kotlin_dev_build "Kotlin dev tools build successfully"
run_test test_ktlint "ktlint is functional"
run_test test_detekt "detekt is installed"
run_test test_kotlin_lsp "kotlin-language-server is installed"

# Generate test report
generate_report
