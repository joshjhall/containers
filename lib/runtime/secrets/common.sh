#!/bin/bash
# Common helpers for the secrets subsystem
#
# Description:
#   Shared logging bootstrap and utility functions used by all secret
#   provider integration scripts.  Source this file at the top of every
#   script in lib/runtime/secrets/ instead of duplicating the logging
#   fallback block.
#
# Provides:
#   log_info(), log_error(), log_warning()  - via logging.sh or fallback stubs
#   normalize_env_var_name <prefix> <label> - emit a valid uppercase env-var name
#   is_protected_env_var <name>             - return 0 if name is on the denylist
#   safe_export_secret <prefix> <label> <value> - normalize, check, export

# Guard against multiple inclusion
if [ "${_SECRETS_COMMON_LOADED:-}" = "true" ]; then
    return 0
fi
_SECRETS_COMMON_LOADED=true

# Source logging utilities from runtime path, or define stubs
_secrets_source_logging() {
    if [ -f "/opt/container-runtime/shared/logging.sh" ]; then
        # shellcheck source=/dev/null
        source "/opt/container-runtime/shared/logging.sh"
    else
        # Fallback logging functions
        log_info() { echo "[INFO] $*"; }
        log_error() { echo "[ERROR] $*" >&2; }
        log_warning() { echo "[WARNING] $*" >&2; }
    fi
}
_secrets_source_logging
unset -f _secrets_source_logging

# Normalize a label into a valid uppercase env-var name.
#   1. Prepend $prefix
#   2. Replace spaces and hyphens with underscores
#   3. Strip characters that are not alphanumeric or underscore
#   4. Convert to uppercase
#
# Usage: env_var=$(normalize_env_var_name "$prefix" "$field_label")
normalize_env_var_name() {
    local prefix="$1"
    local label="$2"
    local env_var="${prefix}${label// /_}"
    env_var="${env_var//-/_}"
    env_var="${env_var//[^a-zA-Z0-9_]/}"
    echo "${env_var^^}"
}

# Denylist of environment variable names that secret loaders must never
# overwrite.  A malicious vault entry named "PATH" or "LD_PRELOAD" could
# hijack process execution; this list prevents that.
declare -gA _PROTECTED_ENV_VARS=(
    # Process execution
    [PATH]=1 [LD_PRELOAD]=1 [LD_LIBRARY_PATH]=1 [LD_AUDIT]=1
    # Shell injection vectors
    [BASH_ENV]=1 [ENV]=1 [IFS]=1 [PROMPT_COMMAND]=1 [SHELLOPTS]=1 [BASHOPTS]=1
    # User identity
    [HOME]=1 [USER]=1 [SHELL]=1 [LOGNAME]=1 [USERNAME]=1
    # 1Password auth
    [OP_SERVICE_ACCOUNT_TOKEN]=1 [OP_CONNECT_TOKEN]=1 [OP_CONNECT_HOST]=1
    # AWS auth
    [AWS_ACCESS_KEY_ID]=1 [AWS_SECRET_ACCESS_KEY]=1 [AWS_SESSION_TOKEN]=1
    # Vault auth
    [VAULT_TOKEN]=1 [VAULT_ADDR]=1 [VAULT_NAMESPACE]=1
    # Azure auth
    [AZURE_CLIENT_SECRET]=1 [AZURE_CLIENT_ID]=1 [AZURE_TENANT_ID]=1
    # GCP auth
    [GOOGLE_APPLICATION_CREDENTIALS]=1
    # Container internals
    [ENTRYPOINT_ALREADY_RAN]=1 [CONTAINER_UID]=1 [RUNNING_AS_ROOT]=1
)

# Check whether an env-var name is on the protected denylist.
# Returns 0 (true → protected, do NOT export) or 1 (false → safe).
#
# Usage: if is_protected_env_var "$name"; then skip; fi
is_protected_env_var() {
    local name="$1"
    # Reject names starting with a digit (invalid bash identifier)
    [[ "$name" =~ ^[0-9] ]] && return 0
    # Reject names on the denylist
    [[ -n "${_PROTECTED_ENV_VARS[$name]+x}" ]]
}

# Normalize a label, check the denylist, and export in one step.
# Returns 0 on success, 1 if the name was blocked.
#
# Usage: safe_export_secret "$prefix" "$label" "$value" || continue
safe_export_secret() {
    local prefix="$1"
    local label="$2"
    local value="$3"
    local env_var
    env_var=$(normalize_env_var_name "$prefix" "$label")

    if is_protected_env_var "$env_var"; then
        log_warning "Skipping protected env var: $env_var (from label: $label)"
        return 1
    fi

    export "${env_var}=${value}"
    return 0
}

# URL-encode a string for safe use in query parameters.
# Uses jq's @uri filter (jq is a verified dependency in the Connect path).
url_encode() {
    jq -rn --arg s "$1" '$s | @uri'
}
