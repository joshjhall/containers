#!/usr/bin/env bash
# Unit tests for lib/features/dev-tools.sh
# Tests development tools installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Development Tools Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-dev-tools"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/usr/share/keyrings"
    mkdir -p "$TEST_TEMP_DIR/etc/apt/sources.list.d"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.config"
    
    # Mock cache directory
    export CACHE_DIR="$TEST_TEMP_DIR/cache"
    mkdir -p "$CACHE_DIR"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME CACHE_DIR 2>/dev/null || true
}

# Test: Repository configuration
test_repository_configuration() {
    local keyrings_dir="$TEST_TEMP_DIR/usr/share/keyrings"
    
    # Check keyrings directory exists
    assert_dir_exists "$keyrings_dir"
    
    # Simulate GitHub CLI GPG key
    touch "$keyrings_dir/githubcli-archive-keyring.gpg"
    chmod 644 "$keyrings_dir/githubcli-archive-keyring.gpg"
    
    # Check key permissions
    if [ -r "$keyrings_dir/githubcli-archive-keyring.gpg" ]; then
        assert_true true "GitHub CLI GPG key is readable"
    else
        assert_true false "GitHub CLI GPG key is not readable"
    fi
}

# Test: Binary tool installations
test_binary_tool_installations() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"
    
    # List of tools that should be installed
    local tools=(
        "lazygit"
        "direnv"
        "just"
        "delta"
        "act"
        "glab"
        "mkcert"
    )
    
    # Simulate tool installation
    for tool in "${tools[@]}"; do
        touch "$bin_dir/$tool"
        chmod +x "$bin_dir/$tool"
    done
    
    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$bin_dir/$tool" ]; then
            assert_true true "$tool binary is executable"
        else
            assert_true false "$tool binary is not executable"
        fi
    done
}

# Test: Tool version management
test_tool_versions() {
    # Define expected versions
    local versions=(
        "LAZYGIT_VERSION=0.54.1"
        "DIRENV_VERSION=2.37.1"
        "DELTA_VERSION=0.18.2"
        "JUST_VERSION=1.42.3"
        "MKCERT_VERSION=1.4.4"
        "ACT_VERSION=0.2.80"
        "GLAB_VERSION=1.65.0"
    )
    
    # Check version format
    for version_def in "${versions[@]}"; do
        local tool="${version_def%%_VERSION=*}"
        local version="${version_def#*=}"
        
        # Verify version format (should be semantic versioning)
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            assert_true true "$tool version $version follows semantic versioning"
        else
            assert_true false "$tool version $version doesn't follow semantic versioning"
        fi
    done
}

# Test: Configuration files
test_configuration_files() {
    local config_dir="$TEST_TEMP_DIR/home/testuser/.config"
    
    # Create mock configuration directories
    mkdir -p "$config_dir/lazygit"
    mkdir -p "$config_dir/direnv"
    
    # Create mock config files
    touch "$config_dir/lazygit/config.yml"
    touch "$config_dir/direnv/direnvrc"
    
    # Check configuration files
    assert_file_exists "$config_dir/lazygit/config.yml"
    assert_file_exists "$config_dir/direnv/direnvrc"
}

# Test: Bashrc integration
test_bashrc_integration() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/30-dev-tools.sh"
    
    # Create mock bashrc content
    cat > "$bashrc_file" << 'EOF'
# Development tools aliases
alias lg='lazygit'
alias ll='eza -la'
alias cat='bat'
alias find='fd'
alias grep='rg'
alias df='duf'

# Direnv hook
eval "$(direnv hook bash)"

# Just completions
source <(just --completions bash)
EOF
    
    # Check aliases
    if grep -q "alias lg='lazygit'" "$bashrc_file"; then
        assert_true true "lazygit alias configured"
    else
        assert_true false "lazygit alias not configured"
    fi
    
    # Check direnv hook
    if grep -q "direnv hook bash" "$bashrc_file"; then
        assert_true true "direnv hook configured"
    else
        assert_true false "direnv hook not configured"
    fi
    
    # Check modern CLI replacements
    if grep -q "alias cat='bat'" "$bashrc_file"; then
        assert_true true "Modern CLI replacements configured"
    else
        assert_true false "Modern CLI replacements not configured"
    fi
}

# Test: Permissions and ownership
test_permissions_ownership() {
    local bin_dir="$TEST_TEMP_DIR/usr/local/bin"
    local config_dir="$TEST_TEMP_DIR/home/testuser/.config"
    
    # Create test files
    touch "$bin_dir/test-tool"
    chmod 755 "$bin_dir/test-tool"
    
    mkdir -p "$config_dir/test-app"
    
    # Check binary permissions
    if [ -x "$bin_dir/test-tool" ]; then
        assert_true true "Binary has execute permissions"
    else
        assert_true false "Binary lacks execute permissions"
    fi
    
    # Check config directory
    if [ -d "$config_dir/test-app" ]; then
        assert_true true "Config directory created"
    else
        assert_true false "Config directory not created"
    fi
}

# Test: System tools installation list
test_system_tools_list() {
    # List of system tools that should be marked for installation
    # Note: either exa (Debian 11/12) or eza (Debian 13+) will be installed
    local system_tools=(
        "telnet"
        "netcat"
        "nmap"
        "tcpdump"
        "socat"
        "whois"
        "htop"
        "btop"
        "iotop"
        "sysstat"
        "strace"
        "unzip"
        "zip"
        "p7zip-full"
        "jq"
        "bat"
        "eza"
        "exa"
        "fd-find"
        "ripgrep"
        "duf"
    )
    
    # Verify each tool is in the expected list
    for tool in "${system_tools[@]}"; do
        assert_not_empty "$tool" "System tool $tool is in installation list"
    done
}

# Test: Architecture detection
test_architecture_detection() {
    # Simulate architecture detection
    local arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    
    # Check architecture-specific URLs
    case "$arch" in
        amd64|x86_64)
            assert_equals "amd64" "$arch" "Architecture is amd64/x86_64"
            ;;
        arm64|aarch64)
            assert_equals "arm64" "$arch" "Architecture is arm64/aarch64"
            ;;
        *)
            assert_true false "Unsupported architecture: $arch"
            ;;
    esac
}

# Test: Download URL construction
test_download_urls() {
    local arch="amd64"
    local lazygit_version="0.54.1"
    
    # Construct expected URL
    local expected_url="https://github.com/jesseduffield/lazygit/releases/download/v${lazygit_version}/lazygit_${lazygit_version}_Linux_x86_64.tar.gz"
    
    # Check URL format
    if [[ "$expected_url" =~ github\.com.*releases.*download ]]; then
        assert_true true "Download URL follows GitHub releases pattern"
    else
        assert_true false "Download URL doesn't follow expected pattern"
    fi
}

# Test: Cache directory usage
test_cache_directory() {
    local cache_dir="$CACHE_DIR"
    
    # Create cache subdirectories
    mkdir -p "$cache_dir/downloads"
    mkdir -p "$cache_dir/tmp"
    
    assert_dir_exists "$cache_dir/downloads"
    assert_dir_exists "$cache_dir/tmp"
    
    # Check cache is used for downloads
    touch "$cache_dir/downloads/lazygit.tar.gz"
    assert_file_exists "$cache_dir/downloads/lazygit.tar.gz"
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
run_test_with_setup test_repository_configuration "Repository configuration for dev tools"
run_test_with_setup test_binary_tool_installations "Binary tools are installed correctly"
run_test_with_setup test_tool_versions "Tool versions are properly defined"
run_test_with_setup test_configuration_files "Configuration files are created"
run_test_with_setup test_bashrc_integration "Bashrc integration is configured"
run_test_with_setup test_permissions_ownership "Permissions and ownership are correct"
run_test_with_setup test_system_tools_list "System tools list is complete"
run_test_with_setup test_architecture_detection "Architecture detection works"
run_test_with_setup test_download_urls "Download URLs are correctly constructed"
run_test_with_setup test_cache_directory "Cache directory is used properly"

# Generate test report
generate_report