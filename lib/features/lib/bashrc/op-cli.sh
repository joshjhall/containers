# shellcheck disable=SC2155
# ----------------------------------------------------------------------------
# 1Password CLI Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Cache and config directories
export OP_CACHE_DIR="/cache/1password"
export OP_CONFIG_DIR="/cache/1password/config"

# Biometric unlock (when available)
export OP_BIOMETRIC_UNLOCK_ENABLED=true

# ----------------------------------------------------------------------------
# 1Password Aliases
# ----------------------------------------------------------------------------
# Common shortcuts
alias ops='op signin'
alias opl='op vault list'
alias opg='op item get'
alias opi='op inject'

# ----------------------------------------------------------------------------
# op-env - Load environment variables from 1Password
#
# ⚠️  SECURITY WARNING:
#   This function uses eval which can expose secrets in:
#   - Command history (if histappend is enabled)
#   - Process listings (ps aux shows full command)
#   - Debug logs (if set -x is enabled)
#
#   Consider using op-env-safe() instead for better security.
#
# Usage:
#   eval $(op-env <vault>/<item>)
#
# Example:
#   eval $(op-env Development/API-Keys)
# ----------------------------------------------------------------------------
op-env() {
    if [ -z "$1" ]; then
        echo "Usage: op-env <vault>/<item>" >&2
        return 1
    fi

    op item get "$1" --format json | jq -r '.fields[] | select(.purpose == "NOTES" or .type == "CONCEALED") | "export " + .label + "=" + (.value | @sh)'
}

# ----------------------------------------------------------------------------
# op-env-safe - Load environment variables from 1Password (RECOMMENDED)
#
# Safer alternative to op-env that exports variables directly without eval.
# Prevents credential exposure in command history and process listings.
#
# Usage:
#   op-env-safe <vault>/<item>
#
# Example:
#   op-env-safe Development/API-Keys
#   echo \$API_KEY  # Variable is now available
# ----------------------------------------------------------------------------
op-env-safe() {
    # Disable command echoing to prevent exposure in logs
    local old_x_state=$(set +o | command grep xtrace)
    set +x

    if [ -z "$1" ]; then
        echo "Usage: op-env-safe <vault>/<item>" >&2
        eval "$old_x_state"
        return 1
    fi

    local item="$1"
    local json_output

    # Fetch secrets from 1Password
    if ! json_output=$(op item get "$item" --format json 2>/dev/null); then
        echo "Failed to fetch secrets from 1Password: $item" >&2
        eval "$old_x_state"
        return 1
    fi

    # Parse and export variables safely using tab-separated output from jq
    local _found=false
    while IFS=$'\t' read -r _label _value; do
        [ -z "$_label" ] && continue
        export "$_label=$_value"
        _found=true
    done < <(echo "$json_output" | jq -r '.fields[] | select(.purpose == "NOTES" or .type == "CONCEALED") | [.label, .value] | @tsv' 2>/dev/null)

    if [ "$_found" = "false" ]; then
        echo "No environment variables found in 1Password item: $item" >&2
        eval "$old_x_state"
        return 1
    fi

    # Re-enable command echoing if it was on
    eval "$old_x_state"
}

# ----------------------------------------------------------------------------
# op-exec - Execute command with secrets from 1Password
#
# Uses op-env-safe internally to avoid credential exposure.
#
# Usage:
#   op-exec <vault>/<item> <command> [args...]
#
# Example:
#   op-exec Development/API-Keys npm run deploy
# ----------------------------------------------------------------------------
op-exec() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: op-exec <vault>/<item> <command> [args...]" >&2
        return 1
    fi

    local item="$1"
    shift

    # Use op-env-safe to load secrets securely
    op-env-safe "$item" || return 1
    "$@"
}

# ----------------------------------------------------------------------------
# Automatic Secret Loading from 1Password (OP_*_REF / OP_*_FILE_REF)
# ----------------------------------------------------------------------------
# Scans the environment for variables matching OP_<NAME>_REF and populates
# <NAME> from 1Password. Also handles OP_<NAME>_FILE_REF for file-based
# secrets (content written to /dev/shm, env var set to the file path).
# Requires OP_SERVICE_ACCOUNT_TOKEN to be set.
#
# Convention:
#   OP_<NAME>_REF=op://vault/item/field       →  exports <NAME>=<secret_value>
#   OP_<NAME>_FILE_REF=op://vault/item/file   →  writes to /dev/shm, exports <NAME>=<path>
#
# Examples:
#   OP_GITHUB_TOKEN_REF=op://Dev/GitHub-PAT/token   → GITHUB_TOKEN
#   OP_KAGI_API_KEY_REF=op://Dev/Kagi/api-key       → KAGI_API_KEY
#   OP_MY_SECRET_REF=op://Vault/Item/field           → MY_SECRET
#   OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF=op://Dev/GCP/sa-key.json
#       → GOOGLE_APPLICATION_CREDENTIALS=/dev/shm/google-application-credentials.json
#
# - Direct env var always wins (if <NAME> is already set, OP ref is skipped)
# - Fails silently if OP is unavailable or unauthenticated
# ----------------------------------------------------------------------------
_op_load_secrets() {
    # Skip if op not available or no service account token
    if ! command -v op >/dev/null 2>&1 || [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        return 0
    fi

    # Disable xtrace to prevent token exposure in logs
    local _old_xtrace
    _old_xtrace=$(set +o | command grep xtrace)
    set +x

    local _ref_var _target_var _ref_value _secret_value
    for _ref_var in $(compgen -v | command grep '^OP_.\+_REF$' | command grep -v '_FILE_REF$'); do
        _target_var="${_ref_var#OP_}"
        _target_var="${_target_var%_REF}"
        [ -z "$_target_var" ] && continue
        # Skip if target variable is already set
        [ -n "${!_target_var:-}" ] && continue
        _ref_value="${!_ref_var:-}"
        [ -z "$_ref_value" ] && continue
        if _secret_value=$(op read "$_ref_value" 2>/dev/null); then
            export "${_target_var}=${_secret_value}"
        fi
    done

    # FILE_REF loop: fetch content, write to /dev/shm, export file path
    local _file_name _uri_field _file_ext _file_path
    for _ref_var in $(compgen -v | command grep '^OP_.\+_FILE_REF$'); do
        _target_var="${_ref_var#OP_}"
        _target_var="${_target_var%_FILE_REF}"
        [ -z "$_target_var" ] && continue
        # Skip if target variable is already set
        [ -n "${!_target_var:-}" ] && continue
        _ref_value="${!_ref_var:-}"
        [ -z "$_ref_value" ] && continue
        if _secret_value=$(op read "$_ref_value" 2>/dev/null); then
            # Derive filename: lowercase target var with dashes
            _file_name=$(echo "$_target_var" | tr '[:upper:]_' '[:lower:]-')
            # Derive extension from the URI's last path segment
            _uri_field="${_ref_value##*/}"
            case "$_uri_field" in
                *.*) _file_ext=".${_uri_field##*.}" ;;
                *)   _file_ext="" ;;
            esac
            _file_path="/dev/shm/${_file_name}${_file_ext}"
            printf '%s' "$_secret_value" > "$_file_path"
            chmod 600 "$_file_path"
            export "${_target_var}=${_file_path}"
        fi
    done

    # Restore xtrace state
    eval "$_old_xtrace"
}

# Automatically load secrets on shell initialization
_op_load_secrets

# ----------------------------------------------------------------------------
# Smart Git Identity Resolution
# ----------------------------------------------------------------------------
# If GIT_USER_NAME wasn't resolved by _op_load_secrets (e.g., the referenced
# item is a 1Password Identity with separate first/last name fields instead of
# a single "full name" field), try combining first name + last name.
# Falls back to "Devcontainer" if nothing resolves.
_op_resolve_git_identity() {
    if ! command -v op >/dev/null 2>&1 || [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        return 0
    fi

    local _old_xtrace
    _old_xtrace=$(set +o | command grep xtrace)
    set +x

    # Resolve GIT_USER_NAME: try custom "full name" field, then first+last
    if [ -z "${GIT_USER_NAME:-}" ] && [ -n "${OP_GIT_USER_NAME_REF:-}" ]; then
        local _base_path="${OP_GIT_USER_NAME_REF%/*}"
        local _first _last
        _first=$(op read "${_base_path}/first name" 2>/dev/null) || true
        _last=$(op read "${_base_path}/last name" 2>/dev/null) || true
        if [ -n "${_first}" ] || [ -n "${_last}" ]; then
            local _full_name="${_first}${_first:+ }${_last}"
            export GIT_USER_NAME="$_full_name"
        fi
    fi

    # Apply defaults so git operations never fail
    if [ -z "${GIT_USER_NAME:-}" ]; then
        export GIT_USER_NAME="Devcontainer"
    fi
    if [ -z "${GIT_USER_EMAIL:-}" ]; then
        export GIT_USER_EMAIL="devcontainer@localhost"
    fi

    eval "$_old_xtrace"
}

_op_resolve_git_identity

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
