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


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
