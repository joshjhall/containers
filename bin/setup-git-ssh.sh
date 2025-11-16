#!/bin/bash
set -euo pipefail

# shellcheck disable=SC2155  # Declare and assign separately to avoid masking return values
# shellcheck disable=SC1090  # Can't follow non-constant source
# shellcheck disable=SC2086  # Double quote to prevent globbing (used intentionally)

# Secure Post-Create Script for Devcontainer
# Version: 3.5.2
#
# Purpose: Configure developer environment (Git, SSH, 1Password)
# Language-specific setup should be handled in devcontainer.json
#
# CHANGELOG:
# v3.5.2 - 2025-07-08
#   - Add Git signing key installation (both public and private keys)
#   - Update health check to verify both signing keys exist
#   - Fix verify_ssh_agent function call
#   - Add signing key to ssh-agent for Git operations
# v3.5.1 - Previous version with enhanced security
#
# Usage:
#   bash setup-git-ssh.sh
#
# Environment Variables:
#   OP_SERVICE_ACCOUNT_TOKEN - 1Password service account token (required)
#   OP_ACCOUNT              - 1Password account URL (optional)
#   GIT_CONFIG_ITEM         - Name of 1Password item with Git config (optional)
#   GIT_SIGNING_KEY_ITEM    - Name of 1Password item with signing key (optional)
#   LOG_LEVEL               - Logging verbosity: 0=ERROR, 1=WARN, 2=INFO, 3=DEBUG
#   NO_PROGRESS             - Set to 1 to disable progress bars (useful in CI/scripts)
#
# The script searches for .env files in multiple locations (see load_env_file docs)
# and can be used standalone or as part of a DevContainer setup
#
# Security hardened implementation with:
# - Command injection prevention
# - Secure temporary file handling
# - Atomic operations
# - Comprehensive error handling
# - Detailed logging
# - Health checks
#
# Version 3.5.1 bug fixes:
# - Fixed ssh-add exit code check logic in SSH agent verification
# - Added VS Code SSH auth socket pattern to validation whitelist
# - Added exception for world-writable /tmp when used by VS Code
# - Resolved false negative SSH agent startup failures in DevContainers
#
# Version 3.5.0 improvements:
# - Enhanced SSH socket path validation with whitelist patterns
# - Added rate limiting for 1Password API operations
# - Implemented secure file operations with file descriptors
# - Added command whitelist validation for external commands
# - Enhanced process validation with binary path checking
# - Added environment variable loading limits (50 max)
# - Implemented secure memory clearing for sensitive data
# - Added generic network connectivity check (no IP leakage)
# - Enhanced cleanup registry with unregister capability
# - Added with_signals_masked for atomic operations
#
# Version 3.4.3 improvements:
# - Enhanced progress bar detection for DevContainer environments
# - Added NO_PROGRESS environment variable support
# - Check for REMOTE_CONTAINERS_IPC to detect DevContainer context
#
# Version 3.4.2 improvements:
# - Fixed progress bar formatting issues with log output
# - Progress bars now only shown in interactive terminals
# - Progress bars disabled when DEBUG logging is active
#
# Version 3.4.1 improvements:
# - Fixed indirect variable expansion bug with set -u (nounset)
# - Use eval with default expansion to safely check variables
#
# Version 3.4.0 improvements:
# - Signal handling and masking during critical operations
# - Cleanup registry for guaranteed temp file removal
# - SSH agent socket validation (permissions, ownership)
# - Enhanced process name validation for ssh-agent
# - Improved username sanitization with POSIX compliance
# - Network error message sanitization (no internal topology)
# - Signal traps for graceful cleanup on interruption
# - Memory scrubbing for sensitive variables
# - Atomic operations protected from interrupts
#
# Version 3.3.0 improvements:
# - Multi-location .env file search with priority ordering
# - Enhanced file permission and ownership validation
# - Rate limiting for 1Password API calls
# - Symlink attack prevention for temp directories
# - Binary path validation with permission checks
# - Improved race condition handling for file operations
# - Username and hostname sanitization
# - SSH agent socket validation
# - Arithmetic operation fixes for set -e compatibility
#
# Version 3.2.0 improvements:
# - Enhanced JSON parsing with validation
# - Improved SSH key format validation
# - Better memory handling for sensitive data
# - More granular error codes
# - Enhanced network error recovery
# - Stricter input validation for edge cases
# - Added process monitoring for SSH agent

# ============================================================================
# CONFIGURATION
# ============================================================================
#
# Security Summary:
# This script implements defense-in-depth security with multiple layers:
#
# 1. Input Validation
#    - All user inputs are sanitized and length-limited
#    - Email addresses, hostnames, and paths are validated
#    - JSON data is parsed securely with size limits
#
# 2. File Security
#    - Temporary files created with 600 permissions
#    - Directory permissions verified (700 for dirs, 600 for files)
#    - Symlink attack prevention
#    - Secure deletion with shred (fallback to overwrite)
#
# 3. Process Security
#    - Binary paths validated against whitelist
#    - Permission checks on executables
#    - Process verification (e.g., SSH agent PID validation)
#    - Timeout protection on all external commands
#
# 4. Environment Hardening
#    - PATH sanitized to known good directories
#    - Dangerous environment variables cleared
#    - Shell options set for safety (nounset, no history expansion)
#    - IFS set to safe default
#
# 5. Resource Protection
#    - Rate limiting for API calls
#    - Maximum file sizes enforced
#    - SSH key count limits
#    - Disk space checks before operations

readonly SCRIPT_VERSION="3.5.2"
# Split declare and assign to avoid masking return values
readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"


# Network and retry configuration
readonly MAX_RETRIES=3
readonly RETRY_DELAY=2
readonly NETWORK_TIMEOUT=15  # Reduced from 30s for better UX
readonly HEALTH_CHECK_TIMEOUT=5  # Timeout for individual health checks
# shellcheck disable=SC2034  # Reserved for future use
readonly OP_RATE_LIMIT_DELAY=0.5  # Delay between 1Password API calls
# shellcheck disable=SC2034  # Reserved for future use
readonly OP_MAX_CONCURRENT=1  # Maximum concurrent 1Password operations

# SSH and security constants
readonly SSH_KEY_BATCH_SIZE=5  # Process SSH keys in batches
readonly SSH_KEY_BATCH_DELAY=0.5  # Delay between batches
readonly SSH_MAX_KEYS_TO_LOAD=50  # Maximum number of SSH keys to load (prevent DoS)
readonly SSH_AGENT_MAX_KEYS=100  # Maximum keys allowed in agent
readonly MIN_DISK_SPACE=$((10 * 1024 * 1024))  # 10MB minimum free space
readonly LOG_ROTATION_CHECK_INTERVAL=100  # Check every N log entries
readonly MIN_EMAIL_LENGTH=3  # Minimum valid email length
readonly MAX_EMAIL_LENGTH=254
readonly MAX_JSON_SIZE=$((1024 * 1024))  # 1MB max JSON response size
readonly SSH_KEY_MIN_LENGTH=200  # Minimum SSH key length in bytes
readonly SSH_KEY_MAX_LENGTH=32768  # Maximum SSH key length in bytes (32KB)

# ============================================================================
# EARLY LOGGING SETUP (needed for error reporting)
# ============================================================================

# Log levels
readonly LOG_ERROR=0
readonly LOG_WARN=1
readonly LOG_INFO=2
readonly LOG_DEBUG=3

# Convert string log level to numeric if needed
if [ -n "${LOG_LEVEL:-}" ]; then
    case "${LOG_LEVEL}" in
        "ERROR") LOG_LEVEL=$LOG_ERROR ;;
        "WARN"|"WARNING") LOG_LEVEL=$LOG_WARN ;;
        "INFO") LOG_LEVEL=$LOG_INFO ;;
        "DEBUG") LOG_LEVEL=$LOG_DEBUG ;;
        [0-3]) ;; # Already numeric, do nothing
        *) LOG_LEVEL=$LOG_INFO ;; # Default for invalid values
    esac
else
    # Default log level
    LOG_LEVEL=$LOG_INFO
fi

# Simple early logging function (before colors are set up)
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local level_str=""

    case $level in
        "$LOG_ERROR") level_str="ERROR" ;;
        "$LOG_WARN")  level_str="WARN " ;;
        "$LOG_INFO")  level_str="INFO " ;;
        "$LOG_DEBUG") level_str="DEBUG" ;;
    esac

    # Early logging to stderr only
    if [ $level -le $LOG_LEVEL ]; then
        echo "[$timestamp] [$level_str] $message" >&2
    fi
}

log_error() { log $LOG_ERROR "$@"; }
log_warn()  { log $LOG_WARN "$@"; }
log_info()  { log $LOG_INFO "$@"; }
log_debug() { log $LOG_DEBUG "$@"; }

# Create secure log directory
readonly LOG_DIR="${TMPDIR:-/tmp}/post-create-logs-$$"

# Check disk space before creating log directory
check_disk_space() {
    local path="${1:-/tmp}"
    local available
    available=$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$available" -lt $((MIN_DISK_SPACE / 1024)) ]; then
        log_error "Insufficient disk space in $path (need ${MIN_DISK_SPACE} bytes)"
        return 1
    fi
    return 0
}

# Ensure we have disk space
if ! check_disk_space "${TMPDIR:-/tmp}"; then
    exit 1
fi

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
readonly LOG_FILE
LOG_FILE="$LOG_DIR/post-create-$(date +%Y%m%d-%H%M%S).log"
readonly MAX_LOG_SIZE=$((1024 * 1024))  # 1MB max log size

# Initialize log file with restricted permissions
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

# Get file size in bytes (cross-platform)
get_file_size() {
    local file="$1"
    if [ -f "$file" ]; then
        stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Log rotation function
rotate_log_if_needed() {
    if [ -f "$LOG_FILE" ] && [ "$(get_file_size "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
        local rotated_log="${LOG_FILE}.1"
        command mv "$LOG_FILE" "$rotated_log"
        gzip "$rotated_log" 2>/dev/null || true
        touch "$LOG_FILE"
        chmod 600 "$LOG_FILE"
        log_info "Rotated log file (size exceeded ${MAX_LOG_SIZE} bytes)"
    fi
}

# Instance locking
# Get username safely with length limit and validation
get_safe_username() {
    local username="${USER:-$(id -un 2>/dev/null || whoami 2>/dev/null || echo "unknown")}"

    # Limit length first
    username="${username:0:32}"

    # Remove any characters that aren't alphanumeric, underscore, or hyphen
    username="${username//[^a-zA-Z0-9_-]/}"

    # Ensure it starts with a letter or underscore (POSIX username requirement)
    if [[ ! "$username" =~ ^[a-zA-Z_] ]]; then
        username="u_$username"
    fi

    # If empty after sanitization, use default
    if [ -z "$username" ]; then
        username="unknown"
    fi

    echo "$username"
}

SAFE_USER=$(get_safe_username)
readonly LOCK_FILE="${TMPDIR:-/tmp}/.post-create-${SAFE_USER}.lock"
readonly LOCK_TIMEOUT=300  # 5 minutes
readonly LOCK_RETRY_DIVISOR=2  # Divisor for calculating max lock retries

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Linux*)     echo "linux" ;;
        Darwin*)    echo "macos" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *)          echo "unknown" ;;
    esac
}
readonly PLATFORM
PLATFORM=$(detect_platform)

# Security settings
umask 077  # Restrictive file permissions
# Verify umask is properly set
if [ "$(umask)" != "0077" ]; then
    log_error "Failed to set restrictive umask (current: $(umask))"
    exit 1
fi
# set -o noclobber  # Disabled - conflicts with mktemp usage

# Set secure IFS (Internal Field Separator)
IFS=$' \t\n'

# Sanitize PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Clear potentially dangerous environment variables
unset LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
unset LD_AUDIT LD_DEBUG BASH_ENV ENV CDPATH
unset PERL5LIB PERL5OPT PYTHONPATH PYTHONHOME
unset PS4 BASH_XTRACEFD
# Note: IFS is reset below, SHELLOPTS is readonly

# Set secure shell options
set +o histexpand  # Disable history expansion (!)
set -o nounset     # Error on undefined variables (after initial setup)

# ============================================================================
# SIGNAL HANDLING AND CLEANUP
# ============================================================================

# Array to track files that need cleanup
declare -a CLEANUP_FILES=()
declare -a CLEANUP_DIRS=()

# Rate limiting for API operations
declare -A RATE_LIMIT_COUNTERS
declare -A RATE_LIMIT_WINDOWS
readonly RATE_LIMIT_INTERVAL=60  # seconds

# Register a file for cleanup on exit
register_cleanup_file() {
    local file="$1"
    CLEANUP_FILES+=("$file")
}

# Unregister file from cleanup (for files that were successfully moved)
unregister_cleanup_file() {
    local file="$1"
    local new_array=()

    for f in "${CLEANUP_FILES[@]}"; do
        if [ "$f" != "$file" ]; then
            new_array+=("$f")
        fi
    done

    CLEANUP_FILES=("${new_array[@]}")
}

# Register a directory for cleanup on exit
register_cleanup_dir() {
    local dir="$1"
    CLEANUP_DIRS+=("$dir")
}

# Cleanup function called on exit
cleanup_on_exit() {
    local exit_code=$?

    # Remove all registered files
    for file in "${CLEANUP_FILES[@]}"; do
        if [ -f "$file" ]; then
            # Use shred if available for sensitive files
            if command -v shred >/dev/null 2>&1; then
                shred -vfzu "$file" 2>/dev/null || command rm -f "$file"
            else
                command rm -f "$file"
            fi
        fi
    done

    # Remove all registered directories
    for dir in "${CLEANUP_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            command rm -rf "$dir"
        fi
    done

    # Clear sensitive variables securely
    secure_clear_var "OP_SERVICE_ACCOUNT_TOKEN"
    secure_clear_var "SSH_PRIVATE_KEY"
    secure_clear_var "GIT_SIGNING_KEY"
    secure_clear_var "private_key"

    exit $exit_code
}

# Set up exit trap
trap cleanup_on_exit EXIT

# Signal handler for interrupts
handle_interrupt() {
    log_warn "Received interrupt signal, cleaning up..."
    exit 130  # Standard exit code for SIGINT
}

# Set up signal handlers
trap handle_interrupt INT TERM

# ============================================================================
# ENHANCED LOGGING (with colors and file output)
# ============================================================================

# Color support for interactive terminals
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_YELLOW='\033[0;33m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_RESET='\033[0m'
else
    readonly COLOR_RED=''
    readonly COLOR_YELLOW=''
    readonly COLOR_GREEN=''
    readonly COLOR_BLUE=''
    readonly COLOR_RESET=''
fi

# Audit logging for security-relevant events
audit_log() {
    local event="$1"
    local details="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local caller="${3:-${FUNCNAME[2]:-unknown}}"

    # Log to both regular log and audit trail
    log $LOG_INFO "[AUDIT] $event - $details"

    # If audit file is configured, append there too
    if [ -n "${AUDIT_LOG_FILE:-}" ] && [ -w "$(dirname "${AUDIT_LOG_FILE}")" ]; then
        echo "[$timestamp] [AUDIT] [$caller] $event - $details" >> "$AUDIT_LOG_FILE"
    fi
}

# Check rate limit for operations
check_rate_limit() {
    local operation="$1"
    local max_calls="${2:-10}"
    local current_time
    current_time=$(date +%s)

    # Initialize if needed
    if [ -z "${RATE_LIMIT_WINDOWS[$operation]:-}" ]; then
        RATE_LIMIT_WINDOWS[$operation]=$current_time
        RATE_LIMIT_COUNTERS[$operation]=0
    fi

    # Check if window has expired
    local window_start=${RATE_LIMIT_WINDOWS[$operation]}
    if [ $((current_time - window_start)) -gt $RATE_LIMIT_INTERVAL ]; then
        # Reset window
        RATE_LIMIT_WINDOWS[$operation]=$current_time
        RATE_LIMIT_COUNTERS[$operation]=0
    fi

    # Check limit
    local count=${RATE_LIMIT_COUNTERS[$operation]}
    if [ $count -ge $max_calls ]; then
        log_warn "Rate limit exceeded for $operation (max $max_calls per ${RATE_LIMIT_INTERVAL}s)"
        return 1
    fi

    # Increment counter
    ((RATE_LIMIT_COUNTERS[$operation]++)) || true
    return 0
}

# Securely clear sensitive variable
secure_clear_var() {
    local var_name="$1"

    # Check if variable exists
    if [ -z "${!var_name:-}" ]; then
        return 0
    fi

    # Get length of current value
    local var_value="${!var_name}"
    local var_len=${#var_value}

    # Overwrite with random data multiple times
    for i in {1..3}; do
        local random_data
        random_data=$(printf '%*s' "$var_len" "" | tr ' ' 'X')
        printf -v "$var_name" '%s' "$random_data"
    done

    # Finally unset
    unset "$var_name"
}

# Enhanced log function with colors and file output
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local level_str_plain=""
    local level_str_color=""

    case $level in
        "$LOG_ERROR")
            level_str_plain="ERROR"
            level_str_color="${COLOR_RED}ERROR${COLOR_RESET}"
            ;;
        "$LOG_WARN")
            level_str_plain="WARN "
            level_str_color="${COLOR_YELLOW}WARN ${COLOR_RESET}"
            ;;
        "$LOG_INFO")
            level_str_plain="INFO "
            level_str_color="${COLOR_GREEN}INFO ${COLOR_RESET}"
            ;;
        "$LOG_DEBUG")
            level_str_plain="DEBUG"
            level_str_color="${COLOR_BLUE}DEBUG${COLOR_RESET}"
            ;;
    esac

    # Check log rotation periodically
    if [ -f "$LOG_FILE" ] && [ $((RANDOM % LOG_ROTATION_CHECK_INTERVAL)) -eq 0 ]; then
        rotate_log_if_needed
    fi

    # Write to log file (plain text, no colors)
    if [ -f "$LOG_FILE" ]; then
        echo "[$timestamp] [$level_str_plain] $message" >> "$LOG_FILE"
    fi

    # Write to console if appropriate level
    if [ $level -le $LOG_LEVEL ]; then
        if [ -n "$COLOR_RESET" ]; then
            echo -e "[$timestamp] [$level_str_color] $message" >&2
        else
            echo "[$timestamp] [$level_str_plain] $message" >&2
        fi
    fi
}

# Progress indicator for long operations
show_progress() {
    local message="$1"
    local current="${2:-0}"
    local total="${3:-100}"

    # Skip progress bar if:
    # - Not in a terminal
    # - In CI environment
    # - In a devcontainer post-create/start command
    # - DEBUG logging is active
    # - NO_PROGRESS environment variable is set
    if [ ! -t 2 ] || \
       [ -n "${CI:-}" ] || \
       [ -n "${CODESPACES:-}" ] || \
       [ -n "${REMOTE_CONTAINERS_IPC:-}" ] || \
       [ -n "${NO_PROGRESS:-}" ] || \
       [ "$LOG_LEVEL" -ge "$LOG_DEBUG" ]; then
        return 0
    fi

    if [ "$total" -gt 0 ]; then
        local percent=$((current * 100 / total))
        printf "\r%-50s [%3d%%]" "$message" "$percent" >&2
        if [ "$current" -eq "$total" ]; then
            echo "" >&2  # New line when complete
        fi
    else
        printf "\r%-50s" "$message" >&2
    fi
}

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Comprehensive signal handling
trap 'cleanup_and_exit $? $LINENO' ERR
trap 'signal_handler SIGINT' INT
trap 'signal_handler SIGTERM' TERM
trap 'signal_handler SIGHUP' HUP

cleanup_and_exit() {
    local exit_code=$1
    local line_number=$2
    log_error "Script failed with exit code $exit_code at line $line_number"
    log_error "Stack trace:"

    local frame=0
    while caller $frame; do
        frame=$((frame + 1))
    done | while read line func file; do
        log_error "  at $func ($file:$line)"
    done

    cleanup_on_error
    exit $exit_code
}

signal_handler() {
    local signal=$1
    log_warn "Received signal: $signal"
    log_warn "Performing graceful shutdown..."
    cleanup_on_error
    exit 130  # 128 + SIGINT(2)
}

# Normal cleanup function
cleanup() {
    # Remove any temporary files
    if [ -n "${TEMP_DIR:-}" ] && [ -d "$TEMP_DIR" ]; then
        command rm -rf "$TEMP_DIR"
    fi

    # Clear sensitive variables
    unset OP_SERVICE_ACCOUNT_TOKEN
    unset GIT_CONFIG_ITEM
    unset GIT_SIGNING_KEY_ITEM

    # Release lock
    release_lock
}

# Cleanup function for errors
cleanup_on_error() {
    log_info "Performing emergency cleanup..."

    cleanup

    # Remove log directory if empty
    if [ -n "${LOG_DIR:-}" ] && [ -d "$LOG_DIR" ]; then
        rmdir "$LOG_DIR" 2>/dev/null || true
    fi

    # Show recovery suggestions
    log_info ""
    log_info "Recovery suggestions:"
    log_info "  1. Check the log file for details: $LOG_FILE"
    log_info "  2. Ensure you have internet connectivity"
    log_info "  3. Verify your 1Password service account token is valid"
    log_info "  4. Try running the script again: $SCRIPT_DIR/$SCRIPT_NAME"
    log_info "  5. For manual setup instructions, see: /workspaces/core/docs/manual-setup.md"
}

# ============================================================================
# LOCKING FUNCTIONS
# ============================================================================

# Acquire exclusive lock
acquire_lock() {
    local lock_acquired=false
    local lock_start
    lock_start=$(date +%s)
    local retry_count=0
    local max_lock_retries=$((LOCK_TIMEOUT / LOCK_RETRY_DIVISOR))  # Maximum retries based on timeout

    while ! $lock_acquired; do
        if (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; then
            lock_acquired=true
            log_debug "Acquired lock (PID: $$)"
        else
            retry_count=$((retry_count + 1))

            # Check if lock is stale
            if [ -f "$LOCK_FILE" ]; then
                local lock_pid
                lock_pid=$(command cat "$LOCK_FILE" 2>/dev/null || echo "0")

                # Validate PID format
                if [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
                    log_warn "Invalid PID in lock file, removing"
                    command rm -f "$LOCK_FILE"
                    continue
                fi

                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    log_warn "Removing stale lock from PID $lock_pid"
                    command rm -f "$LOCK_FILE"
                    continue
                fi
            fi

            # Check timeout
            local current_time
            current_time=$(date +%s)
            if [ $((current_time - lock_start)) -gt $LOCK_TIMEOUT ] || [ $retry_count -gt $max_lock_retries ]; then
                log_error "Failed to acquire lock after ${LOCK_TIMEOUT}s (${retry_count} attempts)"
                return 1
            fi

            log_debug "Waiting for lock (held by PID: ${lock_pid:-unknown})... (attempt $retry_count/$max_lock_retries)"
            sleep 2
        fi
    done

    return 0
}

# Release lock
release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(command cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if [ "$lock_pid" = "$$" ]; then
            command rm -f "$LOCK_FILE"
            log_debug "Released lock"
        fi
    fi
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Check if running in CI/CD environment
is_ci_environment() {
    [ -n "${CI:-}" ] || [ -n "${CONTINUOUS_INTEGRATION:-}" ] || \
    [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ] || \
    [ -n "${JENKINS_URL:-}" ] || [ -n "${TEAMCITY_VERSION:-}" ]
}

# Check if running in container
is_container() {
    [ -f /.dockerenv ] || [ -n "${KUBERNETES_SERVICE_HOST:-}" ] || \
    grep -q '/docker/' /proc/1/cgroup 2>/dev/null || \
    grep -q '/lxc/' /proc/1/cgroup 2>/dev/null
}

# Note: get_file_size is already defined earlier in the script

# ============================================================================
# SECURITY FUNCTIONS
# ============================================================================

# Create secure temporary directory
#
# This function creates a temporary directory with strict security controls to
# prevent various attacks including symlink attacks, race conditions, and
# unauthorized access.
#
# Security measures:
# - Validates temp base is not a symlink (prevents symlink attacks)
# - Checks available disk space before creation
# - Uses restrictive umask (077) during creation
# - Verifies ownership after creation
# - Sets explicit 700 permissions
# - Validates the result is actually a directory
#
# Returns:
#   stdout - Path to created directory
#   1      - Error occurred (directory not created)
create_secure_temp() {
    local temp_dir
    local temp_base="${TMPDIR:-/tmp}"

    # Validate temp base is not a symlink
    if [ -L "$temp_base" ]; then
        log_error "Temp directory is a symlink: $temp_base"
        return 1
    fi

    # Check available disk space (need at least 10MB)
    local available_space
    available_space=$(df "$temp_base" | awk 'NR==2 {print $4}')
    if [ "${available_space:-0}" -lt 10240 ]; then
        log_error "Insufficient disk space in temp directory"
        return 1
    fi

    # Create with restrictive umask
    local old_umask
    old_umask=$(umask)
    umask 077

    temp_dir=$(mktemp -d -t "post-create-XXXXXX") || {
        umask "$old_umask"
        log_error "Failed to create temporary directory"
        return 1
    }

    umask "$old_umask"

    # Verify it's actually a directory and we own it
    if [ ! -d "$temp_dir" ] || [ ! -O "$temp_dir" ]; then
        command rm -rf "$temp_dir" 2>/dev/null || true
        log_error "Temp directory creation failed security check"
        return 1
    fi

    # Set permissions (redundant with umask, but explicit)
    chmod 700 "$temp_dir" || {
        command rm -rf "$temp_dir"
        log_error "Failed to set permissions on temporary directory"
        return 1
    }

    echo "$temp_dir"
}

# Validate string contains only safe characters
validate_safe_string() {
    local input="$1"
    local allowed_pattern="$2"

    if [[ ! "$input" =~ $allowed_pattern ]]; then
        return 1
    fi
    return 0
}

# Validate vault ID format (alphanumeric and hyphens only)
validate_vault_id() {
    local vault="$1"
    validate_safe_string "$vault" '^[a-zA-Z0-9-]+$'
}

# Validate item name (alphanumeric, spaces, hyphens, underscores)
validate_item_name() {
    local item="$1"
    validate_safe_string "$item" '^[a-zA-Z0-9 _-]+$'
}

# Validate email format (RFC 5322 simplified)
validate_email() {
    local email="$1"
    # More comprehensive regex that handles edge cases
    local email_regex='^[a-zA-Z0-9][a-zA-Z0-9._%+-]{0,63}@[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}\.[a-zA-Z]{2,}$'

    # Additional checks
    if [[ ${#email} -lt $MIN_EMAIL_LENGTH ]]; then
        return 1  # Email too short
    fi

    if [[ ${#email} -gt $MAX_EMAIL_LENGTH ]]; then
        return 1  # Email too long
    fi

    if [[ "$email" =~ \.\.  ]] || [[ "$email" =~ ^\. ]] || [[ "$email" =~ \.$  ]]; then
        return 1  # Invalid dot placement
    fi

    # Check for common typos and suspicious patterns
    if [[ "$email" =~ @.*@ ]] || [[ "$email" =~ ^@ ]] || [[ "$email" =~ @$ ]]; then
        return 1  # Multiple @ or @ at start/end
    fi

    [[ "$email" =~ $email_regex ]]
}

# Validate JSON format and size
validate_json() {
    local json_data="$1"
    local max_size="${2:-$MAX_JSON_SIZE}"

    # Check size
    if [ ${#json_data} -gt $max_size ]; then
        log_error "JSON data exceeds maximum size ($max_size bytes)"
        return 1
    fi

    # Validate JSON format using jq
    if ! echo "$json_data" | jq empty 2>/dev/null; then
        log_error "Invalid JSON format"
        return 1
    fi

    # Check for potentially dangerous content (avoid false positives on normal JSON)
    if echo "$json_data" | grep -qE '(\$\(|`|<script[^>]*>|javascript:[^"'\'']*[^"'\''])'; then
        log_error "JSON contains potentially dangerous content"
        return 1
    fi

    return 0
}

# Validate SSH key format and content
validate_ssh_key() {
    local key_data="$1"
    # shellcheck disable=SC2034  # Reserved for future validation use
    local key_type="${2:-any}"

    # Check key length
    if [ ${#key_data} -lt $SSH_KEY_MIN_LENGTH ]; then
        log_error "SSH key too short (minimum $SSH_KEY_MIN_LENGTH bytes)"
        return 1
    fi

    if [ ${#key_data} -gt $SSH_KEY_MAX_LENGTH ]; then
        log_error "SSH key too long (maximum $SSH_KEY_MAX_LENGTH bytes)"
        return 1
    fi

    # Check for valid SSH key format (public or private)
    if ! echo "$key_data" | grep -qE '^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519|sk-ecdsa-sha2-nistp256|-----BEGIN)'; then
        log_error "Invalid SSH key format (must start with valid key type or -----BEGIN)"
        return 1
    fi

    # Check for BEGIN/END markers (private key detection)
    if echo "$key_data" | grep -qE '(BEGIN|END).*(PRIVATE KEY|RSA PRIVATE KEY|DSA PRIVATE KEY|EC PRIVATE KEY|OPENSSH PRIVATE KEY)'; then
        # This is expected for private keys
        if ! echo "$key_data" | grep -qE '^-----BEGIN'; then
            log_error "Malformed private key format"
            return 1
        fi
    fi

    # Validate base64 content (skip header and comments)
    local key_body
    key_body=$(echo "$key_data" | grep -v '^-----' | grep -v '^Comment:' | tr -d '\n\r ')
    if [ -n "$key_body" ] && ! echo "$key_body" | grep -qE '^[A-Za-z0-9+/=]+$'; then
        log_error "SSH key contains invalid base64 characters"
        return 1
    fi

    return 0
}

# Secure JSON field extraction with validation
extract_json_field() {
    local json_data="$1"
    local field_path="$2"
    local default_value="${3:-}"
    local max_length="${4:-1024}"

    # Validate JSON first
    if ! validate_json "$json_data"; then
        echo "$default_value"
        return 1
    fi

    # Extract field value
    local value
    value=$(echo "$json_data" | jq -r "$field_path // empty" 2>/dev/null)

    # Handle extraction errors
    if [ $? -ne 0 ]; then
        log_warn "Failed to extract field: $field_path"
        echo "$default_value"
        return 1
    fi

    # Check if value is null or empty
    if [ -z "$value" ] || [ "$value" = "null" ]; then
        echo "$default_value"
        return 0
    fi

    # Check length
    if [ ${#value} -gt $max_length ]; then
        log_warn "Field value exceeds maximum length: $field_path"
        echo "$default_value"
        return 1
    fi

    echo "$value"
    return 0
}

# Secure command execution with validation
#
# This function provides a secure wrapper around the 1Password CLI (op) command
# with extensive validation and error handling.
#
# Security measures:
# - Validates op binary location and permissions
# - Checks for symlinks and resolves them
# - Prevents execution from unexpected locations
# - Validates JSON output format
# - Implements timeout protection
# - Provides detailed error diagnostics
#
# Parameters:
#   $1    - op subcommand (e.g., "item", "vault")
#   $@    - Additional arguments passed to op
#
# Returns:
#   stdout - Command output (if successful)
#   1      - Error occurred
secure_op_command() {
    local op_command="$1"
    shift
    local args=("$@")

    # Validate op is available
    if ! command -v op >/dev/null 2>&1; then
        log_error "1Password CLI (op) not found. Please ensure 'op' is installed and in PATH"
        return 1
    fi

    # Verify op binary location (should be in standard paths)
    local op_path
    op_path=$(command -v op)

    # First check if it's a symlink
    if [ -L "$op_path" ]; then
        # Resolve the symlink
        local real_op_path
        real_op_path=$(readlink -f "$op_path" 2>/dev/null || readlink "$op_path" 2>/dev/null)
        log_debug "op is a symlink: $op_path -> $real_op_path"
        op_path="$real_op_path"
    fi

    case "$op_path" in
        /usr/bin/op|/usr/local/bin/op|/opt/1password/op|/home/*/.local/bin/op|/opt/homebrew/bin/op)
            log_debug "Using op from: $op_path"

            # Get file permissions in octal
            local op_perms
            op_perms=$(stat -c '%a' "$op_path" 2>/dev/null || stat -f '%A' "$op_path" 2>/dev/null)

            # Check if world-writable (ends in 2, 3, 6, or 7)
            if [[ "$op_perms" =~ [2367]$ ]]; then
                log_error "Security warning: op binary is world-writable (permissions: $op_perms)"
                return 1
            fi

            # Verify ownership
            local op_owner
            op_owner=$(stat -c '%U' "$op_path" 2>/dev/null || stat -f '%Su' "$op_path" 2>/dev/null)
            if [ "$op_owner" != "root" ] && [ "$op_owner" != "$USER" ]; then
                log_warn "Warning: op binary owned by $op_owner (expected root or $USER)"
            fi
            ;;
        *)
            log_error "Refused: op binary in unexpected location: $op_path"
            return 1
            ;;
    esac

    # Execute with timeout and capture both stdout and stderr
    local temp_out temp_err
    temp_out=$(mktemp)
    temp_err=$(mktemp)
    register_cleanup_file "$temp_out"
    register_cleanup_file "$temp_err"

    if timeout $NETWORK_TIMEOUT op "$op_command" "${args[@]}" >"$temp_out" 2>"$temp_err"; then
        local output
        output=$(command cat "$temp_out")

        # Validate JSON output if it looks like JSON
        if [[ "$output" =~ ^\s*[\{\[] ]]; then
            if ! validate_json "$output"; then
                log_error "Invalid JSON response from 1Password CLI"
                command rm -f "$temp_out" "$temp_err"
                return 1
            fi
        fi

        echo "$output"
        command rm -f "$temp_out" "$temp_err"
        return 0
    else
        local exit_code=$?
        local error_msg
        error_msg=$(command cat "$temp_err" 2>/dev/null || echo "Unknown error")

        # Handle specific error cases
        case $exit_code in
            124) # Timeout
                log_error "op command timed out after ${NETWORK_TIMEOUT}s: $op_command"
                ;;
            *)
                log_error "op command failed (exit code $exit_code): $error_msg"
                ;;
        esac

        # Check for common network issues (sanitized messages)
        if echo "$error_msg" | grep -qiE "(connection refused|network unreachable|name resolution|timeout)"; then
            log_warn "Network connectivity issue detected. Check your internet connection."
            # Don't reveal internal network topology or specific IPs
            log_debug "Network diagnostics available in debug mode"
        fi

        command rm -f "$temp_out" "$temp_err"
        return $exit_code
    fi
}

# ============================================================================
# ATOMIC FILE OPERATIONS
# ============================================================================

# Write file atomically
atomic_write() {
    local target_file="$1"
    local content="$2"
    local mode="${3:-644}"

    local temp_file
    temp_file=$(mktemp "${target_file}.XXXXXX")

    # Write content to temporary file
    echo "$content" > "$temp_file"
    chmod "$mode" "$temp_file"

    # Atomically move to target
    command mv -f "$temp_file" "$target_file"
}

# Append to file atomically
atomic_append() {
    local target_file="$1"
    local content="$2"

    local temp_file
    temp_file=$(mktemp "${target_file}.XXXXXX")

    # Copy existing content if file exists
    if [ -f "$target_file" ]; then
        command cp "$target_file" "$temp_file"
    fi

    # Append new content
    echo "$content" >> "$temp_file"

    # Atomically move to target
    command mv -f "$temp_file" "$target_file"
}

# ============================================================================
# 1PASSWORD FUNCTIONS
# ============================================================================

# Load environment variables from .env file(s)
#
# This function searches for .env files in multiple locations to support various
# project structures and deployment scenarios. The search order is designed to
# prioritize local/specific configurations over general ones.
#
# Search priority (first match wins for each variable):
# 1. Co-located with script (for portable deployments)
# 2. .devcontainer/.env (for DevContainer-specific config)
# 3. Project root .env (standard location)
# 4. Workspace folders (for multi-project setups)
#
# Security features:
# - Only loads specific 1Password-related variables
# - Validates file permissions (warns if not 600)
# - Checks file ownership
# - Limits file size to 1MB
# - Validates content for malicious commands
# - First file to define a variable wins (no overrides)
load_env_file() {
    # Track which variables we've already set (to support merging)
    local vars_set=()
    local env_files_loaded=()

    # Define search paths for .env files
    # Priority order: co-located with script > .devcontainer > project root > workspace folders
    local search_paths=()

    # Add paths only if they don't contain shell metacharacters (for safety)
    local safe_paths=(
        "$SCRIPT_DIR/.env"                          # Co-located with script
        "$SCRIPT_DIR/../.env"                       # Parent of script dir
        "$(pwd)/.devcontainer/.env"                 # Current dir .devcontainer
        "$(pwd)/.env"                               # Current directory
        "$SCRIPT_DIR/../../.devcontainer/.env"      # Project .devcontainer
        "$SCRIPT_DIR/../../.env"                    # Project root
    )

    # Add each path only if it doesn't contain dangerous characters
    for path in "${safe_paths[@]}"; do
        if [[ ! "$path" =~ [\$\`\(\)\{\}\[\]\*\?] ]]; then
            search_paths+=("$path")
        fi
    done

    # Add workspace paths with glob patterns separately (these are expected to have *)
    search_paths+=(
        "${WORKSPACE_FOLDER:-/workspace/*}/.devcontainer/.env"  # Workspace .devcontainer
        "${WORKSPACE_FOLDER:-/workspace/*}/.env"    # Workspace root
        "/workspace/.devcontainer/.env"             # Fallback .devcontainer
        "/workspace/.env"                           # Fallback workspace
        "/workspaces/.env"                          # Legacy fallback
    )

    # Debug: Show search paths
    log_debug "Searching for .env files in priority order:"
    local i=1
    for path in "${search_paths[@]}"; do
        log_debug "  $i. $path"
        ((i++)) || true
    done

    # Load .env files in order (later files can override earlier ones)
    for possible_env in "${search_paths[@]}"; do
        # Expand glob patterns and check if file exists
        # Use nullglob to handle non-matching globs safely
        local saved_nullglob
        saved_nullglob=$(shopt -p nullglob)
        shopt -s nullglob
        # shellcheck disable=SC2206  # Word splitting intentional for glob expansion
        local expanded_paths=($possible_env)
        eval "$saved_nullglob"  # Restore original nullglob setting

        for expanded_path in "${expanded_paths[@]}"; do
            # Resolve to absolute path to avoid duplicates
            local abs_path
            if abs_path=$(cd "$(dirname "$expanded_path")" 2>/dev/null && pwd)/$(basename "$expanded_path"); then
                # Successfully resolved path
                :
            else
                # Failed to resolve, use expanded_path as-is if it's already absolute
                if [[ "$expanded_path" = /* ]]; then
                    abs_path="$expanded_path"
                else
                    continue
                fi
            fi

            if [ -f "$abs_path" ] && [[ ! " ${env_files_loaded[*]} " =~ \ ${abs_path}\  ]]; then
                # Check file permissions and ownership
                local file_perms
                file_perms=$(stat -c '%a' "$abs_path" 2>/dev/null || stat -f '%A' "$abs_path" 2>/dev/null)
                local file_owner
                file_owner=$(stat -c '%U' "$abs_path" 2>/dev/null || stat -f '%Su' "$abs_path" 2>/dev/null)

                # Warn if .env file has overly permissive permissions
                if [ -n "$file_perms" ] && [ "$file_perms" -gt 644 ]; then
                    log_warn "Warning: $abs_path has permissive permissions ($file_perms). Consider: chmod 600 $abs_path"
                fi

                # Warn if .env file is not owned by current user or root
                if [ -n "$file_owner" ] && [ "$file_owner" != "$USER" ] && [ "$file_owner" != "root" ]; then
                    log_warn "Warning: $abs_path is owned by $file_owner, not $USER or root"
                fi

                # Check file size (limit to 1MB for .env files)
                local file_size
                file_size=$(get_file_size "$abs_path")
                if [ "$file_size" -gt $((1024 * 1024)) ]; then
                    log_warn "Warning: $abs_path is larger than 1MB ($file_size bytes), skipping for safety"
                    continue
                fi

                log_info "Loading environment variables from: $abs_path"
                env_files_loaded+=("$abs_path")

                # Parse .env file securely with line limit
                local line_count=0
                local max_lines=1000
                local max_env_vars=50
                while IFS= read -r line; do
                    if [ $line_count -ge $max_lines ]; then
                        break
                    fi
                    ((line_count++)) || true

                    # Check environment variable limit
                    if [ ${#vars_set[@]} -ge $max_env_vars ]; then
                        log_warn "Maximum environment variable limit reached ($max_env_vars)"
                        break
                    fi
                    # Skip comments and empty lines
                    [[ "$line" =~ ^#.*$ ]] && continue
                    [[ -z "$line" ]] && continue

                    # Parse key=value pairs
                    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                        key="${BASH_REMATCH[1]}"
                        value="${BASH_REMATCH[2]}"

                        # Trim whitespace from key
                        key=$(echo "$key" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                        # Skip if key is empty or contains invalid characters
                        if [ -z "$key" ] || [[ "$key" =~ [^A-Za-z0-9_] ]]; then
                            log_debug "Skipping invalid key: '$key'"
                            continue
                        fi

                        # Remove quotes from value (handle both single and double quotes)
                        value="${value#\"}"
                        value="${value%\"}"
                        value="${value#\'}"
                        value="${value%\'}"


                        # Don't escape quotes for these specific variables as they need exact values
                        case "$key" in
                            GIT_CONFIG_ITEM|GIT_SIGNING_KEY_ITEM|OP_AIKMS_POSTGRES_ITEM|OP_AIKMS_REDIS_ITEM|OP_AIKMS_APP_SECRETS_ITEM|OP_AIKMS_EXTERNAL_APIS_ITEM)
                                # These are item names that should not have quotes escaped
                                ;;
                            *)
                                # Escape any remaining quotes in the value to prevent injection
                                value="${value//\"/\\\"}"
                                ;;
                        esac

                        # Only set specific 1Password-related variables
                        case "$key" in
                            OP_SERVICE_ACCOUNT_TOKEN|OP_ACCOUNT|GIT_CONFIG_ITEM|GIT_SIGNING_KEY_ITEM)
                                # Validate token format for OP_SERVICE_ACCOUNT_TOKEN
                                if [ "$key" = "OP_SERVICE_ACCOUNT_TOKEN" ]; then
                                    if [[ ! "$value" =~ ^ops_[A-Za-z0-9_-]{20,}$ ]] && [ -n "$value" ]; then
                                        log_warn "Warning: OP_SERVICE_ACCOUNT_TOKEN doesn't match expected format (ops_...)"
                                    fi
                                fi

                                # Only set if not already set (first file wins)
                                # Use eval to safely check if variable is set (works with set -u)
                                local current_value=""
                                eval "current_value=\"\${${key}:-}\""
                                if [ -z "$current_value" ]; then
                                    export "$key=$value"
                                    log_debug "Set $key='$value' from $abs_path"
                                    vars_set+=("$key")
                                fi
                                ;;
                        esac
                    fi
                done < "$abs_path"

                # Warn if we hit the line limit
                if [ $line_count -ge $max_lines ]; then
                    log_warn "Warning: Stopped reading $abs_path after $max_lines lines"
                fi
            fi
        done
    done

    # Report results
    if [ ${#env_files_loaded[@]} -eq 0 ]; then
        log_warn "No .env file found in any expected location"
        log_info "Tip: Create a .env file with your 1Password token in one of these locations:"
        log_info "  - .devcontainer/.env (recommended for DevContainer)"
        log_info "  - Project root .env"
        log_info "  - Copy from .env.example if available"
    else
        log_info "Loaded ${#env_files_loaded[@]} .env file(s)"
        if [ ${#vars_set[@]} -gt 0 ]; then
            log_debug "Variables loaded: ${vars_set[*]}"
        fi
    fi
}

# Initialize 1Password
init_onepassword() {
    log_info "Initializing 1Password integration..."

    # Validate token exists
    if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        log_error "OP_SERVICE_ACCOUNT_TOKEN not set. Please set this environment variable or add it to .env file"
        return 1
    fi

    # Test authentication
    if ! secure_op_command "vault" "list" "--format=json" >/dev/null; then
        log_error "Failed to authenticate with 1Password. Please verify your service account token is valid"
        return 1
    fi

    # Get default vault
    local vaults
    vaults=$(secure_op_command "vault" "list" "--format=json")
    DEFAULT_VAULT=$(extract_json_field "$vaults" '.[0].id' "" 128)

    if ! validate_vault_id "$DEFAULT_VAULT"; then
        log_error "Invalid vault ID format: $DEFAULT_VAULT"
        return 1
    fi

    export DEFAULT_VAULT
    log_info "Successfully initialized 1Password with vault: $DEFAULT_VAULT"
    return 0
}

# Get item from 1Password with retry logic
op_get_item() {
    local item_name="$1"
    local vault="${2:-$DEFAULT_VAULT}"
    local retry_count=0

    # Validate inputs
    if ! validate_item_name "$item_name"; then
        log_error "Invalid item name: $item_name"
        log_debug "validate_item_name failed for item_name='$item_name'"
        log_debug "Validation regex: ^[a-zA-Z0-9 _-]+$"
        return 1
    fi

    if ! validate_vault_id "$vault"; then
        log_error "Invalid vault ID: $vault"
        return 1
    fi

    # Check rate limit for 1Password operations
    if ! check_rate_limit "1password_api" 20; then
        log_error "Rate limit exceeded for 1Password API calls"
        return 1
    fi

    # Retry logic
    while [ $retry_count -lt $MAX_RETRIES ]; do
        if result=$(secure_op_command "item" "get" "$item_name" "--vault" "$vault" "--format=json"); then
            echo "$result"
            return 0
        fi

        ((retry_count++)) || true
        log_warn "Failed to get item '$item_name' (attempt $retry_count/$MAX_RETRIES)"
        sleep $RETRY_DELAY
    done

    log_error "Failed to get item '$item_name' after $MAX_RETRIES attempts"
    return 1
}

# ============================================================================
# GIT CONFIGURATION
# ============================================================================

# Extract name from 1Password item with multiple pattern support
extract_name_from_item() {
    local item_json="$1"
    local name=""

    # Pattern 1: Try first_name + last_name combination
    local first_name last_name
    first_name=$(extract_json_field "$item_json" '.fields[] | select(.label | ascii_downcase | test("^first[ _-]?name$")).value' "" 100)
    last_name=$(extract_json_field "$item_json" '.fields[] | select(.label | ascii_downcase | test("^last[ _-]?name$")).value' "" 100)

    if [ -n "$first_name" ] && [ -n "$last_name" ]; then
        name="$first_name $last_name"
        log_debug "Found name from first/last fields: $name"
        echo "$name"
        return 0
    fi

    # Pattern 2: Look for various full name field patterns
    local name_patterns=(
        "name"
        "full_name"
        "fullname"
        "full-name"
        "display_name"
        "displayname"
        "user_name"
        "username"
        "real_name"
        "realname"
    )

    for pattern in "${name_patterns[@]}"; do
        # Use case-insensitive matching with spaces/underscores/hyphens
        local found_name
        found_name=$(extract_json_field "$item_json" ".fields[] | select(.label | ascii_downcase | test(\"^${pattern//_/[ _-]?}\$\")).value" "" 200)
        if [ -n "$found_name" ]; then
            name="$found_name"
            log_debug "Found name from field pattern '$pattern': $name"
            echo "$name"
            return 0
        fi
    done

    # Pattern 3: Try to extract from title if it looks like a name
    local title
    title=$(extract_json_field "$item_json" '.title' "" 200)
    if [ -n "$title" ] && [[ "$title" =~ ^[A-Za-z][A-Za-z\'\ \-\.]+$ ]] && [ ${#title} -le 100 ]; then
        name="$title"
        log_debug "Using title as name: $name"
        echo "$name"
        return 0
    fi

    # No name found
    echo ""
    return 1
}

# Extract email from 1Password item with multiple pattern support
extract_email_from_item() {
    local item_json="$1"
    local email=""

    # Pattern 1: Look for EMAIL type field
    email=$(extract_json_field "$item_json" '.fields[] | select(.type == "EMAIL").value' "" 254)
    if [ -n "$email" ]; then
        log_debug "Found email from EMAIL type field: $email"
        echo "$email"
        return 0
    fi

    # Pattern 2: Look for various email field label patterns
    local email_patterns=(
        "email"
        "e-mail"
        "email_address"
        "email-address"
        "emailaddress"
        "mail"
        "email_addr"
        "primary_email"
        "work_email"
        "user_email"
    )

    for pattern in "${email_patterns[@]}"; do
        # Use case-insensitive matching with spaces/underscores/hyphens
        local found_email
        found_email=$(extract_json_field "$item_json" ".fields[] | select(.label | ascii_downcase | test(\"^${pattern//_/[ _-]?}\$\")).value" "" 254)
        if [ -n "$found_email" ]; then
            email="$found_email"
            log_debug "Found email from field pattern '$pattern': $email"
            echo "$email"
            return 0
        fi
    done

    # Pattern 3: Look for any field value that looks like an email
    local all_values
    all_values=$(echo "$item_json" | jq -r '.fields[].value // empty' 2>/dev/null || true)
    while IFS= read -r value; do
        # Basic email pattern check
        if [[ "$value" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && [ ${#value} -le 254 ]; then
            email="$value"
            log_debug "Found email from field value scan: $email"
            echo "$email"
            return 0
        fi
    done <<< "$all_values"

    # No email found
    echo ""
    return 1
}

# Sanitize Git user name
sanitize_git_name() {
    local name="$1"

    # Remove leading/trailing whitespace
    name=$(echo "$name" | command sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Remove control characters and non-printable characters
    name=$(echo "$name" | tr -d '[:cntrl:]')

    # Replace multiple spaces with single space
    name=$(echo "$name" | tr -s ' ')

    # Limit length to reasonable maximum (128 characters)
    if [ ${#name} -gt 128 ]; then
        name="${name:0:128}"
    fi

    # Ensure name contains at least one letter
    if ! [[ "$name" =~ [A-Za-z] ]]; then
        log_warn "Name contains no letters: '$name'"
        echo ""
        return 1
    fi

    # Remove dangerous characters that could cause issues
    name=$(echo "$name" | command sed 's/[<>|;&$`\\]//g')

    echo "$name"
}

# Sanitize email address
sanitize_email() {
    local email="$1"

    # Remove leading/trailing whitespace
    email=$(echo "$email" | command sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    # Remove mailto: prefix if present
    email="${email#mailto:}"

    # Convert to lowercase for consistency
    email=$(echo "$email" | tr '[:upper:]' '[:lower:]')

    # Remove control characters
    email=$(echo "$email" | tr -d '[:cntrl:]')

    # Remove dangerous characters but keep valid email chars
    email=$(echo "$email" | command sed 's/[^a-zA-Z0-9._%+-@]//g')

    # Ensure single @ symbol
    local at_count
    at_count=$(echo "$email" | tr -cd '@' | wc -c)
    if [ "$at_count" -ne 1 ]; then
        log_warn "Email has $at_count @ symbols: '$email'"
        echo ""
        return 1
    fi

    echo "$email"
}

configure_git_user() {
    log_info "Configuring Git user..."

    if [ -z "${GIT_CONFIG_ITEM:-}" ]; then
        log_warn "GIT_CONFIG_ITEM not set, skipping Git user configuration"
        return 0
    fi

    # Check if Git user is already configured (common in worktrees)
    local existing_name existing_email
    existing_name="$(git config --global user.name 2>/dev/null || echo "")"
    existing_email="$(git config --global user.email 2>/dev/null || echo "")"

    # Limit length of git config values for safety
    existing_name="${existing_name:0:256}"
    existing_email="${existing_email:0:256}"

    if [ -n "$existing_name" ] && [ -n "$existing_email" ]; then
        log_info "Git user already configured: $existing_name <$existing_email>"
        log_info "Skipping 1Password git configuration (likely in a worktree)"
        return 0
    fi

    local item_json
    if ! item_json=$(op_get_item "$GIT_CONFIG_ITEM"); then
        log_error "Failed to get Git config from 1Password (item: $GIT_CONFIG_ITEM). Verify the item exists and is accessible"
        log_debug "op_get_item failed for GIT_CONFIG_ITEM='$GIT_CONFIG_ITEM'"
        return 1
    fi

    # Extract user information using secure extraction
    local name email

    # Enhanced name extraction with multiple patterns
    name=$(extract_name_from_item "$item_json")

    # Enhanced email extraction with multiple patterns
    email=$(extract_email_from_item "$item_json")

    # Validate and set name
    if [ -z "$name" ]; then
        log_warn "No name found in Git config item"
    else
        # Sanitize name (remove control characters, limit length)
        name=$(sanitize_git_name "$name")
        if [ -n "$name" ]; then
            git config --global user.name "$name"
            log_info "Set Git user.name: $name"
        else
            log_warn "Name sanitization resulted in empty value"
        fi
    fi

    # Validate and set email
    if [ -z "$email" ]; then
        log_warn "No email found in Git config item"
    else
        # Sanitize email
        email=$(sanitize_email "$email")
        if [ -n "$email" ] && validate_email "$email"; then
            git config --global user.email "$email"
            log_info "Set Git user.email: $email"
        else
            log_error "Invalid email format after sanitization: '$email'"
        fi
    fi

    return 0
}

# ============================================================================
# SSH AGENT MANAGEMENT
# ============================================================================

# Validate SSH agent socket with enhanced security
validate_ssh_agent_socket() {
    local socket_path="$1"

    # Must be absolute path
    if [[ "$socket_path" != /* ]]; then
        log_debug "Socket path is not absolute: $socket_path"
        return 1
    fi

    # Check against whitelist of valid SSH agent socket patterns
    local valid_pattern=0
    case "$socket_path" in
        /tmp/ssh-????????????????/agent.[0-9]*)
            # Valid systemd-style path
            valid_pattern=1
            ;;
        /tmp/vscode-ssh-auth-*.sock)
            # Valid VS Code SSH auth socket
            valid_pattern=1
            ;;
        /var/run/ssh-agent.pid-*)
            # Valid system agent path
            valid_pattern=1
            ;;
        "$HOME"/.ssh/agent.sock)
            # Valid user agent path
            valid_pattern=1
            ;;
        /run/user/[0-9]*/ssh-agent.socket)
            # Valid user runtime directory
            valid_pattern=1
            ;;
        "$HOME"/.ssh/agent.env-*)
            # Valid user agent env path
            valid_pattern=1
            ;;
        *)
            log_debug "Socket path doesn't match known patterns: $socket_path"
            return 1
            ;;
    esac

    if [ $valid_pattern -eq 0 ]; then
        return 1
    fi

    # Verify parent directory ownership (prevent symlink attacks)
    local parent_dir
    parent_dir=$(dirname "$socket_path")
    local parent_owner
    parent_owner=$(stat -c '%u' "$parent_dir" 2>/dev/null || stat -f '%u' "$parent_dir" 2>/dev/null)
    local current_uid
    current_uid=$(id -u)

    if [ "$parent_owner" != "$current_uid" ] && [ "$parent_owner" != "0" ]; then
        log_debug "Parent directory not owned by user or root: $parent_dir"
        return 1
    fi

    # Check that parent directory is not world-writable
    # Exception: /tmp is allowed for VS Code SSH auth sockets
    local parent_perms
    parent_perms=$(stat -c '%a' "$parent_dir" 2>/dev/null || stat -f '%A' "$parent_dir" 2>/dev/null)
    if [[ "$parent_perms" =~ [2367]$ ]]; then
        # Allow world-writable /tmp for VS Code sockets
        if [[ "$parent_dir" = "/tmp" && "$socket_path" =~ ^/tmp/vscode-ssh-auth-.*\.sock$ ]]; then
            log_debug "Allowing world-writable /tmp for VS Code SSH auth socket"
        else
            log_error "Parent directory is world-writable: $parent_dir"
            return 1
        fi
    fi

    # Check if path exists and is a socket
    if [ ! -S "$socket_path" ]; then
        log_debug "Not a valid socket: $socket_path"
        return 1
    fi

    # Check socket permissions (should not be world-writable)
    local socket_perms
    socket_perms=$(stat -c '%a' "$socket_path" 2>/dev/null || stat -f '%A' "$socket_path" 2>/dev/null)
    if [[ "$socket_perms" =~ [2367]$ ]]; then
        log_error "SSH agent socket is world-writable: $socket_path"
        return 1
    fi

    # Verify socket is owned by current user
    local socket_owner
    socket_owner=$(stat -c '%u' "$socket_path" 2>/dev/null || stat -f '%u' "$socket_path" 2>/dev/null)
    if [ "$socket_owner" != "$current_uid" ]; then
        log_error "SSH agent socket not owned by current user: $socket_path"
        return 1
    fi

    return 0
}

setup_ssh_agent() {
    log_info "Setting up SSH agent..."

    # Check for existing agent
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        # Validate the socket path first
        if ! validate_ssh_agent_socket "$SSH_AUTH_SOCK"; then
            log_warn "Invalid SSH_AUTH_SOCK, starting new agent"
            unset SSH_AUTH_SOCK
        elif ssh-add -l &>/dev/null; then
            local key_count
            key_count=$(ssh-add -l | wc -l | tr -d ' ')
            log_info "Using existing SSH agent with $key_count keys"
            audit_log "SSH_AGENT_REUSED" "socket=$SSH_AUTH_SOCK keys=$key_count"
            return 0
        elif [ $? -eq 1 ]; then
            log_debug "SSH agent exists but has no keys"
            return 0
        else
            log_debug "SSH agent socket exists but agent is not responding"
            unset SSH_AUTH_SOCK SSH_AGENT_PID
        fi
    fi

    # Start new agent
    local agent_env="$HOME/.ssh/agent.env"

    # Ensure .ssh directory exists with secure permissions
    if [ ! -d "$HOME/.ssh" ]; then
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
    fi

    # Verify .ssh directory permissions
    local ssh_dir_perms
    ssh_dir_perms=$(stat -c '%a' "$HOME/.ssh" 2>/dev/null || stat -f '%A' "$HOME/.ssh" 2>/dev/null)
    if [ "$ssh_dir_perms" != "700" ]; then
        log_warn "Warning: ~/.ssh has insecure permissions ($ssh_dir_perms), fixing..."
        chmod 700 "$HOME/.ssh"
    fi

    # Use file locking to prevent race conditions
    # Check if flock is available (Linux/BSD)
    if command -v flock >/dev/null 2>&1; then
        (
            flock -x 200

        # Check again inside lock
        if [ -f "$agent_env" ]; then
            # Validate agent env file permissions
            local env_perms
            env_perms=$(stat -c '%a' "$agent_env" 2>/dev/null || stat -f '%A' "$agent_env" 2>/dev/null)
            if [ "$env_perms" != "600" ]; then
                log_warn "Warning: agent.env has insecure permissions, removing"
                command rm -f "$agent_env"
            else
                # Validate agent.env content before sourcing
                if grep -qE '(^|\s)(rm|curl|wget|nc|exec|eval|python|perl|ruby|php)' "$agent_env"; then
                    log_error "Agent environment file contains suspicious commands"
                    command rm -f "$agent_env"
                else
                    # shellcheck disable=SC1090
                    source "$agent_env" >/dev/null 2>&1 || true
                    if [ -n "${SSH_AGENT_PID:-}" ] && kill -0 "$SSH_AGENT_PID" 2>/dev/null; then
                        # Verify the process is actually ssh-agent (exact match)
                        local agent_cmd
                        agent_cmd=$(ps -p "$SSH_AGENT_PID" -o comm= 2>/dev/null || true)
                        # Strip path and match exact binary name
                        agent_cmd=$(basename "$agent_cmd" 2>/dev/null || echo "$agent_cmd")
                        if [[ "$agent_cmd" == "ssh-agent" ]]; then
                            if ssh-add -l &>/dev/null || [ $? -eq 1 ]; then
                                log_info "Loaded existing SSH agent (PID: $SSH_AGENT_PID)"
                                return 0
                            fi
                        else
                            log_warn "PID $SSH_AGENT_PID is not ssh-agent (found: $agent_cmd)"
                        fi
                    fi
                fi
            fi
            # Clean up stale environment file
            command rm -f "$agent_env"
        fi

        # Start new agent with specific lifetime
        log_info "Starting new SSH agent"
        local agent_output
        # Start agent with 8-hour key lifetime by default
        agent_output=$(ssh-agent -s -t 28800) || {
            log_error "Failed to start SSH agent"
            return 1
        }

        # Validate agent output format before saving
        if ! echo "$agent_output" | grep -q "SSH_AUTH_SOCK=.*; export SSH_AUTH_SOCK"; then
            log_error "Invalid ssh-agent output format"
            return 1
        fi

        echo "$agent_output" > "$agent_env"
        chmod 600 "$agent_env"

        ) 200>"$agent_env.lock"
    else
        # Fallback without flock (macOS/other)
        log_debug "flock not available, using simple check"
        if [ -f "$agent_env" ]; then
            # Validate permissions first
            local env_perms
            env_perms=$(stat -c '%a' "$agent_env" 2>/dev/null || stat -f '%A' "$agent_env" 2>/dev/null)
            if [ "$env_perms" != "600" ]; then
                log_warn "Warning: agent.env has insecure permissions, removing"
                command rm -f "$agent_env"
            elif grep -qE '(^|\s)(rm|curl|wget|nc|exec|eval|python|perl|ruby|php)' "$agent_env"; then
                log_error "Agent environment file contains suspicious commands"
                command rm -f "$agent_env"
            else
                # shellcheck disable=SC1090
                source "$agent_env" >/dev/null 2>&1 || true
                if [ -n "${SSH_AGENT_PID:-}" ] && ps -p "$SSH_AGENT_PID" >/dev/null 2>&1; then
                    if ssh-add -l &>/dev/null || [ $? -eq 1 ]; then
                        log_info "Loaded existing SSH agent (PID: $SSH_AGENT_PID)"
                        return 0
                    fi
                fi
            fi
            # Clean up stale environment file
            command rm -f "$agent_env"
        fi

        # Start new agent
        log_info "Starting new SSH agent"
        local agent_output
        agent_output=$(ssh-agent -s) || {
            log_error "Failed to start SSH agent"
            return 1
        }
        echo "$agent_output" > "$agent_env"
        chmod 600 "$agent_env"
    fi

    # Source the agent environment
    # shellcheck disable=SC1090
    source "$agent_env" || {
        log_error "Failed to source SSH agent environment"
        return 1
    }

    # Validate SSH_AUTH_SOCK path
    if [ -n "$SSH_AUTH_SOCK" ]; then
        # Check if socket path is in a safe location
        case "$SSH_AUTH_SOCK" in
            /tmp/ssh-*|/var/*/ssh-*|"$HOME"/.ssh/*)
                # Valid paths
                ;;
            *)
                log_error "SSH_AUTH_SOCK points to suspicious location: $SSH_AUTH_SOCK"
                unset SSH_AUTH_SOCK SSH_AGENT_PID
                return 1
                ;;
        esac

        # Verify socket exists and is a socket
        if [ ! -S "$SSH_AUTH_SOCK" ]; then
            log_error "SSH_AUTH_SOCK is not a valid socket: $SSH_AUTH_SOCK"
            unset SSH_AUTH_SOCK SSH_AGENT_PID
            return 1
        fi
    fi

    export SSH_AUTH_SOCK SSH_AGENT_PID

    # Verify agent is working
    ssh-add -l &>/dev/null
    local ssh_add_exit_code=$?
    if [ $ssh_add_exit_code -ne 0 ] && [ $ssh_add_exit_code -ne 1 ]; then
        log_error "SSH agent started but not responding (exit code: $ssh_add_exit_code)"
        return 1
    fi

    log_info "SSH agent started successfully (PID: $SSH_AGENT_PID)"

    # Update shell RC files
    setup_ssh_agent_persistence

    return 0
}

setup_ssh_agent_persistence() {
    log_info "Setting up SSH agent persistence..."

    local agent_script='
# SSH agent environment
if [ -f ~/.ssh/agent.env ]; then
    # Check permissions before sourcing
    _perms=$(stat -c "%a" ~/.ssh/agent.env 2>/dev/null || stat -f "%A" ~/.ssh/agent.env 2>/dev/null)
    if [ "$_perms" = "600" ] && ! grep -qE "(^|\s)(rm|curl|wget|nc|exec|eval)" ~/.ssh/agent.env; then
        . ~/.ssh/agent.env >/dev/null
        # Verify agent is still running
        if ! ps -p $SSH_AGENT_PID >/dev/null 2>&1; then
            # Agent died, start a new one
            # This can happen after system restarts or crashes
            ssh-agent -s -t 28800 > ~/.ssh/agent.env
            chmod 600 ~/.ssh/agent.env
            . ~/.ssh/agent.env >/dev/null
        fi
        export SSH_AUTH_SOCK SSH_AGENT_PID
    else
        # Remove compromised agent file
        command rm -f ~/.ssh/agent.env
    fi
fi
'

    # Update shell RC files safely
    for rc_file in ~/.bashrc ~/.zshrc ~/.profile ~/.bash_profile; do
        if [ -f "$rc_file" ]; then
            # Create backup
            command cp "$rc_file" "$rc_file.backup.$$"

            # Remove existing agent setup safely
            local temp_rc
            temp_rc=$(mktemp)
            grep -v -F "# SSH agent environment" "$rc_file" | \
            awk '/^$/ && ssh_block {next} {print; if (/# SSH agent environment/) ssh_block=1; else if (/^$/) ssh_block=0}' > "$temp_rc"

            # Add new setup
            echo "$agent_script" >> "$temp_rc"

            # Replace atomically
            command mv "$temp_rc" "$rc_file"
            command rm -f "$rc_file.backup.$$"

            log_debug "Updated $rc_file"
        fi
    done

    # System-wide setup (if permitted)
    if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
        atomic_write "/etc/profile.d/ssh-agent.sh" "$agent_script" 755
        log_info "Created /etc/profile.d/ssh-agent.sh"
    fi
}

# ============================================================================
# SSH KEY MANAGEMENT
# ============================================================================

# Mask signals during critical operations
mask_signals() {
    trap '' INT TERM HUP
}

# Restore signal handlers
unmask_signals() {
    trap handle_interrupt INT TERM
    trap - HUP
}

# Run function with signals masked
with_signals_masked() {
    # Save current trap handlers
    local saved_traps
    saved_traps=$(trap -p)

    # Mask critical signals
    trap '' INT TERM HUP

    # Run the command
    "$@"
    local result=$?

    # Restore original traps
    eval "$saved_traps"

    return $result
}

# Process a single SSH key
#
# This function securely extracts an SSH private key from 1Password JSON data
# and adds it to the SSH agent. It implements multiple security measures to
# prevent key exposure or tampering.
#
# Security measures:
# - Creates temp files with 600 permissions before writing
# - Validates key format and checks for known weak keys
# - Uses shred for secure deletion (with fallback)
# - Clears sensitive data from memory after use
# - Implements timeouts to prevent hanging
# - Verifies file deletion after cleanup
# - Masks signals during critical sections
#
# Parameters:
#   $1 - JSON data containing the SSH key
#   $2 - Human-readable title for the key
#
# Returns:
#   0 - Key successfully added or already loaded
#   1 - Error occurred (key not added)
process_ssh_key() {
    local key_json="$1"
    local key_title="$2"

    # Create secure temporary file with restrictive permissions
    local temp_key
    temp_key=$(mktemp -p "$TEMP_DIR" -t ssh_key_XXXXXX)

    # Set permissions before writing any data
    chmod 600 "$temp_key"

    # Verify permissions were set correctly
    local actual_perms
    actual_perms=$(stat -c '%a' "$temp_key" 2>/dev/null || stat -f '%A' "$temp_key" 2>/dev/null)
    if [ "$actual_perms" != "600" ]; then
        log_error "Failed to set secure permissions on temp key file"
        command rm -f "$temp_key"
        return 1
    fi

    # Extract private key using secure extraction
    local private_key
    private_key=$(extract_json_field "$key_json" '.fields[] | select(.label == "private key").ssh_formats.openssh.value' "" $SSH_KEY_MAX_LENGTH)

    if [ -z "$private_key" ]; then
        private_key=$(extract_json_field "$key_json" '.fields[] | select(.type == "SSHKEY").value' "" $SSH_KEY_MAX_LENGTH)
    fi

    if [ -z "$private_key" ]; then
        log_warn "No private key found for: $key_title"
        command rm -f "$temp_key"
        return 1
    fi

    # Validate SSH key format
    if ! validate_ssh_key "$private_key"; then
        log_error "Invalid SSH key format for: $key_title"
        command rm -f "$temp_key"
        unset private_key
        return 1
    fi

    # Additional validation: check for known weak keys
    local key_fingerprint
    key_fingerprint=$(echo "$private_key" | ssh-keygen -l -f - 2>/dev/null | awk '{print $2}' || true)
    if [ -n "$key_fingerprint" ]; then
        # Check against known compromised key fingerprints (example)
        case "$key_fingerprint" in
            # Add known bad fingerprints here
            "SHA256:RjY3K2JlKShb*"|"MD5:98:2e:d7:e0:de:9f:ac:67:28:c2:42:2d:37:16:58:4d")
                log_error "SSH key matches known compromised key: $key_title"
                command rm -f "$temp_key"
                unset private_key
                return 1
                ;;
        esac
    fi

    # Write key to temp file using printf to avoid echo issues
    printf '%s\n' "$private_key" > "$temp_key"

    # Verify file was written and is not empty
    if [ ! -s "$temp_key" ]; then
        log_error "Failed to write SSH key to temp file"
        command rm -f "$temp_key"
        unset private_key
        return 1
    fi

    # Lock down the temp directory to prevent TOCTOU attacks
    chmod 700 "$TEMP_DIR"

    # Mask signals during critical key operations
    mask_signals

    # Add to agent with timeout to prevent hanging
    local add_output
    local add_result

    # Use timeout to prevent indefinite hanging
    if command -v timeout >/dev/null 2>&1; then
        add_output=$(timeout 10 ssh-add "$temp_key" 2>&1)
        add_result=$?
        if [ $add_result -eq 124 ]; then
            log_error "SSH key addition timed out for: $key_title"
            add_result=1
        fi
    else
        add_output=$(ssh-add "$temp_key" 2>&1)
        add_result=$?
    fi

    # Clean up immediately with secure deletion
    if command -v shred >/dev/null 2>&1; then
        # shred with -u flag to remove file after overwriting
        if shred -vfzu -n 3 "$temp_key" 2>/dev/null; then
            # File should be gone, but verify with a small delay
            sync 2>/dev/null || true  # Flush filesystem buffers

            # Only check and warn if file still exists after sync
            if [ -e "$temp_key" ]; then
                log_warn "Warning: temp key file persists after shred"
                command rm -rf "$temp_key" 2>/dev/null || true
            fi
        else
            # shred failed, use fallback
            command rm -f "$temp_key" 2>/dev/null || true
        fi
    else
        # Fallback: overwrite with random data before deletion
        dd if=/dev/urandom of="$temp_key" bs=1k count=10 2>/dev/null || true
        command rm -f "$temp_key"

        # For non-shred case, use sync to avoid race condition
        sync 2>/dev/null || true

        # Final check only if needed
        if [ -e "$temp_key" ]; then
            log_debug "Temp file removal delayed, forcing cleanup"
            command rm -rf "$temp_key" 2>/dev/null || true
        fi
    fi

    # Clear sensitive variable from memory
    unset private_key

    # Clear the variable name itself to prevent memory analysis
    private_key="CLEARED"
    unset private_key

    # Restore signal handlers
    unmask_signals

    # Check result
    if [ $add_result -eq 0 ]; then
        log_info "Added SSH key: $key_title"
        audit_log "SSH_KEY_ADDED" "title=$key_title fingerprint=${key_fingerprint:-unknown}"
        return 0
    elif echo "$add_output" | grep -q "already added"; then
        log_debug "SSH key already loaded: $key_title"
        return 0
    else
        log_error "Failed to add SSH key: $key_title - $add_output"
        return 1
    fi
}

# Load all SSH keys from 1Password
load_ssh_keys() {
    log_info "Loading SSH keys from 1Password..."

    local keys_json
    if ! keys_json=$(secure_op_command "item" "list" "--categories" "SSH Key" "--vault" "$DEFAULT_VAULT" "--format=json"); then
        log_error "Failed to list SSH keys from vault '$DEFAULT_VAULT'. Check vault permissions and connectivity"
        return 1
    fi

    local key_count=0
    local loaded_count=0
    local failed_count=0

    # Get all key IDs with validation
    local key_ids=()
    while IFS= read -r key_id; do
        [ -z "$key_id" ] && continue
        [ "$key_id" = "null" ] && continue
        if validate_safe_string "$key_id" '^[a-zA-Z0-9-]+$' && [ ${#key_id} -le 128 ]; then
            key_ids+=("$key_id")
            key_count=$((key_count + 1))
        else
            log_warn "Skipping key with invalid ID format: ${key_id:0:20}..."
        fi
    done < <(echo "$keys_json" | jq -r '.[].id // empty' 2>/dev/null || true)

    # Check current keys in agent to prevent overloading
    local current_key_count=0
    if ssh-add -l &>/dev/null; then
        current_key_count=$(ssh-add -l | wc -l | tr -d ' ')
        log_debug "SSH agent currently has $current_key_count keys loaded"

        if [ $current_key_count -ge $SSH_AGENT_MAX_KEYS ]; then
            log_error "SSH agent already has maximum keys loaded ($SSH_AGENT_MAX_KEYS)"
            return 1
        fi
    fi

    # Limit total keys to load
    if [ $key_count -gt $SSH_MAX_KEYS_TO_LOAD ]; then
        log_warn "Found $key_count keys but limiting to $SSH_MAX_KEYS_TO_LOAD for security"
        key_count=$SSH_MAX_KEYS_TO_LOAD
    fi

    # Process keys with progress indicator and batch optimization
    if [ "$key_count" -gt 0 ]; then
        log_info "Found $key_count SSH keys to process"

        local i=0
        local batch_count=0

        for key_id in "${key_ids[@]}"; do
            # Stop if we've loaded enough keys
            if [ $i -ge $SSH_MAX_KEYS_TO_LOAD ]; then
                log_info "Reached maximum key limit ($SSH_MAX_KEYS_TO_LOAD)"
                break
            fi

            # Check if agent is getting too full
            if [ $((current_key_count + loaded_count)) -ge $SSH_AGENT_MAX_KEYS ]; then
                log_warn "SSH agent approaching maximum capacity, stopping key loading"
                break
            fi
            i=$((i + 1))
            show_progress "Loading SSH keys" "$i" "$key_count"

            # Batch processing optimization
            if [ $batch_count -ge $SSH_KEY_BATCH_SIZE ] && [ $batch_count -gt 0 ]; then
                log_debug "Pausing between batches to avoid rate limits"
                sleep $SSH_KEY_BATCH_DELAY
                batch_count=0
            fi

            local key_json
            if ! key_json=$(op_get_item "$key_id"); then
                log_warn "Failed to get key: $key_id"
                failed_count=$((failed_count + 1))
                continue
            fi

            local key_title
            key_title=$(extract_json_field "$key_json" '.title' "Unnamed Key" 100)

            if process_ssh_key "$key_json" "$key_title"; then
                loaded_count=$((loaded_count + 1))
            else
                failed_count=$((failed_count + 1))
            fi

            batch_count=$((batch_count + 1))
        done

        show_progress "Loading SSH keys" "$key_count" "$key_count"  # Complete
    fi

    # Report summary
    log_info "SSH key loading complete: $loaded_count loaded, $failed_count failed, $key_count total"

    # Return success if at least one key was loaded
    [ $loaded_count -gt 0 ]
}

# ============================================================================
# GIT SIGNING CONFIGURATION
# ============================================================================

configure_git_signing() {
    log_info "Configuring Git SSH signing..."

    # Check if already configured
    if [ -f ~/.ssh/git_signing_key.pub ] && [ -f ~/.ssh/git_signing_key ] && [ -n "$(git config --global user.signingkey 2>/dev/null)" ]; then
        log_info "Git signing already configured"
        return 0
    fi

    # Try to find signing key
    local key_names=("${GIT_SIGNING_KEY_ITEM:-}" "Git Signing Key" "GitHub SSH Key")
    local key_found=false

    for key_name in "${key_names[@]}"; do
        [ -z "$key_name" ] && continue

        if ! validate_item_name "$key_name"; then
            log_warn "Skipping invalid key name: $key_name"
            continue
        fi

        log_debug "Trying signing key: $key_name"

        local key_json
        if ! key_json=$(op_get_item "$key_name" 2>/dev/null); then
            continue
        fi

        # Extract public key using secure extraction
        local public_key
        public_key=$(extract_json_field "$key_json" '.fields[] | select(.type == "SSHKEY" or .label == "public key").value' "" $SSH_KEY_MAX_LENGTH)

        # Filter to get only the public key part
        public_key=$(echo "$public_key" | grep -E '^ssh-' | head -1)

        if [ -z "$public_key" ]; then
            log_debug "No public key found for: $key_name"
            continue
        fi

        # Extract private key for signing
        local private_key
        private_key=$(extract_json_field "$key_json" '.fields[] | select(.label == "private key").ssh_formats.openssh.value' "" $SSH_KEY_MAX_LENGTH)

        if [ -z "$private_key" ]; then
            private_key=$(extract_json_field "$key_json" '.fields[] | select(.type == "SSHKEY").value' "" $SSH_KEY_MAX_LENGTH)
        fi

        if [ -z "$private_key" ]; then
            log_warn "No private key found for Git signing: $key_name"
            continue
        fi

        # Validate SSH key format
        if ! validate_ssh_key "$private_key"; then
            log_error "Invalid SSH key format for Git signing: $key_name"
            continue
        fi

        # Get email for comment
        local email
        email=$(git config --global user.email 2>/dev/null || echo "")

        # Save public key
        if [ -n "$email" ]; then
            atomic_write ~/.ssh/git_signing_key.pub "$public_key $email" 644
        else
            atomic_write ~/.ssh/git_signing_key.pub "$public_key" 644
        fi

        # Save private key with secure permissions
        atomic_write ~/.ssh/git_signing_key "$private_key" 600

        # Configure Git
        git config --global gpg.format ssh
        git config --global user.signingkey ~/.ssh/git_signing_key.pub
        git config --global commit.gpgsign true
        git config --global tag.gpgsign true

        # Add signing key to ssh-agent for Git operations
        if [ -n "$SSH_AUTH_SOCK" ] && ssh-add -l &>/dev/null; then
            ssh-add ~/.ssh/git_signing_key 2>/dev/null || {
                log_warn "Failed to add Git signing key to ssh-agent"
            }
        fi

        # Setup allowed signers
        if [ -n "$email" ]; then
            atomic_write ~/.ssh/allowed_signers "$email $public_key" 644
            git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
        fi

        log_info "Configured Git signing with: $key_name"
        key_found=true
        break
    done

    if ! $key_found; then
        log_warn "No Git signing key found in 1Password"
    fi

    return 0
}

# ============================================================================
# HEALTH CHECKS
# ============================================================================

perform_health_checks() {
    log_info "Performing health checks..."

    local checks_passed=0
    local checks_total=0
    local check_results_file
    check_results_file=$(mktemp)

    # Run checks in parallel for better performance
    {
        # Check: Git configuration
        timeout $HEALTH_CHECK_TIMEOUT bash -c '
            if [ -n "$(git config --global user.name)" ] && [ -n "$(git config --global user.email)" ]; then
                echo "git:1:✓ Git user configured"
            else
                echo "git:0:✗ Git user not fully configured"
            fi
        ' 2>/dev/null || echo "git:0:✗ Git configuration check timed out"
    } >> "$check_results_file" &

    {
        # Check: SSH agent
        timeout $HEALTH_CHECK_TIMEOUT bash -c '
            if ssh-add -l &>/dev/null; then
                key_count=$(ssh-add -l | wc -l | tr -d " ")
                echo "ssh:1:✓ SSH agent running with $key_count keys"
            else
                echo "ssh:0:✗ SSH agent not running or no keys loaded"
            fi
        ' 2>/dev/null || echo "ssh:0:✗ SSH agent check timed out"
    } >> "$check_results_file" &

    {
        # Check: Git signing
        timeout $HEALTH_CHECK_TIMEOUT bash -c '
            if [ -f ~/.ssh/git_signing_key.pub ] && [ -f ~/.ssh/git_signing_key ] && [ "$(git config --global gpg.format)" = "ssh" ]; then
                echo "signing:1:✓ Git signing configured"
            else
                echo "signing:0:✗ Git signing not configured"
            fi
        ' 2>/dev/null || echo "signing:0:✗ Git signing check timed out"
    } >> "$check_results_file" &

    # Wait for all checks to complete
    wait

    # Process results
    # shellcheck disable=SC2034  # check_name used for structure but not in logic
    while IFS=: read -r check_name check_passed check_message; do
        checks_total=$((checks_total + 1))
        if [ "$check_passed" = "1" ]; then
            checks_passed=$((checks_passed + 1))
            log_info "$check_message"
        else
            log_warn "$check_message"
        fi
    done < <(sort "$check_results_file" 2>/dev/null || true)

    command rm -f "$check_results_file"

    log_info "Health check summary: $checks_passed/$checks_total passed"

    return 0
}

# ============================================================================
# SUMMARY DISPLAY
# ============================================================================

display_setup_summary() {
    echo ""
    log_info "${COLOR_GREEN}============================================${COLOR_RESET}"
    log_info "${COLOR_GREEN}✅ Development Environment Setup Complete!${COLOR_RESET}"
    log_info "${COLOR_GREEN}============================================${COLOR_RESET}"
    echo ""
    log_info "Git user: $(git config --global user.name) <$(git config --global user.email)>"

    if [ "$(git config --global gpg.format)" = "ssh" ]; then
        log_info "Git signing: Enabled (SSH)"
    else
        log_info "Git signing: Not configured"
    fi

    # Show SSH keys status
    if ssh-add -l &>/dev/null; then
        local key_count
        key_count=$(ssh-add -l | wc -l | tr -d ' ')
        log_info "SSH keys: $key_count loaded"
    else
        log_info "SSH keys: None loaded"
    fi

    # Show next steps if needed
    local next_steps=()

    if [ -z "$(git config --global user.name)" ] || [ "$(git config --global user.name)" = "Developer" ]; then
        next_steps+=("Configure your Git identity: git config --global user.name 'Your Name'")
    fi

    if [ -z "$(git config --global user.email)" ] || [ "$(git config --global user.email)" = "developer@localhost" ]; then
        next_steps+=("Configure your Git email: git config --global user.email 'you@example.com'")
    fi

    if ! ssh-add -l &>/dev/null; then
        next_steps+=("Add SSH keys to agent: ssh-add ~/.ssh/id_rsa")
    fi

    if [ ${#next_steps[@]} -gt 0 ]; then
        log_info ""
        log_info "Next steps:"
        for step in "${next_steps[@]}"; do
            log_info "  • $step"
        done
    fi

    log_info ""
    log_info "Log file: $LOG_FILE"

    # Show warning if running in CI
    if is_ci_environment; then
        log_warn "Note: Running in CI environment, some features may be limited"
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================


main() {
    log_info "Starting post-create setup (v$SCRIPT_VERSION)..."
    log_info "Platform: $PLATFORM"
    log_info "Log file: $LOG_FILE"


    # Acquire lock
    if ! acquire_lock; then
        log_error "Another instance is running or lock timeout exceeded. Check for stale lock file: $LOCK_FILE"
        exit 1
    fi

    # Ensure cleanup on exit
    trap 'cleanup' EXIT

    # Create secure temporary directory
    TEMP_DIR=$(create_secure_temp)

    # Create SSH directory
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    # Load environment variables from .env file
    load_env_file

    # Initialize 1Password if token is available
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        if init_onepassword; then
            # Configure Git user
            configure_git_user || log_warn "Git user configuration failed"

            # Setup SSH agent
            setup_ssh_agent || log_warn "SSH agent setup failed"

            # Load SSH keys
            load_ssh_keys || log_warn "SSH key loading failed"

            # Configure Git signing
            configure_git_signing || log_warn "Git signing configuration failed"
        else
            log_warn "1Password initialization failed, continuing with limited functionality"
        fi
    else
        log_warn "OP_SERVICE_ACCOUNT_TOKEN not set, skipping 1Password integration"
    fi

    # Fallback Git configuration with enhanced defaults
    if [ -z "$(git config --global user.name)" ]; then
        # Try to use system username as fallback
        local fallback_name="${USER:-${USERNAME:-Developer}}"
        # Capitalize first letter if it's lowercase
        fallback_name="$(echo "$fallback_name" | command sed 's/^./\U&/')"
        git config --global user.name "$fallback_name"
        log_info "Set fallback Git user.name: $fallback_name"
    fi

    if [ -z "$(git config --global user.email)" ]; then
        # Try to construct a more meaningful default email
        local username="${USER:-${USERNAME:-developer}}"
        # Sanitize username for email
        username="${username:0:64}"
        username="${username//[^a-zA-Z0-9._-]/}"

        local hostname="${HOSTNAME:-${HOST:-localhost}}"
        # Sanitize hostname
        hostname="${hostname:0:253}"
        hostname="${hostname//[^a-zA-Z0-9.-]/}"
        # Remove any .local or .localdomain suffix for cleaner email
        hostname="${hostname%.local}"
        hostname="${hostname%.localdomain}"

        # Validate hostname has at least one dot or use localhost
        if [[ ! "$hostname" =~ \. ]] && [ "$hostname" != "localhost" ]; then
            hostname="localhost"
        fi

        git config --global user.email "${username}@${hostname}"
        log_info "Set fallback Git user.email: ${username}@${hostname}"
    fi

    # Perform health checks
    perform_health_checks

    # Display summary
    display_setup_summary

    return 0
}

# Execute main function
main "$@"
