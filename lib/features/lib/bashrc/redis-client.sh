# ----------------------------------------------------------------------------
# Redis Client Configuration and Helpers
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
# Redis Aliases - Common Redis operations
# ----------------------------------------------------------------------------
alias redis='redis-cli'
alias redis-local='redis-cli -h localhost'
alias redis-ping='redis-cli ping'
alias redis-info='redis-cli info'
alias redis-monitor='redis-cli monitor'
alias redis-keys='redis-cli --scan'

# ----------------------------------------------------------------------------
# redis-quick-connect - Connect to Redis with common defaults
#
# Arguments:
#   $1 - Host (default: localhost)
#   $2 - Port (default: 6379)
#   $3 - Database number (default: 0)
#
# Example:
#   redis-quick-connect redis.example.com 6380 1
# ----------------------------------------------------------------------------
redis-quick-connect() {
    local host="${1:-localhost}"
    local port="${2:-6379}"
    local db="${3:-0}"

    echo "Connecting to Redis at $host:$port (database $db)..."
    redis-cli -h "$host" -p "$port" -n "$db"
}

# ----------------------------------------------------------------------------
# redis-scan-keys - Scan for keys matching a pattern
#
# Arguments:
#   $1 - Pattern (required)
#   $2 - Host (default: localhost)
#
# Example:
#   redis-scan-keys "user:*"
#   redis-scan-keys "session:*" redis.example.com
# ----------------------------------------------------------------------------
redis-scan-keys() {
    if [ -z "$1" ]; then
        echo "Usage: redis-scan-keys <pattern> [host]"
        return 1
    fi

    local pattern="$1"
    local host="${2:-localhost}"

    echo "Scanning for keys matching '$pattern' on $host..."
    redis-cli -h "$host" --scan --pattern "$pattern"
}

# ----------------------------------------------------------------------------
# redis-backup - Create a backup of Redis data
#
# Arguments:
#   $1 - Output file (default: redis_backup_timestamp.rdb)
#   $2 - Host (default: localhost)
#
# Example:
#   redis-backup
#   redis-backup mybackup.rdb redis.example.com
# ----------------------------------------------------------------------------
redis-backup() {
    local output="${1:-redis_backup_$(date +%Y%m%d_%H%M%S).rdb}"
    local host="${2:-localhost}"

    echo "Creating Redis backup from $host to $output..."
    redis-cli -h "$host" --rdb "$output" && echo "Backup complete: $output"
}

# ----------------------------------------------------------------------------
# redis-load-test - Run a simple load test
#
# Arguments:
#   $1 - Number of requests (default: 10000)
#   $2 - Host (default: localhost)
#
# Example:
#   redis-load-test 50000
#   redis-load-test 100000 redis.example.com
# ----------------------------------------------------------------------------
redis-load-test() {
    local requests="${1:-10000}"
    local host="${2:-localhost}"

    echo "Running load test with $requests requests against $host..."
    redis-benchmark -h "$host" -n "$requests" -q
}

# Redis CLI customization
export REDISCLI_HISTFILE="${HOME}/.rediscli_history"


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
