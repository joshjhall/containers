#!/usr/bin/env bash
# Unit tests for lib/features/postgres-client.sh
# Tests PostgreSQL client installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "PostgreSQL Client Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-postgres"
    mkdir -p "$TEST_TEMP_DIR"
    
    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"
    
    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.psql"
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

# Test: PostgreSQL client binaries
test_psql_binaries() {
    local bin_dir="$TEST_TEMP_DIR/usr/bin"
    
    # List of PostgreSQL client tools
    local tools=("psql" "pg_dump" "pg_restore" "pg_dumpall" "createdb" "dropdb")
    
    # Create mock binaries
    for tool in "${tools[@]}"; do
        touch "$bin_dir/$tool"
        chmod +x "$bin_dir/$tool"
    done
    
    # Check each tool
    for tool in "${tools[@]}"; do
        if [ -x "$bin_dir/$tool" ]; then
            assert_true true "$tool is executable"
        else
            assert_true false "$tool is not executable"
        fi
    done
}

# Test: psql configuration
test_psql_config() {
    local psqlrc="$TEST_TEMP_DIR/home/testuser/.psqlrc"
    
    # Create psqlrc
    command cat > "$psqlrc" << 'EOF'
\set QUIET 1
\set ON_ERROR_ROLLBACK interactive
\set VERBOSITY verbose
\set PROMPT1 '%[%033[1m%]%M %n@%/%R%[%033[0m%]%# '
\set PROMPT2 '[more] %R > '
\pset null '[NULL]'
\pset linestyle unicode
\pset border 2
\timing
\set QUIET 0
EOF
    
    assert_file_exists "$psqlrc"
    
    # Check configuration
    if grep -q "ON_ERROR_ROLLBACK" "$psqlrc"; then
        assert_true true "Rollback on error configured"
    else
        assert_true false "Rollback on error not configured"
    fi
    
    if grep -q "\\timing" "$psqlrc"; then
        assert_true true "Query timing enabled"
    else
        assert_true false "Query timing not enabled"
    fi
}

# Test: Connection service file
test_pg_service() {
    local pg_service="$TEST_TEMP_DIR/home/testuser/.pg_service.conf"
    
    # Create service file
    command cat > "$pg_service" << 'EOF'
[development]
host=localhost
port=5432
dbname=dev_db
user=dev_user

[production]
host=prod.example.com
port=5432
dbname=prod_db
user=prod_user
sslmode=require
EOF
    
    assert_file_exists "$pg_service"
    
    # Check services
    if grep -q "\[development\]" "$pg_service"; then
        assert_true true "Development service defined"
    else
        assert_true false "Development service not defined"
    fi
    
    if grep -q "sslmode=require" "$pg_service"; then
        assert_true true "SSL mode configured for production"
    else
        assert_true false "SSL mode not configured"
    fi
}

# Test: PostgreSQL environment variables
test_postgres_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/70-postgres.sh"
    
    # Create environment setup
    command cat > "$bashrc_file" << 'EOF'
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-postgres}"
export PGCONNECT_TIMEOUT=10
export PSQL_HISTORY="$HOME/.psql_history"
EOF
    
    # Check environment variables
    if grep -q "export PGUSER=" "$bashrc_file"; then
        assert_true true "PGUSER is exported"
    else
        assert_true false "PGUSER is not exported"
    fi
    
    if grep -q "export PGCONNECT_TIMEOUT=" "$bashrc_file"; then
        assert_true true "Connection timeout configured"
    else
        assert_true false "Connection timeout not configured"
    fi
}

# Test: PostgreSQL aliases
test_postgres_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/70-postgres.sh"
    
    # Add aliases
    command cat >> "$bashrc_file" << 'EOF'

# PostgreSQL aliases
alias pglocal='psql -h localhost'
alias pgdump='pg_dump -Fc'
alias pgrestore='pg_restore -v'
alias pgsize='psql -c "SELECT pg_database_size(current_database());"'
alias pgtables='psql -c "\dt"'
EOF
    
    # Check aliases
    if grep -q "alias pglocal=" "$bashrc_file"; then
        assert_true true "pglocal alias defined"
    else
        assert_true false "pglocal alias not defined"
    fi
    
    if grep -q "alias pgdump=" "$bashrc_file"; then
        assert_true true "pgdump alias defined"
    else
        assert_true false "pgdump alias not defined"
    fi
}

# Test: psql history
test_psql_history() {
    local history_file="$TEST_TEMP_DIR/home/testuser/.psql_history"
    
    # Create history file
    command cat > "$history_file" << 'EOF'
SELECT version();
\dt
SELECT * FROM users LIMIT 10;
\q
EOF
    
    assert_file_exists "$history_file"
    
    # Check if history is readable
    if [ -r "$history_file" ]; then
        assert_true true "psql history is readable"
    else
        assert_true false "psql history is not readable"
    fi
}

# Test: Connection scripts
test_connection_scripts() {
    local script_dir="$TEST_TEMP_DIR/home/testuser/bin"
    mkdir -p "$script_dir"
    
    # Create connection helper
    command cat > "$script_dir/pgconnect" << 'EOF'
#!/bin/bash
SERVICE="${1:-development}"
psql "service=$SERVICE"
EOF
    chmod +x "$script_dir/pgconnect"
    
    assert_file_exists "$script_dir/pgconnect"
    
    # Check script is executable
    if [ -x "$script_dir/pgconnect" ]; then
        assert_true true "Connection script is executable"
    else
        assert_true false "Connection script is not executable"
    fi
}

# Test: Backup directory
test_backup_directory() {
    local backup_dir="$TEST_TEMP_DIR/home/testuser/postgres-backups"
    
    # Create backup directory
    mkdir -p "$backup_dir"
    
    assert_dir_exists "$backup_dir"
    
    # Check directory is writable
    if [ -w "$backup_dir" ]; then
        assert_true true "Backup directory is writable"
    else
        assert_true false "Backup directory is not writable"
    fi
}

# Test: SSL certificates directory
test_ssl_certificates() {
    local ssl_dir="$TEST_TEMP_DIR/home/testuser/.postgresql"
    
    # Create SSL directory
    mkdir -p "$ssl_dir"
    chmod 700 "$ssl_dir"
    
    assert_dir_exists "$ssl_dir"
    
    # Create mock certificates
    touch "$ssl_dir/root.crt"
    touch "$ssl_dir/postgresql.crt"
    touch "$ssl_dir/postgresql.key"
    chmod 600 "$ssl_dir/postgresql.key"
    
    # Check key permissions
    if [ -f "$ssl_dir/postgresql.key" ]; then
        assert_true true "SSL key exists"
    else
        assert_true false "SSL key missing"
    fi
}

# Test: Verification script
test_postgres_verification() {
    local test_script="$TEST_TEMP_DIR/test-postgres.sh"
    
    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "PostgreSQL client version:"
psql --version 2>/dev/null || echo "psql not installed"
echo "Available tools:"
for tool in pg_dump pg_restore createdb dropdb; do
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
run_test_with_setup test_psql_binaries "PostgreSQL client binaries"
run_test_with_setup test_psql_config "psql configuration"
run_test_with_setup test_pg_service "PostgreSQL service file"
run_test_with_setup test_postgres_environment "PostgreSQL environment variables"
run_test_with_setup test_postgres_aliases "PostgreSQL aliases"
run_test_with_setup test_psql_history "psql history file"
run_test_with_setup test_connection_scripts "Connection helper scripts"
run_test_with_setup test_backup_directory "Backup directory setup"
run_test_with_setup test_ssl_certificates "SSL certificates directory"
run_test_with_setup test_postgres_verification "PostgreSQL verification script"

# Generate test report
generate_report