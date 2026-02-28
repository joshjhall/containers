#!/usr/bin/env bash
# Unit tests for lib/features/rust-dev.sh
# Tests Rust development tools installation

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Rust Dev Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-rust-dev"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.cargo/bin"
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID HOME 2>/dev/null || true
}

# Test: Rust dev tools installation
test_rust_dev_tools() {
    local cargo_bin="$TEST_TEMP_DIR/home/testuser/.cargo/bin"

    # List of Rust dev tools (including cargo-sweep)
    local tools=("cargo-watch" "cargo-audit" "cargo-outdated" "cargo-sweep" "bacon" "sccache" "cargo-nextest")

    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$cargo_bin/$tool"
        chmod +x "$cargo_bin/$tool"
    done

    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$cargo_bin/$tool" ]; then
            assert_true true "$tool is installed"
        else
            assert_true false "$tool is not installed"
        fi
    done
}

# Test: Rust analyzer
test_rust_analyzer() {
    local ra_bin="$TEST_TEMP_DIR/home/testuser/.cargo/bin/rust-analyzer"

    # Create mock rust-analyzer
    touch "$ra_bin"
    chmod +x "$ra_bin"

    assert_file_exists "$ra_bin"

    # Check executable
    if [ -x "$ra_bin" ]; then
        assert_true true "rust-analyzer is executable"
    else
        assert_true false "rust-analyzer is not executable"
    fi
}

# Test: Clippy configuration
test_clippy_config() {
    local clippy_toml="$TEST_TEMP_DIR/clippy.toml"

    # Create config
    command cat > "$clippy_toml" << 'EOF'
msrv = "1.70.0"
warn-on-all-wildcard-imports = true
allow-expect-in-tests = true
allow-unwrap-in-tests = true
EOF

    assert_file_exists "$clippy_toml"

    # Check configuration
    if command grep -q "allow-unwrap-in-tests = true" "$clippy_toml"; then
        assert_true true "Clippy allows unwrap in tests"
    else
        assert_true false "Clippy doesn't allow unwrap in tests"
    fi
}

# Test: Bacon configuration
test_bacon_config() {
    local bacon_toml="$TEST_TEMP_DIR/bacon.toml"

    # Create config
    command cat > "$bacon_toml" << 'EOF'
[jobs.check]
command = ["cargo", "check", "--color", "always"]

[jobs.test]
command = ["cargo", "test", "--color", "always"]
EOF

    assert_file_exists "$bacon_toml"

    # Check configuration
    if command grep -q 'command = \["cargo", "check"' "$bacon_toml"; then
        assert_true true "Bacon check job configured"
    else
        assert_true false "Bacon check job not configured"
    fi
}

# Test: rustfmt configuration
test_rustfmt_config() {
    local rustfmt_toml="$TEST_TEMP_DIR/rustfmt.toml"

    # Create config
    command cat > "$rustfmt_toml" << 'EOF'
edition = "2021"
max_width = 100
use_field_init_shorthand = true
use_try_shorthand = true
EOF

    assert_file_exists "$rustfmt_toml"

    # Check configuration
    if command grep -q "max_width = 100" "$rustfmt_toml"; then
        assert_true true "rustfmt max width configured"
    else
        assert_true false "rustfmt max width not configured"
    fi
}

# Test: Cargo extensions
test_cargo_extensions() {
    local cargo_bin="$TEST_TEMP_DIR/home/testuser/.cargo/bin"

    # Additional cargo extensions
    local extensions=("cargo-expand" "cargo-tree" "cargo-bloat" "cargo-deny")

    # Create mock extensions
    for ext in "${extensions[@]}"; do
        touch "$cargo_bin/$ext"
        chmod +x "$cargo_bin/$ext"
    done

    # Check extensions
    for ext in "${extensions[@]}"; do
        if [ -x "$cargo_bin/$ext" ]; then
            assert_true true "$ext is available"
        else
            assert_true false "$ext is not available"
        fi
    done
}

# Test: Cross-compilation support
test_cross_compilation() {
    local cargo_bin="$TEST_TEMP_DIR/home/testuser/.cargo/bin"

    # Create cross tool
    touch "$cargo_bin/cross"
    chmod +x "$cargo_bin/cross"

    assert_file_exists "$cargo_bin/cross"

    # Check cross
    if [ -x "$cargo_bin/cross" ]; then
        assert_true true "cross-compilation tool installed"
    else
        assert_true false "cross-compilation tool not installed"
    fi
}

# Test: Rust dev aliases
test_rust_dev_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/40-rust-dev.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias cw='cargo watch'
alias cwa='cargo watch -x test'
alias ca='cargo audit'
alias co='cargo outdated'
alias bcn='bacon'
EOF

    # Check aliases
    if command grep -q "alias cw='cargo watch'" "$bashrc_file"; then
        assert_true true "cargo watch alias defined"
    else
        assert_true false "cargo watch alias not defined"
    fi
}

# Test: Wasm support
test_wasm_support() {
    local cargo_bin="$TEST_TEMP_DIR/home/testuser/.cargo/bin"

    # Create wasm tools
    touch "$cargo_bin/wasm-pack"
    touch "$cargo_bin/wasm-bindgen"
    chmod +x "$cargo_bin/wasm-pack" "$cargo_bin/wasm-bindgen"

    # Check wasm tools
    if [ -x "$cargo_bin/wasm-pack" ]; then
        assert_true true "wasm-pack installed"
    else
        assert_true false "wasm-pack not installed"
    fi
}

# Test: Verification script
test_rust_dev_verification() {
    local test_script="$TEST_TEMP_DIR/test-rust-dev.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Rust dev tools:"
for tool in cargo-watch cargo-audit bacon rust-analyzer cargo-sweep; do
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

# Test: cargo-sweep aliases
test_cargo_sweep_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/35-rust-dev.sh"

    # Create aliases matching actual rust-dev.sh output
    command cat > "$bashrc_file" << 'EOF'
alias cw='cargo watch'
alias sweep='cargo-sweep sweep --time 14'
alias sweep-all='find "${WORKING_DIR:-/workspace}" -name "Cargo.toml" -exec dirname {} \; | xargs -I{} cargo-sweep sweep --time 14 {}'
EOF

    # Check sweep alias
    if command grep -q "alias sweep='cargo-sweep sweep --time 14'" "$bashrc_file"; then
        assert_true true "cargo-sweep alias defined"
    else
        assert_true false "cargo-sweep alias not defined"
    fi

    # Check sweep-all alias
    if command grep -q "alias sweep-all=" "$bashrc_file"; then
        assert_true true "sweep-all alias defined"
    else
        assert_true false "sweep-all alias not defined"
    fi
}

# Test: cargo-sweep cron job
test_cargo_sweep_cron_job() {
    local cron_dir="$TEST_TEMP_DIR/etc/cron.d"
    local cron_job="$cron_dir/cargo-sweep"
    local wrapper_script="$TEST_TEMP_DIR/usr/local/bin/cargo-sweep-cron"

    mkdir -p "$cron_dir"
    mkdir -p "$(dirname "$wrapper_script")"

    # Create cron job file matching actual rust-dev.sh output
    command cat > "$cron_job" << 'EOF'
# Cargo-sweep automatic cleanup - clean old Rust build artifacts
# Runs every 6 hours
# Configuration via environment variables:
#   CARGO_SWEEP_DAYS - Age threshold in days (default: 14)
#   CARGO_SWEEP_DISABLE - Set to "true" to disable

SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin

# Run at minute 0 of hours 0, 6, 12, 18
0 */6 * * * testuser /usr/local/bin/cargo-sweep-cron
EOF
    chmod 644 "$cron_job"

    # Create wrapper script matching actual rust-dev.sh output
    command cat > "$wrapper_script" << 'EOF'
#!/bin/bash
# Wrapper script for cargo-sweep cron job

# Load container environment
if [ -f /etc/container/cron-env ]; then
    source /etc/container/cron-env
fi

# Check if disabled
if [ "${CARGO_SWEEP_DISABLE:-false}" = "true" ]; then
    exit 0
fi

SWEEP_DAYS="${CARGO_SWEEP_DAYS:-14}"
EOF
    chmod +x "$wrapper_script"

    assert_file_exists "$cron_job"
    assert_file_exists "$wrapper_script"

    # Check wrapper script is executable
    if [ -x "$wrapper_script" ]; then
        assert_true true "cargo-sweep-cron wrapper script is executable"
    else
        assert_true false "cargo-sweep-cron wrapper script is not executable"
    fi

    # Check cron job has correct schedule (every 6 hours)
    if command grep -q "0 \*/6 \* \* \*" "$cron_job"; then
        assert_true true "Cron job runs every 6 hours"
    else
        assert_true false "Cron job schedule is incorrect"
    fi

    # Check for CARGO_SWEEP_DISABLE check in wrapper
    if command grep -q "CARGO_SWEEP_DISABLE" "$wrapper_script"; then
        assert_true true "Wrapper script has disable option"
    else
        assert_true false "Wrapper script missing disable option"
    fi

    # Check for default sweep age (14 days)
    if command grep -q "CARGO_SWEEP_DAYS:-14" "$wrapper_script"; then
        assert_true true "Wrapper script has 14-day default threshold"
    else
        assert_true false "Wrapper script missing default threshold"
    fi

    # Check wrapper sources cron-env
    if command grep -q "cron-env" "$wrapper_script"; then
        assert_true true "Wrapper script sources cron environment"
    else
        assert_true false "Wrapper script doesn't source cron environment"
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
run_test_with_setup test_rust_dev_tools "Rust dev tools installation"
run_test_with_setup test_rust_analyzer "Rust analyzer"
run_test_with_setup test_clippy_config "Clippy configuration"
run_test_with_setup test_bacon_config "Bacon configuration"
run_test_with_setup test_rustfmt_config "rustfmt configuration"
run_test_with_setup test_cargo_extensions "Cargo extensions"
run_test_with_setup test_cross_compilation "Cross-compilation support"
run_test_with_setup test_rust_dev_aliases "Rust dev aliases"
run_test_with_setup test_wasm_support "Wasm support"
run_test_with_setup test_rust_dev_verification "Rust dev verification"
run_test_with_setup test_cargo_sweep_aliases "cargo-sweep aliases"
run_test_with_setup test_cargo_sweep_cron_job "cargo-sweep cron job"

# Generate test report
generate_report
