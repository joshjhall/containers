#!/bin/bash
# init-env.sh — Resolve .env.init into .devcontainer/.env for Docker Compose
#
# Host-side script that reads .env.init from the project root, resolves any
# OP_*_REF variables via the 1Password CLI, and writes the result to
# .devcontainer/.env where Docker Compose picks it up via env_file.
#
# Usage:
#   ./containers/host/init-env.sh [OPTIONS]
#
# Options:
#   --project-root PATH   Override auto-detected project root
#   --dry-run             Print output to stdout instead of writing file
#   --help                Show this help message
#
# Requirements:
#   - bash 3.2+ (macOS compatible)
#   - op CLI: only required if .env.init contains OP_*_REF lines
#   - .env.secrets: only required if OP_* refs exist and OP_SERVICE_ACCOUNT_TOKEN
#     is not already in the environment
#
# Flow:
#   1. Read .env.init from project root (exit 0 if missing — not an error)
#   2. For OP_*_REF=op://... lines, resolve via `op read` and derive target var
#   3. Write resolved output to .devcontainer/.env (chmod 600)
#   4. Container-side 05-cleanup-init-env.sh shreds this file on boot

set -euo pipefail

# ============================================================================
# Logging (self-contained — no dependency on bin/lib/common.sh)
# ============================================================================

_RED='\033[0;31m'
_GREEN='\033[0;32m'
_YELLOW='\033[1;33m'
_BLUE='\033[0;34m'
_NC='\033[0m'

log_info() { printf '%b[INFO]%b %s\n' "$_BLUE" "$_NC" "$*" >&2; }
log_success() { printf '%b[SUCCESS]%b %s\n' "$_GREEN" "$_NC" "$*" >&2; }
log_warning() { printf '%b[WARNING]%b %s\n' "$_YELLOW" "$_NC" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$_RED" "$_NC" "$*" >&2; }

# ============================================================================
# Path Detection
# ============================================================================

# Resolve the directory containing this script (follows symlinks)
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local dir=""
    while [ -L "$source" ]; do
        dir="$(command cd -P "$(command dirname "$source")" && command pwd)"
        source="$(command readlink "$source")"
        case "$source" in
            /*) ;;
            *) source="$dir/$source" ;;
        esac
    done
    command cd -P "$(command dirname "$source")" && command pwd
}

SCRIPT_DIR="$(get_script_dir)"
# containers/ root is parent of host/
CONTAINERS_ROOT="$(command cd "$SCRIPT_DIR/.." && command pwd)"

# ============================================================================
# CLI Argument Parsing
# ============================================================================

PROJECT_ROOT=""
DRY_RUN=false

usage() {
    command cat <<'USAGE'
Usage: init-env.sh [OPTIONS]

Resolve .env.init into .devcontainer/.env for Docker Compose.

Options:
  --project-root PATH   Override auto-detected project root
  --dry-run             Print output to stdout instead of writing file
  --help                Show this help message

The project root is auto-detected as the parent of the containers/ directory.
If .env.init does not exist at the project root, the script exits cleanly.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project-root)
            if [ $# -lt 2 ]; then
                log_error "--project-root requires a path argument"
                exit 1
            fi
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage >&2
            exit 1
            ;;
    esac
done

# Auto-detect project root (parent of containers/)
if [ -z "$PROJECT_ROOT" ]; then
    PROJECT_ROOT="$(command cd "$CONTAINERS_ROOT/.." && command pwd)"
fi

# ============================================================================
# Check for .env.init
# ============================================================================

ENV_INIT_FILE="$PROJECT_ROOT/.env.init"

if [ ! -f "$ENV_INIT_FILE" ]; then
    log_info "No .env.init found at $ENV_INIT_FILE — nothing to do."
    exit 0
fi

log_info "Processing $ENV_INIT_FILE"

# ============================================================================
# Scan for OP_*_REF lines to determine if op CLI is needed
# ============================================================================

NEED_OP=false
while IFS= read -r line || [ -n "$line" ]; do
    # Strip leading/trailing whitespace for detection
    stripped="$(printf '%s' "$line" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # Skip comments and blank lines
    case "$stripped" in
        "" | \#*) continue ;;
    esac
    # Check for OP_*_REF= pattern (but not OP_*_FILE_REF=)
    case "$stripped" in
        OP_*_FILE_REF=*) ;;
        OP_*_REF=*)
            NEED_OP=true
            break
            ;;
    esac
done <"$ENV_INIT_FILE"

# ============================================================================
# OP CLI setup (only if needed)
# ============================================================================

_LOADED_SA_TOKEN=false

if [ "$NEED_OP" = "true" ]; then
    if ! command -v op >/dev/null 2>&1; then
        log_error "op CLI is required to resolve OP_*_REF variables but was not found."
        log_error "Install: https://developer.1password.com/docs/cli/get-started/"
        exit 1
    fi

    # Load OP_SERVICE_ACCOUNT_TOKEN from .env.secrets if not already set
    if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        SECRETS_FILE="$PROJECT_ROOT/.env.secrets"
        if [ -f "$SECRETS_FILE" ]; then
            log_info "Loading OP_SERVICE_ACCOUNT_TOKEN from .env.secrets"
            # Source only OP_SERVICE_ACCOUNT_TOKEN to avoid polluting env
            while IFS= read -r sline || [ -n "$sline" ]; do
                stripped_s="$(printf '%s' "$sline" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                case "$stripped_s" in
                    "" | \#*) continue ;;
                    OP_SERVICE_ACCOUNT_TOKEN=*)
                        export OP_SERVICE_ACCOUNT_TOKEN="${stripped_s#OP_SERVICE_ACCOUNT_TOKEN=}"
                        _LOADED_SA_TOKEN=true
                        break
                        ;;
                esac
            done <"$SECRETS_FILE"
        fi

        if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
            log_error "OP_SERVICE_ACCOUNT_TOKEN is required to resolve OP_*_REF variables."
            log_error "Set it in the environment or in $PROJECT_ROOT/.env.secrets"
            exit 1
        fi
    fi
fi

# ============================================================================
# Parse .env.init and build output
# ============================================================================

OUTPUT=""
_errors=0

while IFS= read -r line || [ -n "$line" ]; do
    # Preserve blank lines and comments as-is
    stripped="$(printf '%s' "$line" | command sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$stripped" in
        "" | \#*)
            OUTPUT="$OUTPUT$line
"
            continue
            ;;
    esac

    # Extract key=value
    key="${stripped%%=*}"
    value="${stripped#*=}"

    # Handle OP_*_FILE_REF — warn and skip
    case "$key" in
        OP_*_FILE_REF)
            log_warning "Skipping $key — FILE_REF is not supported in env files (use container-side resolution)"
            continue
            ;;
    esac

    # Handle OP_*_REF — resolve via op read
    case "$key" in
        OP_*_REF)
            # Derive target var name: strip OP_ prefix and _REF suffix
            target_var="${key#OP_}"
            target_var="${target_var%_REF}"

            if [ -z "$target_var" ]; then
                log_warning "Skipping $key — could not derive target variable name"
                continue
            fi

            log_info "Resolving $key -> $target_var"

            if resolved="$(command op read "$value" 2>&1)"; then
                OUTPUT="$OUTPUT$target_var=$resolved
"
            else
                log_error "Failed to resolve $key: $resolved"
                _errors=$((_errors + 1))
            fi
            continue
            ;;
    esac

    # Everything else — pass through as-is
    OUTPUT="$OUTPUT$line
"
done <"$ENV_INIT_FILE"

if [ "$_errors" -gt 0 ]; then
    log_warning "$_errors secret(s) failed to resolve — continuing with partial output"
fi

# ============================================================================
# Output
# ============================================================================

if [ "$DRY_RUN" = "true" ]; then
    printf '%s' "$OUTPUT"
    log_info "(dry-run) Output printed to stdout — no file written."
else
    DEVCONTAINER_DIR="$PROJECT_ROOT/.devcontainer"
    OUTPUT_FILE="$DEVCONTAINER_DIR/.env"

    # Create .devcontainer/ if missing
    if [ ! -d "$DEVCONTAINER_DIR" ]; then
        command mkdir -p "$DEVCONTAINER_DIR"
        log_info "Created $DEVCONTAINER_DIR"
    fi

    # Backup existing .env file with numbered backups
    if [ -f "$OUTPUT_FILE" ]; then
        backup="$OUTPUT_FILE.bak"
        if [ -f "$backup" ]; then
            # Find next available backup number
            n=2
            while [ -f "$OUTPUT_FILE.bak-$n" ]; do
                n=$((n + 1))
            done
            backup="$OUTPUT_FILE.bak-$n"
        fi
        command cp "$OUTPUT_FILE" "$backup"
        log_info "Backed up existing .env to $(command basename "$backup")"
    fi

    # Write output with restricted permissions
    printf '%s' "$OUTPUT" >"$OUTPUT_FILE"
    command chmod 600 "$OUTPUT_FILE"

    log_success "Wrote $OUTPUT_FILE ($(printf '%s' "$OUTPUT" | command grep -c '^[^#]' || true) active lines)"
fi

# ============================================================================
# Cleanup
# ============================================================================

if [ "$_LOADED_SA_TOKEN" = "true" ]; then
    unset OP_SERVICE_ACCOUNT_TOKEN
fi

exit 0
