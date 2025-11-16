#!/bin/bash
# PostgreSQL Client Tools - Command-line interface for PostgreSQL databases
#
# Description:
#   Installs PostgreSQL client tools for connecting to and managing PostgreSQL
#   databases. Includes psql interactive terminal and backup/restore utilities.
#
# Features:
#   - psql: Interactive PostgreSQL terminal
#   - pg_dump: Database backup utility
#   - pg_restore: Database restore utility
#   - pg_dumpall: Cluster-wide backup utility
#   - createdb/dropdb: Database creation/deletion utilities
#   - createuser/dropuser: User management utilities
#
# Tools Installed:
#   - postgresql-client: Latest stable version from Ubuntu repos
#
# Common Usage:
#   - psql -h hostname -U username -d database
#   - pg_dump -h hostname -U username database > backup.sql
#   - pg_restore -h hostname -U username -d database backup.dump
#
# Environment Variables:
#   - PGHOST: Default PostgreSQL host
#   - PGPORT: Default PostgreSQL port (5432)
#   - PGUSER: Default PostgreSQL username
#   - PGDATABASE: Default database name
#   - PGPASSWORD: Password (use .pgpass file instead for security)
#
# Note:
#   For production use, configure .pgpass file for secure password storage.
#   Connection parameters can be stored in ~/.pg_service.conf for convenience.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "PostgreSQL Client"

# ============================================================================
# Package Installation
# ============================================================================
log_message "Installing PostgreSQL client package..."

# Update package lists with retry logic
apt_update

# Install PostgreSQL client tools with retry logic
apt_install postgresql-client

# ============================================================================
# Environment Configuration
# ============================================================================
log_message "Configuring PostgreSQL environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide PostgreSQL configuration
write_bashrc_content /etc/bashrc.d/60-postgresql.sh "PostgreSQL client configuration" << 'POSTGRES_BASHRC_EOF'
# ----------------------------------------------------------------------------
# PostgreSQL Client Configuration and Helpers
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
# PostgreSQL Aliases - Common database operations
# ----------------------------------------------------------------------------
alias psql-local='psql -h localhost -U postgres'
alias pg-list='psql -c "\l"'  # List all databases
alias pg-tables='psql -c "\dt"'  # List tables in current database
alias pg-users='psql -c "\du"'  # List all users/roles

# ----------------------------------------------------------------------------
# pg-quick-connect - Connect to PostgreSQL with common defaults
#
# Arguments:
#   $1 - Database name (default: postgres)
#   $2 - Username (default: postgres)
#   $3 - Host (default: localhost)
#
# Example:
#   pg-quick-connect mydb myuser remote-host
# ----------------------------------------------------------------------------
pg-quick-connect() {
    local database="${1:-postgres}"
    local username="${2:-postgres}"
    local host="${3:-localhost}"

    echo "Connecting to $host as $username to database $database..."
    psql -h "$host" -U "$username" -d "$database"
}

# ----------------------------------------------------------------------------
# pg-backup - Create a PostgreSQL database backup
#
# Arguments:
#   $1 - Database name (required)
#   $2 - Output file (default: database_timestamp.sql)
#
# Example:
#   pg-backup mydb
#   pg-backup mydb custom-backup.sql
# ----------------------------------------------------------------------------
pg-backup() {
    if [ -z "$1" ]; then
        echo "Usage: pg-backup <database> [output-file]"
        return 1
    fi

    local database="$1"
    local output="${2:-${database}_$(date +%Y%m%d_%H%M%S).sql}"

    echo "Backing up database '$database' to '$output'..."
    pg_dump "$database" > "$output" && echo "Backup complete: $output"
}

# ----------------------------------------------------------------------------
# pg-restore-sql - Restore a PostgreSQL database from SQL file
#
# Arguments:
#   $1 - SQL file (required)
#   $2 - Database name (required)
#
# Example:
#   pg-restore-sql backup.sql mydb
# ----------------------------------------------------------------------------
pg-restore-sql() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: pg-restore-sql <sql-file> <database>"
        return 1
    fi

    local sqlfile="$1"
    local database="$2"

    if [ ! -f "$sqlfile" ]; then
        echo "Error: SQL file '$sqlfile' not found"
        return 1
    fi

    echo "Restoring '$sqlfile' to database '$database'..."
    psql -d "$database" < "$sqlfile" && echo "Restore complete"
}

# PostgreSQL prompt customization
export PSQL_EDITOR='${EDITOR:-vim}'

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
POSTGRES_BASHRC_EOF

log_command "Setting PostgreSQL bashrc script permissions" \
    chmod +x /etc/bashrc.d/60-postgresql.sh

# ============================================================================
# Connection Configuration
# ============================================================================
log_message "Creating connection configuration templates..."

# Create template .pgpass file
log_command "Creating .pgpass template" \
    bash -c "command cat > /etc/skel/.pgpass.template << 'EOF'
# PostgreSQL password file template
# Format: hostname:port:database:username:password
#
# Examples:
# localhost:5432:*:postgres:mypassword
# db.example.com:5432:myapp:appuser:secretpass
# *:*:*:myuser:mypass
#
# Set permissions: chmod 600 ~/.pgpass
EOF"

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating PostgreSQL startup script..."

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/20-postgres-setup.sh << 'EOF'
#!/bin/bash
# PostgreSQL client configuration
if [ ! -f ~/.pgpass ] && [ -f ~/.pgpass.template ]; then
    echo "=== PostgreSQL Client Configuration ==="
    echo "Template .pgpass file created at ~/.pgpass.template"
    echo "Copy and edit it to ~/.pgpass for automatic authentication"
    echo "Remember to: chmod 600 ~/.pgpass"
fi

# Check for common PostgreSQL environment variables
if [ -n "${PGHOST}${PGUSER}${PGDATABASE}" ]; then
    echo "PostgreSQL environment detected:"
    [ -n "$PGHOST" ] && echo "  Host: $PGHOST"
    [ -n "$PGUSER" ] && echo "  User: $PGUSER"
    [ -n "$PGDATABASE" ] && echo "  Database: $PGDATABASE"
fi
EOF

log_command "Setting PostgreSQL startup script permissions" \
    chmod +x /etc/container/first-startup/20-postgres-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating PostgreSQL verification script..."

command cat > /usr/local/bin/test-postgres << 'EOF'
#!/bin/bash
echo "=== PostgreSQL Client Status ==="
if command -v psql &> /dev/null; then
    echo "✓ PostgreSQL client is installed"
    echo "  Version: $(psql --version)"
    echo "  Binary: $(which psql)"
else
    echo "✗ PostgreSQL client is not installed"
    exit 1
fi

echo ""
echo "=== Available Tools ==="
for cmd in psql pg_dump pg_restore pg_dumpall createdb dropdb createuser dropuser; do
    if command -v $cmd &> /dev/null; then
        echo "✓ $cmd is available"
    else
        echo "✗ $cmd is not found"
    fi
done

echo ""
echo "=== Environment Variables ==="
echo "  PGHOST: ${PGHOST:-[not set]}"
echo "  PGPORT: ${PGPORT:-[not set]}"
echo "  PGUSER: ${PGUSER:-[not set]}"
echo "  PGDATABASE: ${PGDATABASE:-[not set]}"

if [ -f ~/.pgpass ]; then
    echo "  ✓ .pgpass file exists"
else
    echo "  ✗ .pgpass file not found"
fi
EOF

log_command "Setting test-postgres script permissions" \
    chmod +x /usr/local/bin/test-postgres

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying PostgreSQL client installation..."

log_command "Checking psql version" \
    psql --version || log_warning "PostgreSQL client not installed properly"

# Log feature summary
log_feature_summary \
    --feature "PostgreSQL Client" \
    --tools "psql,pg_dump,pg_restore,pg_dumpall,createdb,dropdb,createuser,dropuser" \
    --paths "$HOME/.pgpass,~/.pg_service.conf" \
    --env "PGHOST,PGPORT,PGUSER,PGDATABASE,PGPASSWORD" \
    --commands "psql,pg_dump,pg_restore,pg-quick-connect,pg-backup,pg-restore-sql,pg-db-size,pg-kill-connections" \
    --next-steps "Run 'test-postgres' to verify installation. Connect with 'psql -h <host> -U <user> -d <db>' or use pg-quick-connect helper. Configure .pgpass for password-less auth."

# End logging
log_feature_end

echo ""
echo "Run 'test-postgres' to verify installation"
echo "Run 'check-build-logs.sh postgresql-client' to review installation logs"
