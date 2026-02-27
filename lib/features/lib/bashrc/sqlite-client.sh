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


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
