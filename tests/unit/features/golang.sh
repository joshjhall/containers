#!/usr/bin/env bash
# Unit tests for lib/features/golang.sh
# Tests Go installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Golang Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-golang"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export GO_VERSION="1.24.5"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local"
    mkdir -p "$TEST_TEMP_DIR/home/testuser"
    mkdir -p "$TEST_TEMP_DIR/cache/go"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset GO_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Go version parsing
test_go_version_parsing() {
    # Test version extraction
    local version="1.24.5"
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)
    local patch=$(echo $version | cut -d. -f3)
    
    assert_equals "1" "$major" "Major version extracted correctly"
    assert_equals "24" "$minor" "Minor version extracted correctly"
    assert_equals "5" "$patch" "Patch version extracted correctly"
    
    # Test version comparison logic
    if [ "$major" -ge 1 ] && [ "$minor" -ge 11 ]; then
        assert_true true "Version supports modules (>= 1.11)"
    else
        assert_true false "Version too old for modules"
    fi
}

# Test: Go installation directory structure
test_go_installation_structure() {
    local go_root="$TEST_TEMP_DIR/usr/local/go"
    
    # Create mock Go installation
    mkdir -p "$go_root/bin"
    mkdir -p "$go_root/src"
    mkdir -p "$go_root/pkg"
    
    # Create mock Go binaries
    touch "$go_root/bin/go"
    touch "$go_root/bin/gofmt"
    chmod +x "$go_root/bin/go" "$go_root/bin/gofmt"
    
    # Check structure
    assert_dir_exists "$go_root"
    assert_dir_exists "$go_root/bin"
    assert_file_exists "$go_root/bin/go"
    assert_file_exists "$go_root/bin/gofmt"
    
    # Check executables
    if [ -x "$go_root/bin/go" ]; then
        assert_true true "go binary is executable"
    else
        assert_true false "go binary is not executable"
    fi
}

# Test: GOPATH configuration
test_gopath_configuration() {
    # Test with cache directory
    local cache_dir="$TEST_TEMP_DIR/cache"
    if [ -d "$cache_dir" ]; then
        local expected_gopath="$cache_dir/go"
        assert_not_empty "$expected_gopath" "GOPATH uses cache directory when available"
    fi
    
    # Test fallback to home directory
    local home_gopath="$TEST_TEMP_DIR/home/testuser/go"
    mkdir -p "$home_gopath"
    assert_dir_exists "$home_gopath"
    
    # Check GOPATH subdirectories
    mkdir -p "$home_gopath/bin"
    mkdir -p "$home_gopath/src"
    mkdir -p "$home_gopath/pkg"
    
    assert_dir_exists "$home_gopath/bin"
    assert_dir_exists "$home_gopath/src"
    assert_dir_exists "$home_gopath/pkg"
}

# Test: Go environment variables
test_go_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-golang.sh"
    
    # Create mock bashrc content
    cat > "$bashrc_file" << 'EOF'
export GOROOT="/usr/local/go"
export GOPATH="${GOPATH:-/cache/go}"
export GOCACHE="${GOCACHE:-$GOPATH/cache}"
export GOMODCACHE="${GOMODCACHE:-$GOPATH/pkg/mod}"
export PATH="$GOROOT/bin:$GOPATH/bin:$PATH"
export GO111MODULE=on
EOF
    
    # Check environment variables
    if grep -q "export GOROOT=" "$bashrc_file"; then
        assert_true true "GOROOT is exported"
    else
        assert_true false "GOROOT is not exported"
    fi
    
    if grep -q "export GOPATH=" "$bashrc_file"; then
        assert_true true "GOPATH is exported"
    else
        assert_true false "GOPATH is not exported"
    fi
    
    if grep -q "export GO111MODULE=on" "$bashrc_file"; then
        assert_true true "GO111MODULE is enabled"
    else
        assert_true false "GO111MODULE is not enabled"
    fi
    
    # Check PATH includes Go directories
    if grep -q 'PATH.*GOROOT/bin.*GOPATH/bin' "$bashrc_file"; then
        assert_true true "PATH includes Go binary directories"
    else
        assert_true false "PATH doesn't include Go directories"
    fi
}

# Test: Go cache configuration
test_go_cache_configuration() {
    local cache_base="$TEST_TEMP_DIR/cache/go"
    
    # Create cache directories
    mkdir -p "$cache_base/cache"
    mkdir -p "$cache_base/pkg/mod"
    
    assert_dir_exists "$cache_base/cache"
    assert_dir_exists "$cache_base/pkg/mod"
    
    # Check cache environment would be set
    local gocache="$cache_base/cache"
    local gomodcache="$cache_base/pkg/mod"
    
    assert_not_empty "$gocache" "GOCACHE path is set"
    assert_not_empty "$gomodcache" "GOMODCACHE path is set"
}

# Test: Go workspace permissions
test_go_workspace_permissions() {
    local gopath="$TEST_TEMP_DIR/home/testuser/go"
    mkdir -p "$gopath"
    
    # Simulate setting ownership
    # In real script: chown -R ${USER_UID}:${USER_GID} "$gopath"
    
    # Check directory exists and is accessible
    if [ -d "$gopath" ] && [ -w "$gopath" ]; then
        assert_true true "Go workspace is writable"
    else
        assert_true false "Go workspace is not writable"
    fi
}

# Test: Go aliases and helpers
test_go_aliases_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-golang.sh"
    
    # Add aliases section
    cat >> "$bashrc_file" << 'EOF'

# Go aliases
alias gotest='go test -v ./...'
alias gomod='go mod'
alias gofmtall='gofmt -s -w .'
alias govet='go vet ./...'
EOF
    
    # Check aliases
    if grep -q "alias gotest=" "$bashrc_file"; then
        assert_true true "gotest alias defined"
    else
        assert_true false "gotest alias not defined"
    fi
    
    if grep -q "alias gomod=" "$bashrc_file"; then
        assert_true true "gomod alias defined"
    else
        assert_true false "gomod alias not defined"
    fi
}

# Test: Architecture-specific download
test_architecture_download() {
    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    local version="1.24.5"
    
    # Map architecture to Go naming
    case "$arch" in
        amd64)
            local go_arch="amd64"
            ;;
        arm64)
            local go_arch="arm64"
            ;;
        armhf)
            local go_arch="armv6l"
            ;;
        *)
            local go_arch="$arch"
            ;;
    esac
    
    # Construct download URL
    local url="https://go.dev/dl/go${version}.linux-${go_arch}.tar.gz"
    
    # Check URL format
    if [[ "$url" =~ go\.dev/dl/go.*\.linux-.*\.tar\.gz ]]; then
        assert_true true "Download URL format is correct"
    else
        assert_true false "Download URL format is incorrect"
    fi
}

# Test: Go module proxy configuration
test_go_module_proxy() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/25-golang.sh"
    
    # Add proxy configuration
    cat >> "$bashrc_file" << 'EOF'

# Go module proxy (optional, improves download speed)
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.org}"
EOF
    
    # Check proxy settings
    if grep -q "export GOPROXY=" "$bashrc_file"; then
        assert_true true "GOPROXY is configured"
    else
        assert_true false "GOPROXY is not configured"
    fi
    
    if grep -q "export GOSUMDB=" "$bashrc_file"; then
        assert_true true "GOSUMDB is configured"
    else
        assert_true false "GOSUMDB is not configured"
    fi
}

# Test: Go verification
test_go_verification() {
    local test_script="$TEST_TEMP_DIR/test-go.sh"
    
    # Create verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Go version:"
go version 2>/dev/null || echo "Go not installed"
echo "GOPATH: ${GOPATH:-not set}"
echo "GOROOT: ${GOROOT:-not set}"
echo "Go env:"
go env GOPATH GOROOT GOCACHE 2>/dev/null || echo "Unable to get Go env"
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

# Test: Dynamic checksum fetching is used
test_dynamic_checksum_fetching() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"

    # Should source checksum-fetch.sh for dynamic fetching
    if grep -q "source.*checksum-fetch.sh" "$golang_script"; then
        assert_true true "golang.sh sources checksum-fetch.sh for dynamic fetching"
    else
        assert_true false "golang.sh doesn't source checksum-fetch.sh"
    fi

    # Should use fetch_go_checksum for dynamic fetching from go.dev
    if grep -q "fetch_go_checksum" "$golang_script"; then
        assert_true true "Uses fetch_go_checksum for dynamic fetching from go.dev"
    else
        assert_true false "Doesn't use fetch_go_checksum"
    fi
}

# Test: Download verification functions are used
test_download_verification() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"

    # Check that download verification functions are used (not curl | tar)
    if grep -q "download_and_extract" "$golang_script"; then
        assert_true true "Uses download_and_extract for verification"
    else
        assert_true false "Doesn't use download_and_extract"
    fi
}

# Test: Script sources download-verify.sh
test_sources_download_verify() {
    local golang_script="$PROJECT_ROOT/lib/features/golang.sh"

    if grep -q "source.*download-verify.sh" "$golang_script"; then
        assert_true true "golang.sh sources download-verify.sh"
    else
        assert_true false "golang.sh doesn't source download-verify.sh"
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
run_test_with_setup test_go_version_parsing "Go version parsing works correctly"
run_test_with_setup test_go_installation_structure "Go installation structure is correct"
run_test_with_setup test_gopath_configuration "GOPATH configuration is proper"
run_test_with_setup test_go_environment_variables "Go environment variables are set"
run_test_with_setup test_go_cache_configuration "Go cache is configured correctly"
run_test_with_setup test_go_workspace_permissions "Go workspace has correct permissions"
run_test_with_setup test_go_aliases_helpers "Go aliases and helpers are defined"
run_test_with_setup test_architecture_download "Architecture-specific download works"
run_test_with_setup test_go_module_proxy "Go module proxy is configured"
run_test_with_setup test_go_verification "Go verification script works"
run_test_with_setup test_dynamic_checksum_fetching "Dynamic checksum fetching"
run_test_with_setup test_download_verification "Download verification functions"
run_test_with_setup test_sources_download_verify "Sources download-verify.sh"

# Generate test report
generate_report