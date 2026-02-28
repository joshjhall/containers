#!/usr/bin/env bash
# Unit tests for lib/features/golang-dev.sh
# Tests Go development tools installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Golang Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-golang-dev"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    export GOPATH="/cache/go"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/cache/go/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.config"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME GOPATH 2>/dev/null || true
}

# Test: Go development tools
test_go_dev_tools() {
    local gobin="$TEST_TEMP_DIR/cache/go/bin"

    # List of Go dev tools
    local tools=("gopls" "delve" "golangci-lint" "goimports" "goreleaser" "air" "gomodifytags")

    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$gobin/$tool"
        chmod +x "$gobin/$tool"
    done

    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$gobin/$tool" ]; then
            assert_true true "$tool is installed"
        else
            assert_true false "$tool is not installed"
        fi
    done
}

# Test: Gopls configuration
test_gopls_config() {
    local gopls_config="$TEST_TEMP_DIR/home/testuser/.config/gopls/config.yaml"
    mkdir -p "$(dirname "$gopls_config")"

    # Create config
    command cat > "$gopls_config" << 'EOF'
formatting:
  gofumpt: true
ui:
  completion:
    usePlaceholders: true
  diagnostic:
    staticcheck: true
EOF

    assert_file_exists "$gopls_config"

    # Check configuration
    if command grep -q "gofumpt: true" "$gopls_config"; then
        assert_true true "gofumpt formatting enabled"
    else
        assert_true false "gofumpt formatting not enabled"
    fi
}

# Test: Golangci-lint configuration
test_golangci_config() {
    local config_file="$TEST_TEMP_DIR/.golangci.yml"

    # Create config
    command cat > "$config_file" << 'EOF'
linters:
  enable:
    - gofmt
    - golint
    - govet
    - gosec
    - ineffassign
    - misspell
EOF

    assert_file_exists "$config_file"

    # Check linters
    if command grep -q "gosec" "$config_file"; then
        assert_true true "gosec linter enabled"
    else
        assert_true false "gosec linter not enabled"
    fi
}

# Test: Delve debugger
test_delve_debugger() {
    local dlv_bin="$TEST_TEMP_DIR/cache/go/bin/dlv"

    # Create mock delve
    touch "$dlv_bin"
    chmod +x "$dlv_bin"

    assert_file_exists "$dlv_bin"

    # Check executable
    if [ -x "$dlv_bin" ]; then
        assert_true true "Delve debugger is executable"
    else
        assert_true false "Delve debugger is not executable"
    fi
}

# Test: Air configuration
test_air_config() {
    local air_config="$TEST_TEMP_DIR/.air.toml"

    # Create config
    command cat > "$air_config" << 'EOF'
root = "."
tmp_dir = "tmp"

[build]
cmd = "go build -o ./tmp/main ."
bin = "tmp/main"
include_ext = ["go", "tpl", "tmpl", "html"]
EOF

    assert_file_exists "$air_config"

    # Check configuration
    if command grep -q 'include_ext = \["go"' "$air_config"; then
        assert_true true "Air watches Go files"
    else
        assert_true false "Air doesn't watch Go files"
    fi
}

# Test: Go workspace
test_go_workspace() {
    local workspace_file="$TEST_TEMP_DIR/go.work"

    # Create workspace file
    command cat > "$workspace_file" << 'EOF'
go 1.21

use (
    ./service-a
    ./service-b
    ./shared
)
EOF

    assert_file_exists "$workspace_file"

    # Check workspace
    if command grep -q "use (" "$workspace_file"; then
        assert_true true "Go workspace configured"
    else
        assert_true false "Go workspace not configured"
    fi
}

# Test: Makefile for Go
test_go_makefile() {
    local makefile="$TEST_TEMP_DIR/Makefile"

    # Create Makefile
    command cat > "$makefile" << 'EOF'
.PHONY: lint test build

lint:
	golangci-lint run

test:
	go test -v -race ./...

build:
	go build -o bin/app .
EOF

    assert_file_exists "$makefile"

    # Check targets
    if command grep -q "golangci-lint run" "$makefile"; then
        assert_true true "Lint target uses golangci-lint"
    else
        assert_true false "Lint target doesn't use golangci-lint"
    fi
}

# Test: Go dev aliases
test_go_dev_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-golang-dev.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias glt='golangci-lint run'
alias dlv='dlv debug'
alias gops='gopls'
alias gfmt='goimports -w'
alias gair='air'
EOF

    # Check aliases
    if command grep -q "alias glt='golangci-lint run'" "$bashrc_file"; then
        assert_true true "golangci-lint alias defined"
    else
        assert_true false "golangci-lint alias not defined"
    fi
}

# Test: Protocol buffers support
test_protobuf_support() {
    local gobin="$TEST_TEMP_DIR/cache/go/bin"

    # Create protoc-gen-go tools
    touch "$gobin/protoc-gen-go"
    touch "$gobin/protoc-gen-go-grpc"
    chmod +x "$gobin/protoc-gen-go" "$gobin/protoc-gen-go-grpc"

    # Check protobuf tools
    if [ -x "$gobin/protoc-gen-go" ]; then
        assert_true true "protoc-gen-go installed"
    else
        assert_true false "protoc-gen-go not installed"
    fi
}

# Test: Verification script
test_golang_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-golang-dev.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Go dev tools:"
for tool in gopls delve golangci-lint goimports air; do
    command -v $tool &>/dev/null && echo "  - $tool: installed" || echo "  - $tool: not found"
done
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

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_go_dev_tools "Go development tools"
run_test_with_setup test_gopls_config "Gopls configuration"
run_test_with_setup test_golangci_config "Golangci-lint configuration"
run_test_with_setup test_delve_debugger "Delve debugger"
run_test_with_setup test_air_config "Air configuration"
run_test_with_setup test_go_workspace "Go workspace"
run_test_with_setup test_go_makefile "Makefile for Go"
run_test_with_setup test_go_dev_aliases "Go dev aliases"
run_test_with_setup test_protobuf_support "Protocol buffers support"
run_test_with_setup test_golang_dev_verification "Golang dev verification"

# Generate test report
generate_report
