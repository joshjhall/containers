#!/usr/bin/env bash
# Test rust-golang container build
#
# This test verifies a systems programming polyglot setup with:
# - Rust with cargo and development tools
# - Go with development tools
# - Development tools for both languages

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Rust + Go Systems Programming Stack"

# Test: Rust + Go environment builds
test_rust_golang_build() {
    local image="test-rust-go-$$"

    # Build with Rust and Go dev tools
    assert_build_succeeds "Dockerfile" \
        --build-arg PROJECT_NAME=test-rust-go \
        --build-arg INCLUDE_RUST_DEV=true \
        --build-arg INCLUDE_GOLANG_DEV=true \
        -t "$image"

    # Verify Rust toolchain
    assert_executable_in_path "$image" "rustc"
    assert_executable_in_path "$image" "cargo"
    assert_executable_in_path "$image" "clippy-driver"
    assert_executable_in_path "$image" "rustfmt"

    # Verify Go toolchain
    assert_executable_in_path "$image" "go"
    assert_executable_in_path "$image" "gofmt"
}

# Test: Rust and Go can compile simple programs
test_compilation() {
    local image="test-rust-go-$$"

    # Test Rust version
    assert_command_in_container "$image" "rustc --version" "rustc"

    # Test Go version
    assert_command_in_container "$image" "go version" "go version"
}

# Run all tests
run_test test_rust_golang_build "Rust + Go environment builds successfully"
run_test test_compilation "Rust and Go compilers work"

# Generate test report
generate_report
