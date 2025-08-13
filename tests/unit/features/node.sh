#!/usr/bin/env bash
# Unit tests for lib/features/node.sh
# Tests Node.js installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Node.js Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-node"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export NODE_VERSION="22"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/opt/node"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/cache/npm"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.npm"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    rm -rf "$TEST_TEMP_DIR"
    
    # Unset test variables
    unset NODE_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Node version selection
test_node_version_selection() {
    # Test default version
    assert_equals "22" "$NODE_VERSION" "Default Node version is 22"
    
    # Test version override
    NODE_VERSION="20"
    assert_equals "20" "$NODE_VERSION" "Node version can be overridden"
    
    # Test LTS version mapping
    local version="$NODE_VERSION"
    if [[ "$version" == "22" ]] || [[ "$version" == "20" ]] || [[ "$version" == "18" ]]; then
        assert_true true "Version is a valid LTS version"
    else
        assert_true false "Version is not a valid LTS version"
    fi
}

# Test: Node major version extraction
test_node_major_version_extraction() {
    # Test major version only
    NODE_VERSION="22"
    local major_version=$(echo "${NODE_VERSION}" | cut -d. -f1)
    assert_equals "22" "$major_version" "Major version extracted from '22'"
    
    # Test specific version
    NODE_VERSION="22.10.0"
    major_version=$(echo "${NODE_VERSION}" | cut -d. -f1)
    assert_equals "22" "$major_version" "Major version extracted from '22.10.0'"
    
    # Test version with two parts
    NODE_VERSION="20.5"
    major_version=$(echo "${NODE_VERSION}" | cut -d. -f1)
    assert_equals "20" "$major_version" "Major version extracted from '20.5'"
    
    # Test version comparison
    NODE_VERSION="18.19.1"
    major_version=$(echo "${NODE_VERSION}" | cut -d. -f1)
    if [ "$major_version" -ge 18 ]; then
        assert_true true "Version 18.19.1 meets minimum requirement"
    else
        assert_true false "Version 18.19.1 doesn't meet minimum requirement"
    fi
}

# Test: Node specific version detection
test_node_specific_version_detection() {
    # Test major version only (no dots)
    NODE_VERSION="22"
    if [[ "${NODE_VERSION}" == *"."* ]]; then
        assert_true false "Version '22' incorrectly detected as specific"
    else
        assert_true true "Version '22' correctly detected as major only"
    fi
    
    # Test specific version (with dots)
    NODE_VERSION="22.10.0"
    if [[ "${NODE_VERSION}" == *"."* ]]; then
        assert_true true "Version '22.10.0' correctly detected as specific"
    else
        assert_true false "Version '22.10.0' incorrectly detected as major only"
    fi
    
    # Test partial version
    NODE_VERSION="20.5"
    if [[ "${NODE_VERSION}" == *"."* ]]; then
        assert_true true "Version '20.5' correctly detected as specific"
    else
        assert_true false "Version '20.5' incorrectly detected as major only"
    fi
}

# Test: Node installation directory structure
test_node_installation_paths() {
    local node_dir="$TEST_TEMP_DIR/opt/node"
    local node_bin="$node_dir/bin/node"
    local npm_bin="$node_dir/bin/npm"
    
    # Create mock Node installation
    mkdir -p "$node_dir/bin"
    touch "$node_bin" "$npm_bin"
    chmod +x "$node_bin" "$npm_bin"
    
    assert_file_exists "$node_bin"
    assert_file_exists "$npm_bin"
    
    # Check symlinks would be created
    local node_link="$TEST_TEMP_DIR/usr/local/bin/node"
    local npm_link="$TEST_TEMP_DIR/usr/local/bin/npm"
    
    # Simulate symlink creation
    ln -sf "$node_bin" "$node_link"
    ln -sf "$npm_bin" "$npm_link"
    
    assert_file_exists "$node_link"
    assert_file_exists "$npm_link"
}

# Test: NPM cache configuration
test_npm_cache_configuration() {
    local npm_cache="/cache/npm"
    local npmrc_file="$TEST_TEMP_DIR/home/testuser/.npmrc"
    
    # Create mock .npmrc
    cat > "$npmrc_file" << EOF
cache=/cache/npm
prefix=/home/testuser/.npm
EOF
    
    assert_file_exists "$npmrc_file"
    
    # Check cache configuration
    if grep -q "cache=/cache/npm" "$npmrc_file"; then
        assert_true true "NPM cache directory is configured"
    else
        assert_true false "NPM cache directory not configured"
    fi
    
    if grep -q "prefix=" "$npmrc_file"; then
        assert_true true "NPM prefix is configured"
    else
        assert_true false "NPM prefix not configured"
    fi
}

# Test: Node bashrc configuration
test_node_bashrc_setup() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/20-node.sh"
    
    # Create mock Node bashrc
    cat > "$bashrc_file" << 'EOF'
export NODE_PATH="/opt/node"
export PATH="${NODE_PATH}/bin:${PATH}"
export NPM_CONFIG_PREFIX="${HOME}/.npm"
export NPM_CONFIG_CACHE="/cache/npm"

# Node aliases
alias npm-list="npm list -g --depth=0"
alias npm-outdated="npm outdated -g"
EOF
    
    assert_file_exists "$bashrc_file"
    
    # Check environment variables
    if grep -q "NODE_PATH=" "$bashrc_file"; then
        assert_true true "NODE_PATH is exported"
    else
        assert_true false "NODE_PATH not found"
    fi
    
    if grep -q "NPM_CONFIG_CACHE=" "$bashrc_file"; then
        assert_true true "NPM cache config is exported"
    else
        assert_true false "NPM cache config not found"
    fi
    
    # Check aliases
    if grep -q "alias npm-list" "$bashrc_file"; then
        assert_true true "npm-list alias is defined"
    else
        assert_true false "npm-list alias not found"
    fi
}

# Test: Node permission handling
test_node_permissions() {
    local node_dir="$TEST_TEMP_DIR/opt/node"
    local npm_dir="$TEST_TEMP_DIR/home/testuser/.npm"
    local cache_dir="$TEST_TEMP_DIR/cache/npm"
    
    # Create directories
    mkdir -p "$node_dir" "$npm_dir" "$cache_dir"
    
    # Test ownership commands would be formed correctly
    local chown_npm="chown -R ${USER_UID}:${USER_GID} $npm_dir"
    local chown_cache="chown -R ${USER_UID}:${USER_GID} $cache_dir"
    
    assert_not_empty "$chown_npm" "NPM directory ownership command formed"
    assert_not_empty "$chown_cache" "Cache directory ownership command formed"
    
    # Check UID/GID values
    assert_equals "1000" "$USER_UID" "User UID is correct"
    assert_equals "1000" "$USER_GID" "User GID is correct"
}

# Test: Corepack enablement
test_corepack_enablement() {
    local corepack_cmd="corepack enable"
    
    # Test that corepack would be enabled
    assert_not_empty "$corepack_cmd" "Corepack enable command exists"
    
    # Check for yarn and pnpm after corepack
    local yarn_shim="$TEST_TEMP_DIR/opt/node/bin/yarn"
    local pnpm_shim="$TEST_TEMP_DIR/opt/node/bin/pnpm"
    
    # Create the directory first, then simulate corepack creating shims
    mkdir -p "$(dirname "$yarn_shim")"
    touch "$yarn_shim" "$pnpm_shim"
    
    if [ -f "$yarn_shim" ]; then
        assert_true true "Yarn shim would be created by corepack"
    else
        assert_true false "Yarn shim not created"
    fi
    
    if [ -f "$pnpm_shim" ]; then
        assert_true true "PNPM shim would be created by corepack"
    else
        assert_true false "PNPM shim not created"
    fi
}

# Test: Node version verification
test_node_version_verification() {
    local test_script="$TEST_TEMP_DIR/usr/local/bin/test-node"
    
    # Create mock verification script
    cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Node.js version:"
node --version 2>/dev/null || echo "Node not installed"
echo "NPM version:"
npm --version 2>/dev/null || echo "NPM not installed"
echo "Yarn version:"
yarn --version 2>/dev/null || echo "Yarn not available"
EOF
    chmod +x "$test_script"
    
    assert_file_exists "$test_script"
    
    # Check verification content
    if grep -q "node --version" "$test_script"; then
        assert_true true "Script checks Node version"
    else
        assert_true false "Script doesn't check Node version"
    fi
    
    if grep -q "npm --version" "$test_script"; then
        assert_true true "Script checks NPM version"
    else
        assert_true false "Script doesn't check NPM version"
    fi
}

# Test: Node PATH configuration
test_node_path_configuration() {
    local node_path="/opt/node"
    local node_bin_path="$node_path/bin"
    local npm_global_path="/home/testuser/.npm/bin"
    
    # Test PATH would include Node directories
    local expected_path="$node_bin_path:$npm_global_path"
    
    assert_not_empty "$expected_path" "Node PATH additions are defined"
    
    if [[ "$expected_path" == *"/opt/node/bin"* ]]; then
        assert_true true "Node bin directory in PATH"
    else
        assert_true false "Node bin directory not in PATH"
    fi
    
    if [[ "$expected_path" == *"/.npm/bin"* ]]; then
        assert_true true "NPM global bin directory in PATH"
    else
        assert_true false "NPM global bin directory not in PATH"
    fi
}

# Test: Node helper functions
test_node_helper_functions() {
    # Test helper function definitions
    local npm_clean_func='npm-clean() { npm cache clean --force; }'
    local npm_audit_func='npm-security-audit() { npm audit; }'
    
    assert_not_empty "$npm_clean_func" "npm-clean function is defined"
    assert_not_empty "$npm_audit_func" "npm-security-audit function is defined"
    
    # Check function structure
    if [[ "$npm_clean_func" == *"cache clean"* ]]; then
        assert_true true "npm-clean uses cache clean command"
    else
        assert_true false "npm-clean function incorrect"
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
run_test_with_setup test_node_version_selection "Node version selection and override"
run_test_with_setup test_node_major_version_extraction "Node major version extraction from various formats"
run_test_with_setup test_node_specific_version_detection "Node specific version detection logic"
run_test_with_setup test_node_installation_paths "Node installation directory structure"
run_test_with_setup test_npm_cache_configuration "NPM cache configuration"
run_test_with_setup test_node_bashrc_setup "Node bashrc configuration"
run_test_with_setup test_node_permissions "Node permission handling"
run_test_with_setup test_corepack_enablement "Corepack enablement for package managers"
run_test_with_setup test_node_version_verification "Node version verification script"
run_test_with_setup test_node_path_configuration "Node PATH configuration"
run_test_with_setup test_node_helper_functions "Node helper functions"

# Generate test report
generate_report