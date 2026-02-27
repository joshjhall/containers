#!/bin/bash
# SQLite Client Tools - Lightweight embedded database command-line interface
#
# Description:
#   Installs SQLite3 command-line tools for working with SQLite databases.
#   SQLite is a self-contained, serverless, zero-configuration database engine.
#
# Features:
#   - sqlite3: Interactive SQLite shell and command-line interface
#   - In-memory database support
#   - File-based database management
#   - SQL script execution
#   - CSV import/export capabilities
#   - JSON support (SQLite 3.38.0+)
#
# Tools Installed:
#   - sqlite3: Latest stable version from Ubuntu repos
#
# Common Usage:
#   - sqlite3 database.db           # Open/create database
#   - sqlite3 :memory:             # In-memory database
#   - sqlite3 -init script.sql db  # Run initialization script
#   - sqlite3 -csv db "SELECT..."  # Export query as CSV
#
# Shell Commands:
#   - .tables                      # List all tables
#   - .schema [table]             # Show table structure
#   - .mode csv                   # Set output mode
#   - .import file.csv table      # Import CSV data
#   - .backup filename            # Backup database
#
# Note:
#   SQLite databases are single files, making them ideal for embedded applications,
#   development, and testing. Use .mode and .headers for formatted output.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "SQLite Client"

# ============================================================================
# Package Installation
# ============================================================================
log_message "Installing SQLite client package..."

# Update package lists with retry logic
apt_update

# Install SQLite3 command-line tool with retry logic
apt_install sqlite3

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring SQLite environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide SQLite configuration (content in lib/bashrc/sqlite-client.sh)
write_bashrc_content /etc/bashrc.d/60-sqlite.sh "SQLite client configuration" \
    < /tmp/build-scripts/features/lib/bashrc/sqlite-client.sh

log_command "Setting SQLite bashrc script permissions" \
    chmod +x /etc/bashrc.d/60-sqlite.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating SQLite startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/20-sqlite-setup.sh << 'EOF'
#!/bin/bash
# SQLite client configuration
echo "=== SQLite Configuration ==="
echo "SQLite $(sqlite3 --version | cut -d' ' -f1) is installed"

# Check for SQLite databases in workspace
if compgen -G "${WORKING_DIR}/*.db" > /dev/null || compgen -G "${WORKING_DIR}/*.sqlite" > /dev/null || compgen -G "${WORKING_DIR}/*.sqlite3" > /dev/null; then
    echo "\nSQLite databases found in workspace:"
    ls -la ${WORKING_DIR}/*.db ${WORKING_DIR}/*.sqlite ${WORKING_DIR}/*.sqlite3 2>/dev/null | grep -v "cannot access"
fi

# Create example database if none exists
if [ ! -f ~/example.db ] && [ ! -f ${WORKING_DIR}/*.db ]; then
    echo "\nCreating example database at ~/example.db"
    sqlite3 ~/example.db << 'SQL'
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);
INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com');
INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com');
.tables
SQL
    echo "Try: sqlite3 ~/example.db 'SELECT * FROM users;'"
fi
EOF

log_command "Setting SQLite startup script permissions" \
    chmod +x /etc/container/first-startup/20-sqlite-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating SQLite verification script..."

command cat > /usr/local/bin/test-sqlite << 'EOF'
#!/bin/bash
echo "=== SQLite Client Status ==="
if command -v sqlite3 &> /dev/null; then
    echo "✓ SQLite client is installed"
    echo "  Version: $(sqlite3 --version | cut -d' ' -f1)"
    echo "  Binary: $(which sqlite3)"
else
    echo "✗ SQLite client is not installed"
    exit 1
fi

echo ""
echo "=== SQLite Features ==="
echo -n "  JSON support: "
if sqlite3 :memory: "SELECT json('{\"test\": 1}');" &>/dev/null 2>&1; then
    echo "✓ Available"
else
    echo "✗ Not available"
fi

echo -n "  FTS5 support: "
if sqlite3 :memory: "CREATE VIRTUAL TABLE test USING fts5(content);" &>/dev/null 2>&1; then
    echo "✓ Available"
else
    echo "✗ Not available"
fi

echo ""
echo "=== Environment ==="
echo "  SQLITE_HISTORY: ${SQLITE_HISTORY:-$HOME/.sqlite_history}"

if [ -f ~/.sqliterc ]; then
    echo "  ✓ .sqliterc file exists"
else
    echo "  ✗ .sqliterc file not found"
fi

# Check for databases in common locations
echo ""
echo "=== Database Files ==="
if compgen -G "$HOME/*.db" > /dev/null || compgen -G "$HOME/*.sqlite" > /dev/null || compgen -G "$HOME/*.sqlite3" > /dev/null; then
    echo "Found in home directory:"
    ls -la $HOME/*.db $HOME/*.sqlite $HOME/*.sqlite3 2>/dev/null | grep -v "cannot access" || true
fi

if [ -d ${WORKING_DIR} ] && (compgen -G "${WORKING_DIR}/*.db" > /dev/null || compgen -G "${WORKING_DIR}/*.sqlite" > /dev/null || compgen -G "${WORKING_DIR}/*.sqlite3" > /dev/null); then
    echo "Found in workspace:"
    ls -la ${WORKING_DIR}/*.db ${WORKING_DIR}/*.sqlite ${WORKING_DIR}/*.sqlite3 2>/dev/null | grep -v "cannot access" || true
fi
EOF

log_command "Setting test-sqlite script permissions" \
    chmod +x /usr/local/bin/test-sqlite

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying SQLite installation..."

log_command "Checking sqlite3 version" \
    sqlite3 --version || log_warning "SQLite not installed properly"

# Log feature summary
log_feature_summary \
    --feature "SQLite Client" \
    --tools "sqlite3" \
    --paths "$HOME/.sqlite_history" \
    --env "SQLITE_HISTORY" \
    --commands "sqlite3,sqlite-quick,sqlite-backup,sqlite-restore,sqlite-analyze,sqlite-dump-schema" \
    --next-steps "Run 'test-sqlite' to verify installation. Use 'sqlite3 <db-file>' to open databases. Create backups with 'sqlite-backup <db> [output]'. Analyze tables with 'sqlite-analyze <db>'."

# End logging
log_feature_end

echo ""
echo "Run 'test-sqlite' to verify installation"
echo "Run 'check-build-logs.sh sqlite-client' to review installation logs"
