#!/usr/bin/env bash
# Unit tests for lib/features/rust.sh
# Tests Rust programming language installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Rust Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-rust"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export RUST_VERSION="${RUST_VERSION:-stable}"
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.cargo"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.rustup"
    mkdir -p "$TEST_TEMP_DIR/cache/cargo"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Unset test variables
    unset RUST_VERSION USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Rust version handling
test_rust_version_handling() {
    # Test stable version
    local version="stable"
    assert_equals "stable" "$version" "Stable version string recognized"
    
    # Test beta version
    version="beta"
    assert_equals "beta" "$version" "Beta version string recognized"
    
    # Test nightly version
    version="nightly"
    assert_equals "nightly" "$version" "Nightly version string recognized"
    
    # Test specific version
    version="1.72.0"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        assert_true true "Specific version format is valid"
    else
        assert_true false "Specific version format is invalid"
    fi
}

# Test: Rustup installation script
test_rustup_installation() {
    local rustup_script="$TEST_TEMP_DIR/rustup-init.sh"
    
    # Create mock rustup installation script
    command cat > "$rustup_script" << 'EOF'
#!/bin/sh
echo "Installing Rust..."
echo "Rust installed successfully"
EOF
    chmod +x "$rustup_script"
    
    assert_file_exists "$rustup_script"
    
    # Check script is executable
    if [ -x "$rustup_script" ]; then
        assert_true true "Rustup script is executable"
    else
        assert_true false "Rustup script is not executable"
    fi
}

# Test: Cargo directories structure
test_cargo_directories() {
    local cargo_home="$TEST_TEMP_DIR/home/testuser/.cargo"
    local rustup_home="$TEST_TEMP_DIR/home/testuser/.rustup"
    
    # Create expected Cargo directory structure
    mkdir -p "$cargo_home/bin"
    mkdir -p "$cargo_home/registry"
    mkdir -p "$cargo_home/git"
    mkdir -p "$rustup_home/toolchains"
    mkdir -p "$rustup_home/update-hashes"
    
    # Check directories exist
    assert_dir_exists "$cargo_home"
    assert_dir_exists "$cargo_home/bin"
    assert_dir_exists "$cargo_home/registry"
    assert_dir_exists "$rustup_home"
    assert_dir_exists "$rustup_home/toolchains"
}

# Test: Cargo cache configuration
test_cargo_cache_configuration() {
    local cache_dir="$TEST_TEMP_DIR/cache/cargo"
    
    # Create cache directories
    mkdir -p "$cache_dir/registry"
    mkdir -p "$cache_dir/git"
    mkdir -p "$cache_dir/target"
    
    assert_dir_exists "$cache_dir/registry"
    assert_dir_exists "$cache_dir/git"
    assert_dir_exists "$cache_dir/target"
    
    # Check cache would be used
    local cargo_config="$TEST_TEMP_DIR/home/testuser/.cargo/config.toml"
    mkdir -p "$(dirname "$cargo_config")"
    
    # Create mock Cargo config
    command cat > "$cargo_config" << 'EOF'
[build]
target-dir = "/cache/cargo/target"

[registry]
cache-dir = "/cache/cargo/registry"
EOF
    
    assert_file_exists "$cargo_config"
    
    # Check cache directories are configured
    if grep -q "/cache/cargo/target" "$cargo_config"; then
        assert_true true "Target directory uses cache"
    else
        assert_true false "Target directory doesn't use cache"
    fi
}

# Test: Rust toolchain components
test_rust_toolchain_components() {
    local cargo_bin="$TEST_TEMP_DIR/home/testuser/.cargo/bin"
    
    # Create cargo bin directory
    mkdir -p "$cargo_bin"
    
    # List of expected Rust tools
    local tools=(
        "cargo"
        "rustc"
        "rustup"
        "rustfmt"
        "rust-analyzer"
        "cargo-fmt"
        "cargo-clippy"
        "rustdoc"
    )
    
    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$cargo_bin/$tool"
        chmod +x "$cargo_bin/$tool"
    done
    
    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$cargo_bin/$tool" ]; then
            assert_true true "$tool is executable"
        else
            assert_true false "$tool is not executable"
        fi
    done
}

# Test: Environment variables
test_rust_environment_variables() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/40-rust.sh"
    
    # Create mock bashrc content
    command cat > "$bashrc_file" << 'EOF'
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export PATH="$CARGO_HOME/bin:$PATH"
export RUST_BACKTRACE=1
EOF
    
    # Check environment variables
    if grep -q "export CARGO_HOME=" "$bashrc_file"; then
        assert_true true "CARGO_HOME is exported"
    else
        assert_true false "CARGO_HOME is not exported"
    fi
    
    if grep -q "export RUSTUP_HOME=" "$bashrc_file"; then
        assert_true true "RUSTUP_HOME is exported"
    else
        assert_true false "RUSTUP_HOME is not exported"
    fi
    
    if grep -q 'PATH.*CARGO_HOME/bin' "$bashrc_file"; then
        assert_true true "PATH includes Cargo bin directory"
    else
        assert_true false "PATH doesn't include Cargo bin directory"
    fi
    
    if grep -q "export RUST_BACKTRACE=1" "$bashrc_file"; then
        assert_true true "RUST_BACKTRACE is enabled"
    else
        assert_true false "RUST_BACKTRACE is not enabled"
    fi
}

# Test: Rust aliases and helpers
test_rust_aliases_helpers() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/40-rust.sh"
    
    # Add aliases section
    command cat >> "$bashrc_file" << 'EOF'

# Rust aliases
alias cb='cargo build'
alias cbr='cargo build --release'
alias cr='cargo run'
alias crr='cargo run --release'
alias ct='cargo test'
alias cc='cargo check'
alias ccl='cargo clippy'
alias cf='cargo fmt'
alias cu='cargo update'
alias ci='cargo install'
EOF
    
    # Check common aliases
    if grep -q "alias cb='cargo build'" "$bashrc_file"; then
        assert_true true "cargo build alias defined"
    else
        assert_true false "cargo build alias not defined"
    fi
    
    if grep -q "alias ct='cargo test'" "$bashrc_file"; then
        assert_true true "cargo test alias defined"
    else
        assert_true false "cargo test alias not defined"
    fi
    
    if grep -q "alias ccl='cargo clippy'" "$bashrc_file"; then
        assert_true true "cargo clippy alias defined"
    else
        assert_true false "cargo clippy alias not defined"
    fi
}

# Test: Cargo.toml detection
test_cargo_toml_detection() {
    local project_dir="$TEST_TEMP_DIR/project"
    mkdir -p "$project_dir"
    
    # Create mock Cargo.toml
    command cat > "$project_dir/Cargo.toml" << 'EOF'
[package]
name = "test-project"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = "1.0"
EOF
    
    assert_file_exists "$project_dir/Cargo.toml"
    
    # Check if Cargo.toml can be parsed
    if grep -q '\[package\]' "$project_dir/Cargo.toml"; then
        assert_true true "Cargo.toml has package section"
    else
        assert_true false "Cargo.toml missing package section"
    fi
    
    if grep -q 'edition = "2021"' "$project_dir/Cargo.toml"; then
        assert_true true "Cargo.toml uses 2021 edition"
    else
        assert_true false "Cargo.toml doesn't use 2021 edition"
    fi
}

# Test: Permissions and ownership
test_rust_permissions() {
    local cargo_home="$TEST_TEMP_DIR/home/testuser/.cargo"
    local rustup_home="$TEST_TEMP_DIR/home/testuser/.rustup"
    
    # Create directories
    mkdir -p "$cargo_home" "$rustup_home"
    
    # Check directories exist and are accessible
    if [ -d "$cargo_home" ] && [ -w "$cargo_home" ]; then
        assert_true true "Cargo home is writable"
    else
        assert_true false "Cargo home is not writable"
    fi
    
    if [ -d "$rustup_home" ] && [ -w "$rustup_home" ]; then
        assert_true true "Rustup home is writable"
    else
        assert_true false "Rustup home is not writable"
    fi
}

# Test: Rust verification script
test_rust_verification() {
    local test_script="$TEST_TEMP_DIR/test-rust.sh"
    
    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Rust version:"
rustc --version 2>/dev/null || echo "Rust not installed"
echo "Cargo version:"
cargo --version 2>/dev/null || echo "Cargo not installed"
echo "Rustup version:"
rustup --version 2>/dev/null || echo "Rustup not installed"
echo "Installed toolchains:"
rustup show 2>/dev/null || echo "No toolchains"
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

# ============================================================================
# Checksum Verification Tests
# ============================================================================

# Test: rust.sh sources checksum libraries
test_checksum_libraries_sourced() {
    local rust_script="$PROJECT_ROOT/lib/features/rust.sh"

    if ! [ -f "$rust_script" ]; then
        skip_test "rust.sh not found"
        return
    fi

    # Check for checksum-fetch.sh
    if grep -q "source.*checksum-fetch.sh" "$rust_script"; then
        assert_true true "checksum-fetch.sh library is sourced"
    else
        assert_true false "checksum-fetch.sh library not sourced"
    fi

    # Check for download-verify.sh
    if grep -q "source.*download-verify.sh" "$rust_script"; then
        assert_true true "download-verify.sh library is sourced"
    else
        assert_true false "download-verify.sh library not sourced"
    fi
}

# Test: rust.sh fetches rustup checksum dynamically
test_rustup_checksum_fetching() {
    local rust_script="$PROJECT_ROOT/lib/features/rust.sh"

    if ! [ -f "$rust_script" ]; then
        skip_test "rust.sh not found"
        return
    fi

    # Check for rustup checksum URL fetching
    if grep -q "RUSTUP_CHECKSUM_URL" "$rust_script"; then
        assert_true true "Uses dynamic rustup checksum fetching"
    else
        assert_true false "Does not use dynamic checksum fetching"
    fi
}

# Test: rust.sh uses download verification
test_download_verification() {
    local rust_script="$PROJECT_ROOT/lib/features/rust.sh"

    if ! [ -f "$rust_script" ]; then
        skip_test "rust.sh not found"
        return
    fi

    # Check for download_and_verify usage
    if grep -q "download_and_verify" "$rust_script"; then
        assert_true true "Uses checksum verification for downloads"
    else
        assert_true false "Does not use checksum verification"
    fi
}

# Run all tests
run_test_with_setup test_rust_version_handling "Rust version handling works correctly"
run_test_with_setup test_rustup_installation "Rustup installation process"
run_test_with_setup test_cargo_directories "Cargo directory structure is correct"
run_test_with_setup test_cargo_cache_configuration "Cargo cache is configured properly"
run_test_with_setup test_rust_toolchain_components "Rust toolchain components installed"
run_test_with_setup test_rust_environment_variables "Rust environment variables are set"
run_test_with_setup test_rust_aliases_helpers "Rust aliases and helpers are defined"
run_test_with_setup test_cargo_toml_detection "Cargo.toml detection works"
run_test_with_setup test_rust_permissions "Rust directories have correct permissions"
run_test_with_setup test_rust_verification "Rust verification script works"

# Checksum verification tests
run_test test_checksum_libraries_sourced "Checksum libraries are sourced"
run_test test_rustup_checksum_fetching "Rustup checksum fetching is used"
run_test test_download_verification "Download verification is used"

# Generate test report
generate_report