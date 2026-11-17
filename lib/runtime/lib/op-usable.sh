#!/bin/bash
# op-usable.sh — Shared "can op read secrets right now?" detection (#1711)
#
# Sourced (never executed) by every consumer that used to gate on
# OP_SERVICE_ACCOUNT_TOKEN alone: 45-op-secrets.sh, claude-setup,
# claude-auth-watcher, the op-cli bashrc helpers, _wait-for-op-cache and
# _source-env-secrets. Installed to /opt/container-runtime/lib/op-usable.sh.
#
# Why: an external credential provider (e.g. a host-side holder that exposes a
# pre-authenticated `op` shim over a socket) leaves NO token in the
# environment. Gating on the token made every consumer silently skip. This
# gates on "is op usable", which the token case still satisfies on its fast
# path, so today's token-based setup behaves exactly as before.
#
# Functions:
#   op_is_usable         - 0 when `op` is on PATH and authenticated by any of,
#                          in order: OP_SERVICE_ACCOUNT_TOKEN; OP_CONNECT_HOST +
#                          OP_CONNECT_TOKEN; a bounded, non-interactive
#                          `op whoami`. Never prompts, never hangs.
#   credential_env_load  - source the pre-secrets hook hand-off file written by
#                          30-credential-setup.sh (PATH for shims, etc.).
#
# Environment:
#   OP_WHOAMI_TIMEOUT          - seconds to bound `op whoami` (default 5)
#   OP_NO_WHOAMI_PROBE         - "true" disables the whoami probe (token/Connect only)
#   OP_USABLE_NEGATIVE_TTL     - seconds a "not usable" verdict is reused (per
#                                process and in the /dev/shm cache) before
#                                re-probing (default 30)
#   OP_WHOAMI_CACHE_DIR        - where the whoami verdict cache lives (default /dev/shm)
#   CONTAINER_CREDENTIAL_ENV_FILE - hand-off file (default
#                                /dev/shm/container-credential-env.<uid>)
#
# Safe under `set -euo pipefail` callers: every probe is guarded, and both
# functions only return status — they never exit the caller.

# Idempotent: re-sourcing is a no-op.
[ -n "${_OP_USABLE_SH_LOADED:-}" ] && return 0
_OP_USABLE_SH_LOADED=1

# Default hand-off path. Per-UID so a root-run hook and a user-run consumer
# can never trust each other's file.
_credential_env_file() {
    printf '%s' "${CONTAINER_CREDENTIAL_ENV_FILE:-/dev/shm/container-credential-env.$(id -u 2>/dev/null || echo 0)}"
}

# Source the hand-off file written by pre-secrets hooks. Refuses a file that is
# not a regular file, not owned by the current user, or group/world-writable:
# it is executed as shell, so a file another user can write is code injection.
# Returns 0 whether or not a file was loaded (absence is the common case).
credential_env_load() {
    local f
    f=$(_credential_env_file)
    [ -e "$f" ] || [ -L "$f" ] || return 0
    if [ -L "$f" ] || [ ! -f "$f" ]; then
        printf '[credential-env] WARN: ignoring %s (not a regular file)\n' "$f" >&2
        return 0
    fi
    if [ ! -O "$f" ]; then
        printf '[credential-env] WARN: ignoring %s (not owned by current user)\n' "$f" >&2
        return 0
    fi
    local perms
    perms=$(command stat -c '%a' "$f" 2>/dev/null || echo "")
    case "$perms" in
        *[2367]? | *[2367])
            printf '[credential-env] WARN: ignoring %s (group/world-writable, mode %s)\n' "$f" "$perms" >&2
            return 0
            ;;
    esac
    # Hooks may write secrets-adjacent values; keep them out of xtrace.
    local _cel_xt
    _cel_xt=$(set +o | command grep xtrace)
    { set +x; } 2>/dev/null
    local _cel_a
    _cel_a=$(set +o | command grep allexport)
    set -a
    # shellcheck disable=SC1090
    . "$f" || true
    eval "$_cel_a"
    eval "$_cel_xt"
    return 0
}

# whoami verdict cache, shared across processes (every non-interactive bash
# sources the op-cli bashrc helper, so an uncached probe would run per shell).
# Keyed on the resolved op path: a provider's shim lives at a different path
# from the real binary, so a "no" recorded before the shim reached PATH is
# never consulted for the shim. "ok" lives 60s; "no" lives
# OP_USABLE_NEGATIVE_TTL (default 30s) so a provider that comes up later is
# noticed promptly.
_op_whoami_cache_file() {
    local op_path="$1" key
    key=$(printf '%s' "$op_path" | command sha256sum 2>/dev/null | command cut -c1-16)
    [ -n "$key" ] || return 1
    printf '%s/op-whoami.%s.%s' "${OP_WHOAMI_CACHE_DIR:-/dev/shm}" "$(id -u 2>/dev/null || echo 0)" "$key"
}

op_is_usable() {
    # Per-process memo: consumers may ask several times per run. A "yes"
    # sticks; a "no" expires after OP_USABLE_NEGATIVE_TTL seconds (default 30)
    # so a long-lived poller (claude-auth-watcher) notices a provider that
    # becomes usable after it started.
    case "${_OP_USABLE:-}" in
        yes) return 0 ;;
        no)
            if [ $((SECONDS - ${_OP_USABLE_AT:-0})) -lt "${OP_USABLE_NEGATIVE_TTL:-30}" ]; then
                return 1
            fi
            ;;
    esac
    _OP_USABLE_AT=$SECONDS

    local op_path
    op_path=$(command -v op 2>/dev/null) || op_path=""
    if [ -z "$op_path" ]; then
        _OP_USABLE=no
        return 1
    fi

    # 1. Service account token (unchanged fast path, no subprocess).
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        _OP_USABLE=yes
        return 0
    fi

    # 2. 1Password Connect.
    if [ -n "${OP_CONNECT_HOST:-}" ] && [ -n "${OP_CONNECT_TOKEN:-}" ]; then
        _OP_USABLE=yes
        return 0
    fi

    # 3. Externally authenticated op: ask it, bounded and non-interactive.
    if [ "${OP_NO_WHOAMI_PROBE:-false}" = "true" ]; then
        _OP_USABLE=no
        return 1
    fi

    local cache now mtime verdict neg_ttl
    neg_ttl="${OP_USABLE_NEGATIVE_TTL:-30}"
    case "$neg_ttl" in '' | *[!0-9]*) neg_ttl=30 ;; esac
    cache=$(_op_whoami_cache_file "$op_path") || cache=""
    if [ -n "$cache" ] && [ -f "$cache" ] && [ ! -L "$cache" ] && [ -O "$cache" ]; then
        now=$(command date +%s 2>/dev/null || echo 0)
        mtime=$(command stat -c '%Y' "$cache" 2>/dev/null || echo 0)
        verdict=$(command head -c 2 "$cache" 2>/dev/null || echo "")
        if [ "$verdict" = "ok" ] && [ $((now - mtime)) -lt 60 ]; then
            _OP_USABLE=yes
            return 0
        fi
        if [ "$verdict" = "no" ] && [ $((now - mtime)) -lt "$neg_ttl" ]; then
            _OP_USABLE=no
            return 1
        fi
    fi

    local timeout_s="${OP_WHOAMI_TIMEOUT:-5}"
    case "$timeout_s" in '' | *[!0-9]*) timeout_s=5 ;; esac
    local rc=1
    if command -v timeout >/dev/null 2>&1; then
        # -k: a probe that ignores TERM is still reaped. stdin closed so op
        # can never block on an interactive sign-in prompt.
        command timeout -k 1 "$timeout_s" "$op_path" whoami </dev/null >/dev/null 2>&1 && rc=0
    fi
    # No `timeout` binary: we cannot bound the call, so do not make it —
    # an unbounded probe is exactly the hang this helper exists to prevent.

    local result=no
    [ "$rc" -eq 0 ] && result=ok
    if [ -n "$cache" ]; then
        # Replace, never write through, whatever is there (incl. a symlink).
        command rm -f "$cache" 2>/dev/null
        (umask 077 && printf '%s' "$result" >"$cache") 2>/dev/null || true
    fi
    if [ "$result" = "ok" ]; then
        _OP_USABLE=yes
        return 0
    fi
    _OP_USABLE=no
    return 1
}
