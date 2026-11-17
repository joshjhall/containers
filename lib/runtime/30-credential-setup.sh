#!/bin/bash
# 30-credential-setup.sh — Run a project's credential-provider setup BEFORE
# secret loading (#1711)
#
# An external credential provider (anything that makes `op`, `gh`, `glab` or
# git's ssh/signing work without a token in the environment) usually installs
# shims or sets env at container start. The every-boot scripts run in numeric
# order — 35-claude-auth-watcher, 45-op-secrets, 60-setup-git — so this script,
# at 30, is the generic place to do that first. `recover-entrypoint` (the Zed
# path) replays the same /etc/container/startup/ directory, so the ordering
# holds on both entry paths with no entrypoint change.
#
# Hooks (both optional; run in this order):
#   1. $CONTAINER_CREDENTIAL_SETUP_CMD — a command line, run via `bash -c`
#   2. /workspace/*/.devcontainer/pre-secrets.d/*.sh — run with `bash`, sorted;
#      OPT-IN: only when CREDENTIAL_SETUP_HOOKS=true (a mounted repo must not
#      get code execution at boot by shipping a file)
#
# Hand-off: every startup script is its own process, so a hook that changes
# PATH or exports variables would otherwise be invisible to 45-op-secrets.
# Hooks append shell assignments to $CONTAINER_CREDENTIAL_ENV_FILE (exported
# to them; a 0600 per-UID tmpfs file), e.g.
#     echo 'export PATH="/opt/provider/shims:$PATH"' >>"$CONTAINER_CREDENTIAL_ENV_FILE"
# and every later consumer sources it via credential_env_load
# (/opt/container-runtime/lib/op-usable.sh). Write config, not secrets.
#
# With no command and no hook files this exits immediately and creates
# nothing — startup is byte-for-byte what it was before this script existed.
#
# Environment:
#   CONTAINER_CREDENTIAL_SETUP_CMD - command to run first (optional)
#   CREDENTIAL_SETUP_HOOKS         - "true" to run workspace pre-secrets.d hooks
#   CREDENTIAL_SETUP_TIMEOUT       - per-hook timeout in seconds (default 30)
#   CREDENTIAL_SETUP_HOOK_GLOB     - override hook glob (testing; default
#                                    /workspace/*/.devcontainer/pre-secrets.d/*.sh)
#   CONTAINER_CREDENTIAL_ENV_FILE  - hand-off file path (default
#                                    /dev/shm/container-credential-env.<uid>)

set +e

_log() { printf '[credential-setup] %s\n' "$*" >&2; }

# Trust boundary: hooks come from the mounted workspace and run BEFORE secrets
# load, so a hook another user could have written is refused — loudly, so a
# refused hook never looks like "no hook". Regular files only (no symlinks,
# same rule as run_startup_scripts), owned by the current user or root, and
# not group/world-writable.
_hook_trusted() {
    local f="$1" owner perms
    if [ -L "$f" ] || [ ! -f "$f" ]; then
        _log "WARN: ignoring hook ${f} (not a regular file)"
        return 1
    fi
    owner=$(command stat -c '%u' "$f" 2>/dev/null || echo "")
    if [ "$owner" != "$(id -u)" ] && [ "$owner" != "0" ]; then
        _log "WARN: ignoring hook ${f} (owned by uid ${owner:-?}, not the current user or root)"
        return 1
    fi
    perms=$(command stat -c '%a' "$f" 2>/dev/null || echo "")
    case "$perms" in
        *[2367]? | *[2367])
            _log "WARN: ignoring hook ${f} (group/world-writable, mode ${perms})"
            return 1
            ;;
    esac
    return 0
}

_hook_glob="${CREDENTIAL_SETUP_HOOK_GLOB:-/workspace/*/.devcontainer/pre-secrets.d/*.sh}"
_hooks=()
shopt -s nullglob
# shellcheck disable=SC2206 # the glob is a pattern by design; nullglob drops non-matches
_candidates=($_hook_glob)
shopt -u nullglob
# Workspace hooks are opt-in: a repo mounted under /workspace must not get
# code execution at boot (before secrets load) just by shipping a file here.
# CONTAINER_CREDENTIAL_SETUP_CMD comes from the operator's own env/compose,
# not a repo, so it needs no opt-in.
if [ "${CREDENTIAL_SETUP_HOOKS:-false}" = "true" ]; then
    for _h in "${_candidates[@]}"; do
        _hook_trusted "$_h" && _hooks+=("$_h")
    done
elif [ "${#_candidates[@]}" -gt 0 ]; then
    _log "skipping ${#_candidates[@]} pre-secrets.d hook(s): workspace hooks are opt-in (set CREDENTIAL_SETUP_HOOKS=true)"
fi
unset _h _candidates

# Fresh hand-off file every boot: stale entries from a previous start must not
# outlive the hooks that wrote them. Cleared BEFORE the nothing-to-run exit, so
# turning hooks off (or removing them) also retires what they last wrote — a
# recover-entrypoint replay keeps /dev/shm across "boots".
_env_file="${CONTAINER_CREDENTIAL_ENV_FILE:-/dev/shm/container-credential-env.$(id -u)}"
command rm -f "$_env_file" 2>/dev/null

if [ -z "${CONTAINER_CREDENTIAL_SETUP_CMD:-}" ] && [ "${#_hooks[@]}" -eq 0 ]; then
    exit 0
fi

if ! (umask 077 && : >"$_env_file") 2>/dev/null; then
    _log "WARN: cannot create hand-off file ${_env_file}; hooks' env will not reach later scripts"
fi
export CONTAINER_CREDENTIAL_ENV_FILE="$_env_file"

_timeout="${CREDENTIAL_SETUP_TIMEOUT:-30}"
case "$_timeout" in '' | *[!0-9]*) _timeout=30 ;; esac

# Run one hook bounded by the timeout when `timeout` exists. A hook that fails
# or times out is logged and the next hook still runs: a broken provider must
# degrade to "no provider", never block container start.
_run_hook() {
    local label="$1"
    shift
    local rc=0
    if command -v timeout >/dev/null 2>&1; then
        command timeout -k 5 "$_timeout" "$@" </dev/null || rc=$?
    else
        "$@" </dev/null || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        _log "ran ${label}"
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        _log "WARN: ${label} timed out after ${_timeout}s (continuing)"
    else
        _log "WARN: ${label} failed (exit ${rc}) (continuing)"
    fi
}

if [ -n "${CONTAINER_CREDENTIAL_SETUP_CMD:-}" ]; then
    _run_hook "CONTAINER_CREDENTIAL_SETUP_CMD" bash -c "$CONTAINER_CREDENTIAL_SETUP_CMD"
fi

for _h in "${_hooks[@]}"; do
    _run_hook "hook $(basename "$_h")" bash "$_h"
done

exit 0
