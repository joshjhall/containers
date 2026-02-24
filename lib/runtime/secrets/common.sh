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

# Guard against multiple inclusion
if [ "${_SECRETS_COMMON_LOADED:-}" = "true" ]; then
    return 0
fi
_SECRETS_COMMON_LOADED=true

# Source logging utilities with build/runtime path fallback, or define stubs
_secrets_source_logging() {
    if [ -f "/tmp/build-scripts/base/logging.sh" ]; then
        # shellcheck source=/dev/null
        source "/tmp/build-scripts/base/logging.sh"
    elif [ -f "/opt/container-runtime/base/logging.sh" ]; then
        # shellcheck source=/dev/null
        source "/opt/container-runtime/base/logging.sh"
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
