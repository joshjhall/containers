# ----------------------------------------------------------------------------
# Environment Secrets Loader
#
# Sources .env.secrets at shell init time so that secrets (e.g.,
# OP_SERVICE_ACCOUNT_TOKEN) are available without ever appearing in
# docker-compose output.
#
# Search order (first match wins):
#   1. $ENV_SECRETS_FILE  — explicit path override
#   2. $HOME/.env.secrets — user-level secrets
#   3. $PWD/.env.secrets  — project-level secrets (container WORKDIR)
#   4. /workspace/*/.env.secrets — workspace mount fallback
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u # Don't error on unset variables
set +e # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Idempotency guard — don't re-source across nested shells
if [ -n "${_ENV_SECRETS_LOADED:-}" ]; then
    return 0
fi

# Disable xtrace to prevent token exposure in debug output
_env_secrets_old_xtrace=$(set +o | command grep xtrace)
set +x

# Find the first matching .env.secrets file
# Search order: explicit path > $HOME > $PWD > /workspace subdirectories
_env_secrets_file=""
if [ -n "${ENV_SECRETS_FILE:-}" ] && [ -f "${ENV_SECRETS_FILE}" ]; then
    _env_secrets_file="${ENV_SECRETS_FILE}"
elif [ -n "${HOME:-}" ] && [ -f "${HOME}/.env.secrets" ]; then
    _env_secrets_file="${HOME}/.env.secrets"
elif [ -f "${PWD}/.env.secrets" ]; then
    _env_secrets_file="${PWD}/.env.secrets"
elif [ -d "/workspace" ]; then
    # During entrypoint startup, $PWD may not be the project directory.
    # Search /workspace subdirectories as a fallback.
    for _ws_dir in /workspace/*/; do
        if [ -f "${_ws_dir}.env.secrets" ]; then
            _env_secrets_file="${_ws_dir}.env.secrets"
            break
        fi
    done
fi

# Source it with auto-export so users don't need 'export' in their file
if [ -n "$_env_secrets_file" ]; then
    set -a
    . "$_env_secrets_file"
    set +a
fi

# Mark as loaded
_ENV_SECRETS_LOADED=1

# Clean up
unset _env_secrets_file

# Restore xtrace state
eval "$_env_secrets_old_xtrace"
unset _env_secrets_old_xtrace
