#!/bin/bash
# Load secrets from 1Password on container startup (OP_*_REF convention)
#
# This script runs on every container startup (not just first startup) to ensure
# secrets are available for background processes and non-interactive shells.
#
# Convention:
#   OP_<NAME>_REF=op://vault/item/field       →  exports <NAME>=<secret_value>
#   OP_<NAME>_FILE_REF=op://vault/item/file   →  writes to /dev/shm, exports <NAME>=<path>
#
# Environment Variables:
#   OP_SERVICE_ACCOUNT_TOKEN  - 1Password service account token (required)
#   OP_<NAME>_REF             - 1Password ref for any string secret
#   OP_<NAME>_FILE_REF        - 1Password ref for file secrets (written to /dev/shm)
#
# Examples:
#   OP_GITHUB_TOKEN_REF=op://Dev/GitHub-PAT/token   → GITHUB_TOKEN
#   OP_KAGI_API_KEY_REF=op://Dev/Kagi/api-key       → KAGI_API_KEY
#   OP_GOOGLE_APPLICATION_CREDENTIALS_FILE_REF=op://Dev/GCP/sa-key.json
#       → writes to /dev/shm/google-application-credentials.json
#       → GOOGLE_APPLICATION_CREDENTIALS=/dev/shm/google-application-credentials.json
#
set +e  # Don't exit on errors

# Skip if op not available
command -v op >/dev/null 2>&1 || exit 0

# Skip if no service account token configured
[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && exit 0

# Disable xtrace to prevent secret exposure in logs
_old_xtrace=$(set +o | grep xtrace)
set +x

for _ref_var in $(compgen -v | grep '^OP_.\+_REF$' | grep -v '_FILE_REF$'); do
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
for _ref_var in $(compgen -v | grep '^OP_.\+_FILE_REF$'); do
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

# Smart Git Identity Resolution: if GIT_USER_NAME wasn't resolved (e.g.,
# Identity item with separate first/last fields), try combining them.
if [ -z "${GIT_USER_NAME:-}" ] && [ -n "${OP_GIT_USER_NAME_REF:-}" ]; then
    _base_path="${OP_GIT_USER_NAME_REF%/*}"
    _first=$(op read "${_base_path}/first name" 2>/dev/null) || true
    _last=$(op read "${_base_path}/last name" 2>/dev/null) || true
    if [ -n "${_first}" ] || [ -n "${_last}" ]; then
        export GIT_USER_NAME="${_first}${_first:+ }${_last}"
    fi
fi

# Apply defaults so git operations never fail
[ -z "${GIT_USER_NAME:-}" ] && export GIT_USER_NAME="Devcontainer"
[ -z "${GIT_USER_EMAIL:-}" ] && export GIT_USER_EMAIL="devcontainer@localhost"

# Restore xtrace state
eval "$_old_xtrace"

exit 0
