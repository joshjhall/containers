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

# Create system-wide SQLite configuration
write_bashrc_content /etc/bashrc.d/60-sqlite.sh "SQLite client configuration" << 'SQLITE_BASHRC_EOF'
# ----------------------------------------------------------------------------
# SQLite Client Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# ----------------------------------------------------------------------------
# SQLite Aliases - Common database operations
# ----------------------------------------------------------------------------
alias sqlite='sqlite3'
alias sqlite-version='sqlite3 --version'
alias sqlite-memory='sqlite3 :memory:'  # Start with in-memory database
alias sqlite-csv='sqlite3 -csv'         # CSV output mode
alias sqlite-json='sqlite3 -json'       # JSON output mode
alias sqlite-pretty='sqlite3 -column -header'  # Pretty table output

# ----------------------------------------------------------------------------
# sqlite-create - Create a new SQLite database with basic structure
#
# Arguments:
#   $1 - Database filename (required)
#
# Example:
#   sqlite-create myapp.db
# ----------------------------------------------------------------------------
sqlite-create() {
    if [ -z "$1" ]; then
        echo "Usage: sqlite-create <database-file>"
        return 1
    fi

    local dbfile="$1"

    if [ -f "$dbfile" ]; then
        echo "Error: Database '$dbfile' already exists"
        return 1
    fi

    echo "Creating SQLite database: $dbfile"
    sqlite3 "$dbfile" << 'SQL'
-- Enable foreign keys
PRAGMA foreign_keys = ON;

-- Create metadata table
CREATE TABLE IF NOT EXISTS _metadata (
    key TEXT PRIMARY KEY,
    value TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Insert version info
INSERT INTO _metadata (key, value) VALUES ('version', '1.0');
INSERT INTO _metadata (key, value) VALUES ('created', datetime('now'));

-- Show confirmation
SELECT 'Database created successfully' as message;
.tables
SQL
}

# ----------------------------------------------------------------------------
# sqlite-backup - Create a backup of SQLite database
#
# Arguments:
#   $1 - Source database (required)
#   $2 - Backup filename (default: source_timestamp.db)
#
# Example:
#   sqlite-backup myapp.db
#   sqlite-backup myapp.db backup.db
# ----------------------------------------------------------------------------
sqlite-backup() {
    if [ -z "$1" ]; then
        echo "Usage: sqlite-backup <source-db> [backup-file]"
        return 1
    fi

    local source="$1"
    local backup="${2:-${source%.db}_$(date +%Y%m%d_%H%M%S).db}"

    if [ ! -f "$source" ]; then
        echo "Error: Source database '$source' not found"
        return 1
    fi

    echo "Backing up '$source' to '$backup'..."
    sqlite3 "$source" ".backup '$backup'" && echo "Backup complete: $backup"
}

# ----------------------------------------------------------------------------
# sqlite-export-csv - Export table or query results to CSV
#
# Arguments:
#   $1 - Database file (required)
#   $2 - Table name or SQL query (required)
#   $3 - Output CSV file (default: output.csv)
#
# Example:
#   sqlite-export-csv myapp.db users
#   sqlite-export-csv myapp.db "SELECT * FROM users WHERE active=1" active_users.csv
# ----------------------------------------------------------------------------
sqlite-export-csv() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: sqlite-export-csv <database> <table|query> [output.csv]"
        return 1
    fi

    local database="$1"
    local query="$2"
    local output="${3:-output.csv}"

    # Check if it's a table name or SQL query
    if [[ ! "$query" =~ ^[Ss][Ee][Ll][Ee][Cc][Tt] ]]; then
        query="SELECT * FROM $query"
    fi

    echo "Exporting to $output..."
    sqlite3 -csv -header "$database" "$query" > "$output" && echo "Export complete: $output"
}

# ----------------------------------------------------------------------------
# sqlite-import-csv - Import CSV file into SQLite table
#
# Arguments:
#   $1 - Database file (required)
#   $2 - CSV file (required)
#   $3 - Table name (required)
#
# Example:
#   sqlite-import-csv myapp.db users.csv users
# ----------------------------------------------------------------------------
sqlite-import-csv() {
    if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
        echo "Usage: sqlite-import-csv <database> <csv-file> <table>"
        return 1
    fi

    local database="$1"
    local csvfile="$2"
    local table="$3"

    if [ ! -f "$csvfile" ]; then
        echo "Error: CSV file '$csvfile' not found"
        return 1
    fi

    echo "Importing '$csvfile' into table '$table'..."
    sqlite3 "$database" << EOF
.mode csv
.import "$csvfile" "$table"
SELECT COUNT(*) || ' rows imported' FROM "$table";
EOF
}

# ----------------------------------------------------------------------------
# sqlite-analyze - Analyze database and show statistics
#
# Arguments:
#   $1 - Database file (required)
#
# Example:
#   sqlite-analyze myapp.db
# ----------------------------------------------------------------------------
sqlite-analyze() {
    if [ -z "$1" ]; then
        echo "Usage: sqlite-analyze <database>"
        return 1
    fi

    local database="$1"

    if [ ! -f "$database" ]; then
        echo "Error: Database '$database' not found"
        return 1
    fi

    echo "Analyzing database: $database"
    echo "=============================="

    sqlite3 -column -header "$database" << 'EOF'
-- File size
SELECT 'File size' as metric,
       printf('%.2f MB', page_count * page_size / 1024.0 / 1024.0) as value
FROM pragma_page_count(), pragma_page_size();

-- Table count
SELECT 'Tables' as metric, COUNT(*) as value
FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';

-- Index count
SELECT 'Indexes' as metric, COUNT(*) as value
FROM sqlite_master WHERE type='index';

-- Table sizes
SELECT '\nTable sizes:' as info;
SELECT name as table_name,
       printf('%.2f MB', pgsize/1024.0/1024.0) as size
FROM (SELECT name, SUM(pgsize) as pgsize FROM dbstat GROUP BY name)
WHERE name IN (SELECT name FROM sqlite_master WHERE type='table')
ORDER BY pgsize DESC
LIMIT 10;
EOF
}

# SQLite configuration
export SQLITE_HISTORY="$HOME/.sqlite_history"

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
SQLITE_BASHRC_EOF

log_command "Setting SQLite bashrc script permissions" \
    chmod +x /etc/bashrc.d/60-sqlite.sh

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating SQLite startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/20-sqlite-setup.sh << 'EOF'
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

cat > /usr/local/bin/test-sqlite << 'EOF'
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
    --paths "~/.sqlite_history" \
    --env "SQLITE_HISTORY" \
    --commands "sqlite3,sqlite-quick,sqlite-backup,sqlite-restore,sqlite-analyze,sqlite-dump-schema" \
    --next-steps "Run 'test-sqlite' to verify installation. Use 'sqlite3 <db-file>' to open databases. Create backups with 'sqlite-backup <db> [output]'. Analyze tables with 'sqlite-analyze <db>'."

# End logging
log_feature_end

echo ""
echo "Run 'test-sqlite' to verify installation"
echo "Run 'check-build-logs.sh sqlite-client' to review installation logs"
