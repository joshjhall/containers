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
set +e # Don't exit on errors

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

# Persistent secret cache — resolved secrets are NEVER written to disk.
# Preference order:
#   1. $OP_SECRET_CACHE_DIR (default /cache/1password/secrets), only if it is
#      tmpfs-backed. This is the intended production configuration: a
#      tmpfs-backed docker volume that survives `docker restart` so cached
#      secrets reduce `op read` pressure across container restarts without
#      ever touching persistent storage. See docs/claude-code/secrets-and-setup.md
#      for the compose snippet.
#   2. $OP_SECRET_CACHE_FALLBACK_DIR (default /dev/shm/op-secrets-persistent) as
#      a degraded fallback — still tmpfs, so secrets stay off disk, but /dev/shm
#      is cleared on container restart so the rate-throttle benefit is lost.
#      A one-shot warning is emitted to stderr in this mode.
#   3. No cache at all — every `op read` hits upstream. Concurrency semaphore
#      and retry/backoff still apply.
_op_secret_cache_dir=""
_op_cache_requested="${OP_SECRET_CACHE_DIR:-/cache/1password/secrets}"
_op_cache_fallback="${OP_SECRET_CACHE_FALLBACK_DIR:-/dev/shm/op-secrets-persistent}"
_op_cache_primary_fs=""
if mkdir -p "$_op_cache_requested" 2>/dev/null && [ -w "$_op_cache_requested" ]; then
    _op_cache_primary_fs=$(command stat -f -c '%T' "$_op_cache_requested" 2>/dev/null)
    case "$_op_cache_primary_fs" in
        tmpfs | ramfs)
            _op_secret_cache_dir="$_op_cache_requested"
            chmod 700 "$_op_secret_cache_dir" 2>/dev/null || true
            ;;
    esac
fi
if [ -z "$_op_secret_cache_dir" ] &&
    [ "$_op_cache_requested" != "$_op_cache_fallback" ] &&
    mkdir -p "$_op_cache_fallback" 2>/dev/null &&
    [ -w "$_op_cache_fallback" ]; then
    _op_secret_cache_dir="$_op_cache_fallback"
    chmod 700 "$_op_secret_cache_dir" 2>/dev/null || true
    command cat >&2 <<WARN
op-secrets: ${_op_cache_requested} is not tmpfs-backed (fs=${_op_cache_primary_fs:-unknown}).
            Resolved secrets will not be written to disk; cache has been
            downgraded to ${_op_cache_fallback} which is cleared on container
            restart. To keep the cache across restarts without writing secrets
            to disk, mount ${_op_cache_requested} as a tmpfs-backed docker
            volume. See docs/claude-code/secrets-and-setup.md.
WARN
fi
unset _op_cache_requested _op_cache_fallback _op_cache_primary_fs

# Run `op read` with throttle-aware retry + exponential backoff.
# Emits the resolved secret on stdout (preserves newlines). Returns non-zero if
# all attempts fail. Only retries when stderr matches a throttle signature;
# other failures (missing item, auth error, bad ref) bail immediately so we
# don't stall on non-transient problems.
_op_read_with_backoff() {
    local ref="$1"
    local max_attempts="${OP_READ_MAX_ATTEMPTS:-3}"
    local delay="${OP_READ_RETRY_DELAY:-1}"
    local attempt=0
    local stderr_file
    stderr_file=$(mktemp /dev/shm/op-stderr.XXXXXX 2>/dev/null) ||
        stderr_file=$(mktemp 2>/dev/null) ||
        stderr_file=""
    if [ -z "$stderr_file" ]; then
        # No tmpfile available — we can't inspect stderr to detect throttling,
        # so do a single attempt with no retry.
        op read "$ref" 2>/dev/null
        return $?
    fi
    while [ "$attempt" -lt "$max_attempts" ]; do
        if op read "$ref" 2>"$stderr_file"; then
            command rm -f "$stderr_file"
            return 0
        fi
        if command grep -iqE 'rate.?limit|too many|429|throttl' "$stderr_file" 2>/dev/null; then
            attempt=$((attempt + 1))
            if [ "$attempt" -lt "$max_attempts" ]; then
                command sleep "$delay" 2>/dev/null
                delay=$((delay * 2))
                : >"$stderr_file"
                continue
            fi
        fi
        break
    done
    command rm -f "$stderr_file"
    return 1
}

# TTL-gated persistent cache wrapper for `op read`. Emits the resolved secret
# on stdout — from the cache if fresh, otherwise from upstream (with backoff)
# and writes the result to the cache atomically. OP_SECRET_CACHE_TTL=0
# disables the cache entirely.
_op_read_cached() {
    local ref="$1"
    local ttl="${OP_SECRET_CACHE_TTL:-1800}"
    local hash cache_file tmp age
    if [ "$ttl" -le 0 ] || [ -z "${_op_secret_cache_dir:-}" ] || [ ! -d "$_op_secret_cache_dir" ]; then
        _op_read_with_backoff "$ref"
        return $?
    fi
    hash=$(printf '%s' "$ref" | sha256sum | command awk '{print $1}')
    cache_file="${_op_secret_cache_dir}/${hash}"
    if [ -f "$cache_file" ]; then
        age=$(($(command date +%s) - $(command stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
        if [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; then
            command cat "$cache_file"
            return 0
        fi
    fi
    tmp=$(mktemp "${_op_secret_cache_dir}/tmp.XXXXXX" 2>/dev/null) || {
        _op_read_with_backoff "$ref"
        return $?
    }
    if _op_read_with_backoff "$ref" >"$tmp" && [ -s "$tmp" ]; then
        chmod 600 "$tmp" 2>/dev/null || true
        if mv -f "$tmp" "$cache_file" 2>/dev/null; then
            command cat "$cache_file"
        else
            command cat "$tmp"
            command rm -f "$tmp"
        fi
        return 0
    fi
    command rm -f "$tmp"
    return 1
}

# Shim: fetch via cache and write to a target file. Backgroundable with `&`
# (bash functions inherit into backgrounded subshells).
_fetch_to_file() {
    _op_read_cached "$1" >"$2"
}

# Fork `$@ &`, capping concurrent background jobs at OP_SECRET_CACHE_MAX_CONCURRENT
# to avoid overwhelming the 1Password service-account token. Uses `wait -n`
# (bash 4.3+) to block until any job exits when the cap is reached. All
# currently-supported distros ship bash ≥ 4.4.
_launch_fetch() {
    local max="${OP_SECRET_CACHE_MAX_CONCURRENT:-4}"
    if [ "$max" -gt 0 ]; then
        local active
        while :; do
            active=$(jobs -rp 2>/dev/null | command wc -l | command tr -d ' ')
            [ "$active" -lt "$max" ] && break
            wait -n 2>/dev/null || break
        done
    fi
    "$@" &
}

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
    # Background: fetch secret (cached + throttled + retried) and write to temp file
    _launch_fetch _fetch_to_file "$_ref_value" "${_op_tmp_dir}/ref_${_target_var}"
done

# Launch parallel fetches for OP_*_FILE_REF variables
for _ref_var in $(compgen -v | command grep '^OP_.\+_FILE_REF$'); do
    _target_var="${_ref_var#OP_}"
    _target_var="${_target_var%_FILE_REF}"
    [ -z "$_target_var" ] && continue
    [ -n "${!_target_var:-}" ] && continue
    _ref_value="${!_ref_var:-}"
    [ -z "$_ref_value" ] && continue
    _launch_fetch _fetch_to_file "$_ref_value" "${_op_tmp_dir}/fileref_${_target_var}_${_ref_value##*/}"
done

# Launch parallel git identity fetch if needed
if [ -z "${GIT_USER_NAME:-}" ] && [ -n "${OP_GIT_USER_NAME_REF:-}" ]; then
    _base_path="${OP_GIT_USER_NAME_REF%/*}"
    _launch_fetch _fetch_to_file "${_base_path}/first name" "${_op_tmp_dir}/git_first"
    _launch_fetch _fetch_to_file "${_base_path}/last name" "${_op_tmp_dir}/git_last"
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
            *) _file_ext="" ;;
        esac
        _file_path="/dev/shm/${_file_name}${_file_ext}"
        command cat "$_result_file" >"$_file_path"
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
} >"$_cache_tmp"
chmod 600 "$_cache_tmp"
mv "$_cache_tmp" "$_cache_file"
unset _cache_file _cache_tmp

# Restore xtrace state
if [ "$_xtrace_was_on" = true ]; then set -x; fi
unset _xtrace_was_on

# Clean up helper scaffolding
unset -f _op_read_with_backoff _op_read_cached _fetch_to_file _launch_fetch 2>/dev/null
unset _op_secret_cache_dir

exit 0
