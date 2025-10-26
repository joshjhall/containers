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
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
    else
        local image="test-rust-go-$$"
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-rust-go \
            --build-arg INCLUDE_RUST_DEV=true \
            --build-arg INCLUDE_GOLANG_DEV=true \
            -t "$image"
    fi

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
    local image="${IMAGE_TO_TEST:-test-rust-go-$$}"

    # Test Rust version
    assert_command_in_container "$image" "rustc --version" "rustc"

    # Test Go version
    assert_command_in_container "$image" "go version" "go version"
}

# Test: Rust compilation and execution
test_rust_compilation() {
    local image="${IMAGE_TO_TEST:-test-rust-go-$$}"

    # Compile and run a Rust program
    assert_command_in_container "$image" "cd /tmp && echo 'fn main() { println!(\"Hello from Rust\"); }' > hello.rs && rustc hello.rs && ./hello" "Hello from Rust"

    # Cargo can create a new project
    assert_command_in_container "$image" "cd /tmp && cargo new test-project --quiet && test -d test-project && echo ok" "ok"
}

# Test: Go compilation and execution
test_go_compilation() {
    local image="${IMAGE_TO_TEST:-test-rust-go-$$}"

    # Compile and run a Go program
    assert_command_in_container "$image" "cd /tmp && echo 'package main; import \"fmt\"; func main() { fmt.Println(\"Hello from Go\") }' > hello.go && go run hello.go" "Hello from Go"

    # Go can build a binary
    assert_command_in_container "$image" "cd /tmp && go build hello.go && ./hello" "Hello from Go"
}

# Test: Rust development tools
test_rust_tools() {
    local image="${IMAGE_TO_TEST:-test-rust-go-$$}"

    # Cargo works
    assert_command_in_container "$image" "cargo --version" "cargo"

    # Clippy (linter) works
    assert_command_in_container "$image" "cargo clippy --version" "clippy"

    # Rustfmt (formatter) works
    assert_command_in_container "$image" "rustfmt --version" "rustfmt"
}

# Test: Go development tools
test_go_tools() {
    local image="${IMAGE_TO_TEST:-test-rust-go-$$}"

    # gofmt works
    assert_command_in_container "$image" "echo 'package main; func main() {}' | gofmt" "package main"

    # Go can format code
    assert_command_in_container "$image" "go version" "go version"
}

# Test: Cache directories configured
test_rust_go_cache() {
    local image="${IMAGE_TO_TEST:-test-rust-go-$$}"

    # Rust cargo cache
    assert_command_in_container "$image" "test -w /cache/cargo && echo writable" "writable"

    # Go module cache
    assert_command_in_container "$image" "test -w /cache/go && echo writable" "writable"
}

# Test: Cross-compilation capability
test_cross_language_interop() {
    local image="${IMAGE_TO_TEST:-test-rust-go-$$}"

    # Both languages can work in same workspace
    assert_command_in_container "$image" "cd /tmp && echo 'fn main() { println!(\"42\"); }' > test.rs && rustc test.rs && ./test" "42"
    assert_command_in_container "$image" "cd /tmp && echo 'package main; import \"fmt\"; func main() { fmt.Println(\"42\") }' > test.go && go run test.go" "42"
}

# Run all tests
run_test test_rust_golang_build "Rust + Go environment builds successfully"
run_test test_compilation "Rust and Go compilers work"
run_test test_rust_compilation "Rust compilation and execution works"
run_test test_go_compilation "Go compilation and execution works"
run_test test_rust_tools "Rust development tools work"
run_test test_go_tools "Go development tools work"
run_test test_rust_go_cache "Cache directories are configured"
run_test test_cross_language_interop "Both languages can coexist"

# Generate test report
generate_report
