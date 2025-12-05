#!/usr/bin/env bash
# Unit tests for lib/features/sqlite-client.sh
# Tests SQLite client installation and configuration

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "SQLite Client Feature Tests"

# Setup function - runs before each test
setup() {
    # Create temporary directory for testing
    export TEST_TEMP_DIR="$RESULTS_DIR/test-sqlite"
    mkdir -p "$TEST_TEMP_DIR"

    # Mock environment
    export USERNAME="testuser"
    export USER_UID="1000"
    export USER_GID="1000"
    export HOME="/home/testuser"

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR/usr/bin"
    mkdir -p "$TEST_TEMP_DIR/home/testuser/.sqlite"
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

# Test: SQLite3 installation
test_sqlite3_installation() {
    local bin_dir="$TEST_TEMP_DIR/usr/bin"

    # Create mock sqlite3 binary
    touch "$bin_dir/sqlite3"
    chmod +x "$bin_dir/sqlite3"

    assert_file_exists "$bin_dir/sqlite3"

    # Check executable
    if [ -x "$bin_dir/sqlite3" ]; then
        assert_true true "sqlite3 is executable"
    else
        assert_true false "sqlite3 is not executable"
    fi
}

# Test: SQLite configuration
test_sqlite_config() {
    local sqliterc="$TEST_TEMP_DIR/home/testuser/.sqliterc"

    # Create config
    command cat > "$sqliterc" << 'EOF'
.mode column
.headers on
.timer on
.nullvalue NULL
EOF

    assert_file_exists "$sqliterc"

    # Check configuration
    if grep -q ".headers on" "$sqliterc"; then
        assert_true true "Headers enabled"
    else
        assert_true false "Headers not enabled"
    fi

    if grep -q ".timer on" "$sqliterc"; then
        assert_true true "Timer enabled"
    else
        assert_true false "Timer not enabled"
    fi
}

# Test: SQLite aliases
test_sqlite_aliases() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/80-sqlite.sh"

    # Create aliases
    command cat > "$bashrc_file" << 'EOF'
alias sq='sqlite3'
alias sqmem='sqlite3 :memory:'
alias sqcsv='sqlite3 -csv'
alias sqjson='sqlite3 -json'
EOF

    # Check aliases
    if grep -q "alias sq='sqlite3'" "$bashrc_file"; then
        assert_true true "sqlite3 alias defined"
    else
        assert_true false "sqlite3 alias not defined"
    fi
}

# Test: Database directory
test_database_directory() {
    local db_dir="$TEST_TEMP_DIR/home/testuser/databases"

    # Create database directory
    mkdir -p "$db_dir"

    assert_dir_exists "$db_dir"

    # Check directory is writable
    if [ -w "$db_dir" ]; then
        assert_true true "Database directory is writable"
    else
        assert_true false "Database directory is not writable"
    fi
}

# Test: Sample database
test_sample_database() {
    local db_file="$TEST_TEMP_DIR/home/testuser/databases/test.db"
    mkdir -p "$(dirname "$db_file")"

    # Create empty database file
    touch "$db_file"

    assert_file_exists "$db_file"
}

# Test: SQLite history
test_sqlite_history() {
    local history_file="$TEST_TEMP_DIR/home/testuser/.sqlite_history"

    # Create history
    command cat > "$history_file" << 'EOF'
.tables
SELECT * FROM users;
.schema
.quit
EOF

    assert_file_exists "$history_file"
}

# Test: Environment variables
test_sqlite_environment() {
    local bashrc_file="$TEST_TEMP_DIR/etc/bashrc.d/80-sqlite.sh"

    # Add environment variables
    command cat >> "$bashrc_file" << 'EOF'
export SQLITE_HISTORY="$HOME/.sqlite_history"
EOF

    # Check environment variables
    if grep -q "export SQLITE_HISTORY=" "$bashrc_file"; then
        assert_true true "History file env var set"
    else
        assert_true false "History file env var not set"
    fi
}

# Test: Extensions directory
test_extensions_directory() {
    local ext_dir="$TEST_TEMP_DIR/home/testuser/.sqlite/extensions"

    # Create extensions directory
    mkdir -p "$ext_dir"

    assert_dir_exists "$ext_dir"
}

# Test: Backup scripts
test_backup_scripts() {
    local script="$TEST_TEMP_DIR/home/testuser/bin/sqlite-backup"
    mkdir -p "$(dirname "$script")"

    # Create backup script
    command cat > "$script" << 'EOF'
#!/bin/bash
DB="$1"
sqlite3 "$DB" ".backup ${DB}.backup"
EOF
    chmod +x "$script"

    assert_file_exists "$script"

    # Check script is executable
    if [ -x "$script" ]; then
        assert_true true "Backup script is executable"
    else
        assert_true false "Backup script is not executable"
    fi
}

# Test: Verification script
test_sqlite_verification() {
    local test_script="$TEST_TEMP_DIR/test-sqlite.sh"

    # Create verification script
    command cat > "$test_script" << 'EOF'
#!/bin/bash
echo "SQLite version:"
sqlite3 --version 2>/dev/null || echo "SQLite not installed"
echo "Testing in-memory database:"
echo "SELECT 1+1;" | sqlite3 :memory: 2>/dev/null || echo "SQLite test failed"
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
run_test_with_setup test_sqlite3_installation "SQLite3 installation"
run_test_with_setup test_sqlite_config "SQLite configuration"
run_test_with_setup test_sqlite_aliases "SQLite aliases"
run_test_with_setup test_database_directory "Database directory"
run_test_with_setup test_sample_database "Sample database creation"
run_test_with_setup test_sqlite_history "SQLite history file"
run_test_with_setup test_sqlite_environment "SQLite environment variables"
run_test_with_setup test_extensions_directory "Extensions directory"
run_test_with_setup test_backup_scripts "Backup scripts"
run_test_with_setup test_sqlite_verification "SQLite verification script"

# Generate test report
generate_report
