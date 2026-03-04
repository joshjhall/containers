# Source OP secrets cache for non-interactive shells
# The 45-op-secrets.sh startup script resolves OP_*_REF variables and writes
# the results to /dev/shm/op-secrets-cache. This script sources that cache
# in ALL shell contexts so that commands like setup-gh work when invoked
# from devcontainer.json postStartCommand (non-interactive).
#
# Interactive shells also benefit (fast path before 70-1password.sh runs).

set +u
set +e

_OP_SECRETS_CACHE_FILE="/dev/shm/op-secrets-cache"

# Source cache if it exists and is owned by current user (security check)
if [ -f "$_OP_SECRETS_CACHE_FILE" ] && [ -O "$_OP_SECRETS_CACHE_FILE" ]; then
    _old_xtrace=$(set +o | command grep xtrace)
    set +x
    . "$_OP_SECRETS_CACHE_FILE"
    eval "$_old_xtrace"
    unset _old_xtrace
fi

unset _OP_SECRETS_CACHE_FILE
