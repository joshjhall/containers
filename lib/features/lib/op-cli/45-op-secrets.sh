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

# Source .env.secrets if available (runtime secrets not in docker-compose env_file)
# Search order: explicit path > $HOME > $PWD > /workspace subdirectories
_secrets_file=""
if [ -n "${ENV_SECRETS_FILE:-}" ] && [ -f "${ENV_SECRETS_FILE}" ]; then
    _secrets_file="${ENV_SECRETS_FILE}"
elif [ -n "${HOME:-}" ] && [ -f "${HOME}/.env.secrets" ]; then
    _secrets_file="${HOME}/.env.secrets"
elif [ -f "${PWD}/.env.secrets" ]; then
    _secrets_file="${PWD}/.env.secrets"
elif [ -d "/workspace" ]; then
    # During entrypoint startup, $PWD may not be the project directory.
    # Search /workspace subdirectories as a fallback.
    for _ws_dir in /workspace/*/; do
        if [ -f "${_ws_dir}.env.secrets" ]; then
            _secrets_file="${_ws_dir}.env.secrets"
            break
        fi
    done
fi
if [ -n "$_secrets_file" ]; then
    set -a
    . "$_secrets_file"
    set +a
fi
unset _secrets_file

# Skip if no service account token configured
[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && exit 0

# Disable xtrace to prevent secret exposure in logs
_xtrace_was_on=false
[[ $- == *x* ]] && _xtrace_was_on=true
set +x

# Fetch all secrets in parallel using temp files on /dev/shm (RAM-backed).
# Each op read runs as a background job; we wait for all to finish, then
# read results back. This turns N sequential network round-trips into one
# parallel batch (~0.8s total instead of N × 0.8s).

_op_tmp_dir=$(mktemp -d /dev/shm/op-fetch.XXXXXX)
chmod 700 "$_op_tmp_dir"

# Launch parallel fetches for OP_*_REF (non-FILE) variables
for _ref_var in $(compgen -v | command grep '^OP_.\+_REF$' | command grep -v '_FILE_REF$'); do
    _target_var="${_ref_var#OP_}"
    _target_var="${_target_var%_REF}"
    [ -z "$_target_var" ] && continue
    [ -n "${!_target_var:-}" ] && continue
    _ref_value="${!_ref_var:-}"
    [ -z "$_ref_value" ] && continue
    # Background: fetch secret and write to temp file
    ( op read "$_ref_value" 2>/dev/null > "${_op_tmp_dir}/ref_${_target_var}" ) &
done

# Launch parallel fetches for OP_*_FILE_REF variables
for _ref_var in $(compgen -v | command grep '^OP_.\+_FILE_REF$'); do
    _target_var="${_ref_var#OP_}"
    _target_var="${_target_var%_FILE_REF}"
    [ -z "$_target_var" ] && continue
    [ -n "${!_target_var:-}" ] && continue
    _ref_value="${!_ref_var:-}"
    [ -z "$_ref_value" ] && continue
    ( op read "$_ref_value" 2>/dev/null > "${_op_tmp_dir}/fileref_${_target_var}_${_ref_value##*/}" ) &
done

# Launch parallel git identity fetch if needed
if [ -z "${GIT_USER_NAME:-}" ] && [ -n "${OP_GIT_USER_NAME_REF:-}" ]; then
    _base_path="${OP_GIT_USER_NAME_REF%/*}"
    ( op read "${_base_path}/first name" 2>/dev/null > "${_op_tmp_dir}/git_first" ) &
    ( op read "${_base_path}/last name" 2>/dev/null > "${_op_tmp_dir}/git_last" ) &
fi

# Wait for ALL parallel fetches to complete
wait

# Collect results: OP_*_REF → export as env vars
for _ref_var in $(compgen -v | command grep '^OP_.\+_REF$' | command grep -v '_FILE_REF$'); do
    _target_var="${_ref_var#OP_}"
    _target_var="${_target_var%_REF}"
    [ -z "$_target_var" ] && continue
    [ -n "${!_target_var:-}" ] && continue
    _result_file="${_op_tmp_dir}/ref_${_target_var}"
    if [ -s "$_result_file" ]; then
        export "${_target_var}=$(command cat "$_result_file")"
    fi
done

# Collect results: OP_*_FILE_REF → write to /dev/shm, export file path
for _ref_var in $(compgen -v | command grep '^OP_.\+_FILE_REF$'); do
    _target_var="${_ref_var#OP_}"
    _target_var="${_target_var%_FILE_REF}"
    [ -z "$_target_var" ] && continue
    [ -n "${!_target_var:-}" ] && continue
    _ref_value="${!_ref_var:-}"
    [ -z "$_ref_value" ] && continue
    _result_file="${_op_tmp_dir}/fileref_${_target_var}_${_ref_value##*/}"
    if [ -s "$_result_file" ]; then
        _file_name=$(echo "$_target_var" | command tr '[:upper:]_' '[:lower:]-')
        _uri_field="${_ref_value##*/}"
        case "$_uri_field" in
            *.*) _file_ext=".${_uri_field##*.}" ;;
            *)   _file_ext="" ;;
        esac
        _file_path="/dev/shm/${_file_name}${_file_ext}"
        command cat "$_result_file" > "$_file_path"
        chmod 600 "$_file_path"
        export "${_target_var}=${_file_path}"
    fi
done

# Smart Git Identity Resolution: if GIT_USER_NAME wasn't resolved (e.g.,
# Identity item with separate first/last fields), try combining them.
if [ -z "${GIT_USER_NAME:-}" ] && [ -n "${OP_GIT_USER_NAME_REF:-}" ]; then
    _first="" _last=""
    [ -s "${_op_tmp_dir}/git_first" ] && _first=$(command cat "${_op_tmp_dir}/git_first")
    [ -s "${_op_tmp_dir}/git_last" ] && _last=$(command cat "${_op_tmp_dir}/git_last")
    if [ -n "${_first}" ] || [ -n "${_last}" ]; then
        export GIT_USER_NAME="${_first}${_first:+ }${_last}"
    fi
fi

# Clean up temp files
rm -rf "$_op_tmp_dir"

# Apply defaults so git operations never fail
[ -z "${GIT_USER_NAME:-}" ] && export GIT_USER_NAME="Devcontainer"
[ -z "${GIT_USER_EMAIL:-}" ] && export GIT_USER_EMAIL="devcontainer@localhost"

# Write secrets cache for interactive shells
_cache_file="/dev/shm/op-secrets-cache"
_cache_tmp="${_cache_file}.tmp.$$"
{
    for _ref_var in $(compgen -v | command grep '^OP_.\+_REF$' | command grep -v '_FILE_REF$'); do
        _target_var="${_ref_var#OP_}"
        _target_var="${_target_var%_REF}"
        [ -z "$_target_var" ] && continue
        [ -z "${!_target_var:-}" ] && continue
        printf 'export %s=%q\n' "$_target_var" "${!_target_var}"
    done
    for _ref_var in $(compgen -v | command grep '^OP_.\+_FILE_REF$'); do
        _target_var="${_ref_var#OP_}"
        _target_var="${_target_var%_FILE_REF}"
        [ -z "$_target_var" ] && continue
        [ -z "${!_target_var:-}" ] && continue
        printf 'export %s=%q\n' "$_target_var" "${!_target_var}"
    done
    printf 'export GIT_USER_NAME=%q\n' "${GIT_USER_NAME:-Devcontainer}"
    printf 'export GIT_USER_EMAIL=%q\n' "${GIT_USER_EMAIL:-devcontainer@localhost}"
} > "$_cache_tmp"
chmod 600 "$_cache_tmp"
mv "$_cache_tmp" "$_cache_file"
unset _cache_file _cache_tmp

# Restore xtrace state
if [ "$_xtrace_was_on" = true ]; then set -x; fi
unset _xtrace_was_on

exit 0
