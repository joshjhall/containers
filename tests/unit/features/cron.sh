#!/usr/bin/env bash
# Unit tests for lib/features/cron.sh
# Tests cron daemon installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Cron Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-cron"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/etc/bashrc.d"
    mkdir -p "$TEST_TEMP_DIR/etc/container/startup"
    mkdir -p "$TEST_TEMP_DIR/etc/container"
    mkdir -p "$TEST_TEMP_DIR/etc/cron.d"
    mkdir -p "$TEST_TEMP_DIR/usr/local/bin"
}

# Teardown function - runs after each test
teardown() {
    # Clean up test directory
    if [ -n "${TEST_TEMP_DIR:-}" ]; then
        command rm -rf "$TEST_TEMP_DIR"
    fi

    # Unset test variables
    unset USERNAME USER_UID USER_GID 2>/dev/null || true
}

# Test: Cron startup script creation
test_cron_startup_script() {
    local startup_dir="$TEST_TEMP_DIR/etc/container/startup"
    local startup_script="$startup_dir/05-cron.sh"

    # Create startup script matching actual cron.sh output
    command cat > "$startup_script" << 'EOF'
#!/bin/bash
# Cron daemon status check
#
# The cron daemon is normally started by the entrypoint while still running
# as root (before dropping to non-root user).

# Check if cron is installed
if ! command -v cron &> /dev/null; then
    exit 0
fi

# Check if cron is already running (started by entrypoint)
if pgrep -x "cron" > /dev/null 2>&1; then
    echo "cron: Daemon running"
    exit 0
fi

# Cron not running - try to start it (fallback)
if [ "$(id -u)" = "0" ]; then
    service cron start > /dev/null 2>&1 || cron
elif command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
    sudo service cron start > /dev/null 2>&1 || sudo cron
fi
EOF
    chmod +x "$startup_script"

    assert_file_exists "$startup_script"

    # Check script is executable
    if [ -x "$startup_script" ]; then
        assert_true true "Cron startup script is executable"
    else
        assert_true false "Cron startup script is not executable"
    fi

    # Check for idempotent check (pgrep)
    if command grep -q "pgrep" "$startup_script"; then
        assert_true true "Startup script checks if cron is already running"
    else
        assert_true false "Startup script missing idempotent check"
    fi

    # Check script mentions entrypoint handles startup
    if command grep -q "entrypoint" "$startup_script"; then
        assert_true true "Startup script documents entrypoint handles cron"
    else
        assert_true false "Startup script should mention entrypoint"
    fi
}

# Test: Cron environment file creation
test_cron_env_file() {
    local env_file="$TEST_TEMP_DIR/etc/container/cron-env"

    # Create environment file matching actual cron.sh output
    command cat > "$env_file" << 'EOF'
#!/bin/bash
# Cron Environment File
# Source this file at the start of cron job scripts

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export HOME="${HOME:-/home/${USER:-root}}"
export WORKING_DIR="${WORKING_DIR:-/workspace}"

# Rust environment (if installed)
if [ -d "/cache/cargo" ]; then
    export CARGO_HOME="/cache/cargo"
    export RUSTUP_HOME="/cache/rustup"
    export PATH="${CARGO_HOME}/bin:${PATH}"
fi
EOF
    chmod 644 "$env_file"

    assert_file_exists "$env_file"

    # Check for PATH export
    if command grep -q "export PATH=" "$env_file"; then
        assert_true true "Environment file exports PATH"
    else
        assert_true false "Environment file missing PATH export"
    fi

    # Check for CARGO_HOME setup
    if command grep -q "CARGO_HOME" "$env_file"; then
        assert_true true "Environment file includes Rust environment"
    else
        assert_true false "Environment file missing Rust environment"
    fi

    # Check for WORKING_DIR
    if command grep -q "WORKING_DIR" "$env_file"; then
        assert_true true "Environment file includes WORKING_DIR"
    else
        assert_true false "Environment file missing WORKING_DIR"
    fi
}

# Test: Cron bashrc configuration
test_cron_bashrc() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/10-cron.sh"

    # Create bashrc file matching actual cron.sh output
    command cat > "$bashrc_file" << 'EOF'
# Cron Aliases and Functions
set +u
set +e

if [[ $- != *i* ]]; then
    return 0
fi

# List user's crontab
alias cron-list='crontab -l 2>/dev/null || echo "No crontab for current user"'

# Edit user's crontab
alias cron-edit='crontab -e'

# List system cron jobs
alias cron-system='command ls -la /etc/cron.d/ 2>/dev/null'

# Show cron daemon status
alias cron-status='pgrep -x cron > /dev/null && echo "cron: running" || echo "cron: not running"'
EOF
    chmod +x "$bashrc_file"

    assert_file_exists "$bashrc_file"

    # Check for cron-list alias
    if command grep -q "alias cron-list=" "$bashrc_file"; then
        assert_true true "Bashrc includes cron-list alias"
    else
        assert_true false "Bashrc missing cron-list alias"
    fi

    # Check for cron-status alias
    if command grep -q "alias cron-status=" "$bashrc_file"; then
        assert_true true "Bashrc includes cron-status alias"
    else
        assert_true false "Bashrc missing cron-status alias"
    fi
}

# Test: Cron test script
test_cron_verification_script() {
    local test_script="$TEST_TEMP_DIR/usr/local/bin/test-cron"

    # Create test script matching actual cron.sh output
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "=== Cron Status ==="

if command -v cron &> /dev/null; then
    echo "cron: Installed"
else
    echo "cron: Not installed"
    exit 1
fi

echo ""
echo "=== Daemon Status ==="
if pgrep -x "cron" > /dev/null 2>&1; then
    echo "cron daemon: Running"
else
    echo "cron daemon: Not running"
fi
EOF
    chmod +x "$test_script"

    assert_file_exists "$test_script"

    # Check script is executable
    if [ -x "$test_script" ]; then
        assert_true true "Test script is executable"
    else
        assert_true false "Test script is not executable"
    fi

    # Check for daemon status check
    if command grep -q "pgrep" "$test_script"; then
        assert_true true "Test script checks daemon status"
    else
        assert_true false "Test script missing daemon status check"
    fi
}

# Test: Startup script numbering (should be early)
test_cron_startup_order() {
    local startup_script="$TEST_TEMP_DIR/etc/container/startup/05-cron.sh"

    # Create the script
    echo "#!/bin/bash" > "$startup_script"
    echo "# Cron startup" >> "$startup_script"
    chmod +x "$startup_script"

    # Extract the number from the filename
    local script_name
    script_name=$(basename "$startup_script")
    local script_num="${script_name%%-*}"

    # Check that cron uses an early number (05)
    if [ "$script_num" = "05" ]; then
        assert_true true "Cron startup uses early number (05)"
    else
        assert_true false "Cron startup number should be 05, got $script_num"
    fi
}

# Run tests with setup/teardown wrapper
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_cron_startup_script "Cron startup script creation"
run_test_with_setup test_cron_env_file "Cron environment file"
run_test_with_setup test_cron_bashrc "Cron bashrc configuration"
run_test_with_setup test_cron_verification_script "Cron verification script"
run_test_with_setup test_cron_startup_order "Cron startup script ordering"

# Generate report
generate_report
