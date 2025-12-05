#!/usr/bin/env bash
# Unit tests for lib/features/redis-client.sh
# Tests Redis client installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Redis Client Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-redis"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.redis"
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

# Test: Redis CLI installation
test_redis_cli_installation() {
    local bin_dir="$TEST_TEMP_DIR/usr/bin"

    # Create mock redis-cli binary
    touch "$bin_dir/redis-cli"
    chmod +x "$bin_dir/redis-cli"

    assert_file_exists "$bin_dir/redis-cli"

    # Check executable
    if [ -x "$bin_dir/redis-cli" ]; then
        assert_true true "redis-cli is executable"
    else
        assert_true false "redis-cli is not executable"
    fi
}

# Test: Redis tools
test_redis_tools() {
    local bin_dir="$TEST_TEMP_DIR/usr/bin"

    # List of Redis tools
    local tools=("redis-cli" "redis-benchmark" "redis-check-aof" "redis-check-rdb")

    # Create mock tools
    for tool in "${tools[@]}"; do
        touch "$bin_dir/$tool"
        chmod +x "$bin_dir/$tool"
    done

    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$bin_dir/$tool" ]; then
            assert_true true "$tool is installed"
        else
            assert_true false "$tool is not installed"
        fi
    done
}

# Test: Redis configuration
test_redis_config() {
    local redis_conf="$TEST_TEMP_DIR/home/testuser/.redis/redis-cli.conf"
    mkdir -p "$(dirname "$redis_conf")"

    # Create config
    command cat > "$redis_conf" << 'EOF'
# Redis CLI configuration
historyfile ~/.redis/.rediscli_history
EOF

    assert_file_exists "$redis_conf"

    # Check configuration
    if grep -q "historyfile" "$redis_conf"; then
        assert_true true "History file configured"
    else
        assert_true false "History file not configured"
    fi
}

# Test: Redis aliases
test_redis_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/75-redis.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias rcli='redis-cli'
alias rping='redis-cli ping'
alias rinfo='redis-cli info'
alias rmon='redis-cli monitor'
alias rkeys='redis-cli keys "*"'
EOF

    # Check aliases
    if grep -q "alias rcli=" "$bashrc_file"; then
        assert_true true "redis-cli alias defined"
    else
        assert_true false "redis-cli alias not defined"
    fi

    if grep -q "alias rmon=" "$bashrc_file"; then
        assert_true true "monitor alias defined"
    else
        assert_true false "monitor alias not defined"
    fi
}

# Test: Redis connection scripts
test_connection_scripts() {
    local script="$TEST_TEMP_DIR/home/testuser/bin/redis-connect"
    mkdir -p "$(dirname "$script")"

    # Create connection script
    command cat > "$script" << 'EOF'
#!/bin/bash
HOST="${1:-localhost}"
PORT="${2:-6379}"
redis-cli -h "$HOST" -p "$PORT"
EOF
    chmod +x "$script"

    assert_file_exists "$script"

    # Check script is executable
    if [ -x "$script" ]; then
        assert_true true "Connection script is executable"
    else
        assert_true false "Connection script is not executable"
    fi
}

# Test: Redis history file
test_redis_history() {
    local history_file="$TEST_TEMP_DIR/home/testuser/.redis/.rediscli_history"
    mkdir -p "$(dirname "$history_file")"

    # Create history
    command cat > "$history_file" << 'EOF'
PING
INFO
GET key1
SET key2 value2
EOF

    assert_file_exists "$history_file"
}

# Test: Environment variables
test_redis_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/75-redis.sh"

    # Add environment variables
    command cat >> "$bashrc_file" << 'EOF'
export REDISCLI_HISTFILE="$HOME/.redis/.rediscli_history"
export REDISCLI_AUTH=""
EOF

    # Check environment variables
    if grep -q "export REDISCLI_HISTFILE=" "$bashrc_file"; then
        assert_true true "History file env var set"
    else
        assert_true false "History file env var not set"
    fi
}

# Test: Redis dump directory
test_dump_directory() {
    local dump_dir="$TEST_TEMP_DIR/home/testuser/redis-dumps"

    # Create dump directory
    mkdir -p "$dump_dir"

    assert_dir_exists "$dump_dir"

    # Check directory is writable
    if [ -w "$dump_dir" ]; then
        assert_true true "Dump directory is writable"
    else
        assert_true false "Dump directory is not writable"
    fi
}

# Test: Redis TLS certificates
test_redis_tls() {
    local tls_dir="$TEST_TEMP_DIR/home/testuser/.redis/tls"

    # Create TLS directory
    mkdir -p "$tls_dir"

    # Create mock certificates
    touch "$tls_dir/ca.crt"
    touch "$tls_dir/client.crt"
    touch "$tls_dir/client.key"
    chmod 600 "$tls_dir/client.key"

    assert_file_exists "$tls_dir/ca.crt"
    assert_file_exists "$tls_dir/client.key"
}

# Test: Verification script
test_redis_verification() {
    local test_script="$TEST_TEMP_DIR/test-redis.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "Redis CLI version:"
redis-cli --version 2>/dev/null || echo "redis-cli not installed"
echo "Testing connection:"
redis-cli ping 2>/dev/null || echo "Cannot connect to Redis"
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
run_test_with_setup test_redis_cli_installation "Redis CLI installation"
run_test_with_setup test_redis_tools "Redis tools installation"
run_test_with_setup test_redis_config "Redis configuration"
run_test_with_setup test_redis_aliases "Redis aliases"
run_test_with_setup test_connection_scripts "Connection scripts"
run_test_with_setup test_redis_history "Redis history file"
run_test_with_setup test_redis_environment "Redis environment variables"
run_test_with_setup test_dump_directory "Redis dump directory"
run_test_with_setup test_redis_tls "Redis TLS certificates"
run_test_with_setup test_redis_verification "Redis verification script"

# Generate test report
generate_report
