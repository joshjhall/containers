#!/bin/bash
# Validate Build Arguments
#
# Description:
#   Validates Docker build arguments against the JSON schema and checks
#   for common configuration errors (e.g., dev tools without base language).
#
# Usage:
#   ./bin/validate-build-args.sh [--json-file FILE] [--help]
#
# Options:
#   --json-file FILE    Validate build args from JSON file
#   --env-file FILE     Validate build args from environment file
#   --help, -h          Show this help message
#
# Examples:
#   # Validate from JSON file
#   ./bin/validate-build-args.sh --json-file build-config.json
#
#   # Validate from environment file
#   ./bin/validate-build-args.sh --env-file .env
#
#   # Validate current environment
#   export INCLUDE_PYTHON=true
#   export INCLUDE_PYTHON_DEV=true
#   ./bin/validate-build-args.sh
#
# Exit Codes:
#   0 - All validations passed
#   1 - Validation errors found
#   2 - Invalid usage or missing dependencies

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # May be used in future enhancements
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0

# Print usage
show_help() {
    command head -n 30 "$0" | command grep "^#" | command sed 's/^# \?//'
    exit 0
}

# Print error message
error() {
    echo -e "${RED}ERROR:${NC} $*" >&2
    ((ERRORS++))
}

# Print warning message
warn() {
    echo -e "${YELLOW}WARNING:${NC} $*" >&2
    ((WARNINGS++))
}

# Print success message
success() {
    echo -e "${GREEN}✓${NC} $*"
}

# Print info message
info() {
    echo "$*"
}

# Validate version format
validate_version() {
    local var_name="$1"
    local version="$2"
    local pattern="$3"

    if [ -z "$version" ]; then
        return 0  # Empty is OK (will use default)
    fi

    if ! [[ "$version" =~ $pattern ]]; then
        error "${var_name}: Invalid format '${version}'"
        error "  Expected pattern: ${pattern}"
        return 1
    fi

    return 0
}

# Validate boolean value
validate_boolean() {
    local var_name="$1"
    local value="$2"

    if [ -z "$value" ]; then
        return 0  # Empty is OK (will use default)
    fi

    if [[ "$value" != "true" && "$value" != "false" ]]; then
        error "${var_name}: Must be 'true' or 'false', got '${value}'"
        return 1
    fi

    return 0
}

# Check feature dependencies
check_dependencies() {
    local base_feature="$1"
    local dev_feature="$2"
    local base_var="INCLUDE_${base_feature}"
    local dev_var="INCLUDE_${dev_feature}_DEV"

    local base_value="${!base_var:-false}"
    local dev_value="${!dev_var:-false}"

    if [[ "$dev_value" == "true" && "$base_value" != "true" ]]; then
        error "${dev_var}=true requires ${base_var}=true"
        return 1
    fi

    return 0
}

# Validate USERNAME format
validate_username() {
    local username="${USERNAME:-developer}"

    if ! [[ "$username" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        error "USERNAME: Invalid format '${username}'"
        error "  Must start with lowercase letter, max 32 chars, only lowercase, digits, _ and -"
        return 1
    fi

    return 0
}

# Validate UID/GID
validate_uid_gid() {
    local uid="${USER_UID:-1000}"
    local gid="${USER_GID:-1000}"

    if ! [[ "$uid" =~ ^[0-9]+$ ]] || [ "$uid" -lt 1000 ] || [ "$uid" -gt 60000 ]; then
        error "USER_UID: Must be a number between 1000 and 60000, got '${uid}'"
        return 1
    fi

    if ! [[ "$gid" =~ ^[0-9]+$ ]] || [ "$gid" -lt 1000 ] || [ "$gid" -gt 60000 ]; then
        error "USER_GID: Must be a number between 1000 and 60000, got '${gid}'"
        return 1
    fi

    return 0
}

# Check for Cloudflare + Node.js dependency
check_cloudflare_dependency() {
    local cloudflare="${INCLUDE_CLOUDFLARE:-false}"
    local node="${INCLUDE_NODE:-false}"

    if [[ "$cloudflare" == "true" && "$node" != "true" ]]; then
        error "INCLUDE_CLOUDFLARE=true requires INCLUDE_NODE=true (Wrangler is an npm package)"
        return 1
    fi

    return 0
}

# Main validation function
validate_build_args() {
    info "Validating build arguments..."
    info ""

    # Base configuration
    validate_username
    validate_uid_gid
    validate_boolean "ENABLE_PASSWORDLESS_SUDO" "${ENABLE_PASSWORDLESS_SUDO:-}"

    # Python
    validate_boolean "INCLUDE_PYTHON" "${INCLUDE_PYTHON:-}"
    validate_boolean "INCLUDE_PYTHON_DEV" "${INCLUDE_PYTHON_DEV:-}"
    validate_version "PYTHON_VERSION" "${PYTHON_VERSION:-}" "^[0-9]+\.[0-9]+\.[0-9]+$"
    check_dependencies "PYTHON" "PYTHON"

    # Node.js
    validate_boolean "INCLUDE_NODE" "${INCLUDE_NODE:-}"
    validate_boolean "INCLUDE_NODE_DEV" "${INCLUDE_NODE_DEV:-}"
    validate_version "NODE_VERSION" "${NODE_VERSION:-}" "^[0-9]+(\.[0-9]+(\.[0-9]+)?)?$"
    check_dependencies "NODE" "NODE"

    # Rust
    validate_boolean "INCLUDE_RUST" "${INCLUDE_RUST:-}"
    validate_boolean "INCLUDE_RUST_DEV" "${INCLUDE_RUST_DEV:-}"
    validate_version "RUST_VERSION" "${RUST_VERSION:-}" "^[0-9]+\.[0-9]+\.[0-9]+$"
    check_dependencies "RUST" "RUST"

    # Go
    validate_boolean "INCLUDE_GOLANG" "${INCLUDE_GOLANG:-}"
    validate_boolean "INCLUDE_GOLANG_DEV" "${INCLUDE_GOLANG_DEV:-}"
    validate_version "GO_VERSION" "${GO_VERSION:-}" "^[0-9]+\.[0-9]+(\.[0-9]+)?$"
    check_dependencies "GOLANG" "GOLANG"

    # Ruby
    validate_boolean "INCLUDE_RUBY" "${INCLUDE_RUBY:-}"
    validate_boolean "INCLUDE_RUBY_DEV" "${INCLUDE_RUBY_DEV:-}"
    validate_version "RUBY_VERSION" "${RUBY_VERSION:-}" "^[0-9]+\.[0-9]+\.[0-9]+$"
    check_dependencies "RUBY" "RUBY"

    # Java
    validate_boolean "INCLUDE_JAVA" "${INCLUDE_JAVA:-}"
    validate_boolean "INCLUDE_JAVA_DEV" "${INCLUDE_JAVA_DEV:-}"
    validate_version "JAVA_VERSION" "${JAVA_VERSION:-}" "^[0-9]+(\.[0-9]+(\.[0-9]+)?)?$"
    check_dependencies "JAVA" "JAVA"

    # R
    validate_boolean "INCLUDE_R" "${INCLUDE_R:-}"
    validate_boolean "INCLUDE_R_DEV" "${INCLUDE_R_DEV:-}"
    validate_version "R_VERSION" "${R_VERSION:-}" "^[0-9]+\.[0-9]+\.[0-9]+$"
    check_dependencies "R" "R"

    # Mojo
    validate_boolean "INCLUDE_MOJO" "${INCLUDE_MOJO:-}"
    validate_boolean "INCLUDE_MOJO_DEV" "${INCLUDE_MOJO_DEV:-}"
    check_dependencies "MOJO" "MOJO"

    # Tools
    validate_boolean "INCLUDE_DEV_TOOLS" "${INCLUDE_DEV_TOOLS:-}"
    validate_boolean "INCLUDE_DOCKER" "${INCLUDE_DOCKER:-}"
    validate_boolean "INCLUDE_OP_CLI" "${INCLUDE_OP_CLI:-}"
    validate_boolean "INCLUDE_KUBERNETES" "${INCLUDE_KUBERNETES:-}"
    validate_boolean "INCLUDE_TERRAFORM" "${INCLUDE_TERRAFORM:-}"
    validate_boolean "INCLUDE_AWS" "${INCLUDE_AWS:-}"
    validate_boolean "INCLUDE_GCLOUD" "${INCLUDE_GCLOUD:-}"
    validate_boolean "INCLUDE_CLOUDFLARE" "${INCLUDE_CLOUDFLARE:-}"
    validate_boolean "INCLUDE_POSTGRES_CLIENT" "${INCLUDE_POSTGRES_CLIENT:-}"
    validate_boolean "INCLUDE_REDIS_CLIENT" "${INCLUDE_REDIS_CLIENT:-}"
    validate_boolean "INCLUDE_SQLITE_CLIENT" "${INCLUDE_SQLITE_CLIENT:-}"
    validate_boolean "INCLUDE_OLLAMA" "${INCLUDE_OLLAMA:-}"

    # Special dependency checks
    check_cloudflare_dependency

    # Production warnings
    if [[ "${ENABLE_PASSWORDLESS_SUDO:-true}" == "true" ]]; then
        warn "ENABLE_PASSWORDLESS_SUDO=true is NOT recommended for production"
    fi

    # Report results
    info ""
    info "Validation complete:"
    if [ $ERRORS -eq 0 ]; then
        success "No errors found"
    else
        error "$ERRORS error(s) found"
    fi

    if [ $WARNINGS -gt 0 ]; then
        warn "$WARNINGS warning(s) found"
    fi

    return $ERRORS
}

# Load from environment file
load_env_file() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        error "Environment file not found: $env_file"
        exit 2
    fi

    info "Loading environment from: $env_file"

    # Source the file in a subshell to avoid polluting current environment
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

# Parse arguments
main() {
    local json_file=""
    local env_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json-file)
                json_file="$2"
                shift 2
                ;;
            --env-file)
                env_file="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                ;;
            *)
                error "Unknown option: $1"
                show_help
                ;;
        esac
    done

    # Load from file if specified
    if [ -n "$env_file" ]; then
        load_env_file "$env_file"
    fi

    if [ -n "$json_file" ]; then
        error "JSON file validation not yet implemented"
        error "Use --env-file instead or set environment variables"
        exit 2
    fi

    # Run validation
    validate_build_args

    # Exit with appropriate code
    if [ $ERRORS -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

main "$@"
