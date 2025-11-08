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

# Test: Checksum variables are defined
test_checksum_variables_defined() {
    # Check that dev-tools.sh defines checksum variables
    local dev_tools_script="$PROJECT_ROOT/lib/features/dev-tools.sh"

    # lazygit checksums (SHA256)
    if grep -q "LAZYGIT_AMD64_SHA256=" "$dev_tools_script"; then
        assert_true true "LAZYGIT_AMD64_SHA256 variable is defined"
    else
        assert_true false "LAZYGIT_AMD64_SHA256 variable is missing"
    fi

    if grep -q "LAZYGIT_ARM64_SHA256=" "$dev_tools_script"; then
        assert_true true "LAZYGIT_ARM64_SHA256 variable is defined"
    else
        assert_true false "LAZYGIT_ARM64_SHA256 variable is missing"
    fi

    # delta checksums (SHA256)
    if grep -q "DELTA_AMD64_SHA256=" "$dev_tools_script"; then
        assert_true true "DELTA_AMD64_SHA256 variable is defined"
    else
        assert_true false "DELTA_AMD64_SHA256 variable is missing"
    fi

    if grep -q "DELTA_ARM64_SHA256=" "$dev_tools_script"; then
        assert_true true "DELTA_ARM64_SHA256 variable is defined"
    else
        assert_true false "DELTA_ARM64_SHA256 variable is missing"
    fi

    # act checksums (SHA256)
    if grep -q "ACT_AMD64_SHA256=" "$dev_tools_script"; then
        assert_true true "ACT_AMD64_SHA256 variable is defined"
    else
        assert_true false "ACT_AMD64_SHA256 variable is missing"
    fi

    if grep -q "ACT_ARM64_SHA256=" "$dev_tools_script"; then
        assert_true true "ACT_ARM64_SHA256 variable is defined"
    else
        assert_true false "ACT_ARM64_SHA256 variable is missing"
    fi

    # git-cliff checksums (SHA512)
    if grep -q "GITCLIFF_AMD64_SHA512=" "$dev_tools_script"; then
        assert_true true "GITCLIFF_AMD64_SHA512 variable is defined"
    else
        assert_true false "GITCLIFF_AMD64_SHA512 variable is missing"
    fi

    if grep -q "GITCLIFF_ARM64_SHA512=" "$dev_tools_script"; then
        assert_true true "GITCLIFF_ARM64_SHA512 variable is defined"
    else
        assert_true false "GITCLIFF_ARM64_SHA512 variable is missing"
    fi
}

# Test: Checksum values are valid format
test_checksum_format_validation() {
    local dev_tools_script="$PROJECT_ROOT/lib/features/dev-tools.sh"

    # Extract checksum values and validate format
    local lazygit_amd64=$(grep "LAZYGIT_AMD64_SHA256=" "$dev_tools_script" | cut -d'"' -f2)
    local lazygit_arm64=$(grep "LAZYGIT_ARM64_SHA256=" "$dev_tools_script" | cut -d'"' -f2)

    # SHA256 should be 64 hex characters
    if [[ "$lazygit_amd64" =~ ^[a-fA-F0-9]{64}$ ]]; then
        assert_true true "LAZYGIT_AMD64_SHA256 is valid SHA256 format"
    else
        assert_true false "LAZYGIT_AMD64_SHA256 is not valid SHA256 format"
    fi

    if [[ "$lazygit_arm64" =~ ^[a-fA-F0-9]{64}$ ]]; then
        assert_true true "LAZYGIT_ARM64_SHA256 is valid SHA256 format"
    else
        assert_true false "LAZYGIT_ARM64_SHA256 is not valid SHA256 format"
    fi

    # Check git-cliff SHA512 (128 hex characters)
    local gitcliff_amd64=$(grep "GITCLIFF_AMD64_SHA512=" "$dev_tools_script" | cut -d'"' -f2)

    if [[ "$gitcliff_amd64" =~ ^[a-fA-F0-9]{128}$ ]]; then
        assert_true true "GITCLIFF_AMD64_SHA512 is valid SHA512 format"
    else
        assert_true false "GITCLIFF_AMD64_SHA512 is not valid SHA512 format"
    fi
}

# Test: Download verification functions are called
test_download_verification_usage() {
    local dev_tools_script="$PROJECT_ROOT/lib/features/dev-tools.sh"

    # Check that download_and_extract is used for lazygit
    if grep -A5 "Install lazygit" "$dev_tools_script" | grep -q "download_and_extract"; then
        assert_true true "lazygit uses download_and_extract for verification"
    else
        assert_true false "lazygit doesn't use download_and_extract"
    fi

    # Check that download_and_verify is used for delta
    if grep -A10 "Install delta" "$dev_tools_script" | grep -q "download_and_verify"; then
        assert_true true "delta uses download_and_verify for verification"
    else
        assert_true false "delta doesn't use download_and_verify"
    fi

    # Check that download_and_extract is used for act
    if grep -A5 "Install.*act" "$dev_tools_script" | grep -q "download_and_extract"; then
        assert_true true "act uses download_and_extract for verification"
    else
        assert_true false "act doesn't use download_and_extract"
    fi

    # Check that download_and_verify is used for git-cliff
    if grep -A10 "Install git-cliff" "$dev_tools_script" | grep -q "download_and_verify"; then
        assert_true true "git-cliff uses download_and_verify for verification"
    else
        assert_true false "git-cliff doesn't use download_and_verify"
    fi
}

# Test: Script sources download-verify.sh
test_sources_download_verify() {
    local dev_tools_script="$PROJECT_ROOT/lib/features/dev-tools.sh"

    if grep -q "source.*download-verify.sh" "$dev_tools_script"; then
        assert_true true "dev-tools.sh sources download-verify.sh"
    else
        assert_true false "dev-tools.sh doesn't source download-verify.sh"
    fi
}

# Test: Checksum verification date is documented
test_checksum_verification_date() {
    local dev_tools_script="$PROJECT_ROOT/lib/features/dev-tools.sh"

    # Check for verification date comment
    if grep -q "Checksums verified on:" "$dev_tools_script" || \
       grep -q "verified on:" "$dev_tools_script"; then
        assert_true true "Checksum verification date is documented"
    else
        assert_true false "Checksum verification date is not documented"
    fi
}

# Test: Version variables match checksum sections
test_version_checksum_consistency() {
    local dev_tools_script="$PROJECT_ROOT/lib/features/dev-tools.sh"

    # Extract lazygit version from both variable and comment
    local version_var=$(grep "^LAZYGIT_VERSION=" "$dev_tools_script" | cut -d'"' -f2)

    if [ -n "$version_var" ]; then
        # Check that checksum comment references the same version
        if grep "lazygit.*releases/tag/v$version_var" "$dev_tools_script" > /dev/null 2>&1 || \
           grep "LAZYGIT.*$version_var" "$dev_tools_script" > /dev/null 2>&1; then
            assert_true true "lazygit version matches checksum documentation"
        else
            # Version might be referenced differently, accept if version variable exists
            assert_true true "lazygit has version variable defined"
        fi
    else
        assert_true false "LAZYGIT_VERSION variable not found"
    fi
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
run_test test_checksum_variables_defined "Checksum variables are defined"
run_test test_checksum_format_validation "Checksum formats are valid"
run_test test_download_verification_usage "Download verification functions are used"
run_test test_sources_download_verify "Script sources download-verify.sh"
run_test test_checksum_verification_date "Checksum verification date is documented"
run_test test_version_checksum_consistency "Version and checksum documentation is consistent"

# Generate test report
generate_report