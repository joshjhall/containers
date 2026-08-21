#!/bin/bash
# 60-setup-git.sh — Configure git identity on every container start
#
# Why this exists as a startup script rather than only a postStartCommand link:
#
# `setup-git` is wired into this repo's devcontainer postStartCommand chain, but
# that chain is not a reliable place to depend on secrets. Under Zed,
# postStartCommand fires ~147ms after container start while the entrypoint (which
# runs 45-op-secrets.sh to resolve OP_*_REF) needs ~3s — they run concurrently, so
# a postStart link can observe an unresolved GIT_USER_NAME/GIT_USER_EMAIL. It also
# leaves projects whose generated devcontainer.json never chains setup-git at all
# with no git identity whatsoever.
#
# Running here instead puts identity setup *after* 45-op-secrets.sh in the same
# sequential every-boot phase, so the secrets it needs are already resolved. The
# entrypoint runs this phase on every start under VS Code (PID 1) and
# `recover-entrypoint` replays it on every start under Zed via
# ENTRYPOINT_STARTUP_ONLY, so both editors converge on a configured identity.
#
# This does not remove the postStart race — it removes git identity's dependence
# on winning it. See docs/troubleshooting/zed-devcontainer.md.
#
# Skip with: SKIP_GIT_SETUP=true

# ============================================================================
# Skip gate
# ============================================================================

if [ "${SKIP_GIT_SETUP:-false}" = "true" ]; then
    exit 0
fi

if ! command -v setup-git >/dev/null 2>&1; then
    exit 0
fi

# ============================================================================
# Run setup-git
# ============================================================================
# setup-git is idempotent (it reports "skip:" for already-correct state) and
# sources the OP secrets cache itself, so it needs no arguments or pre-sourced
# environment. Failure is non-fatal: the entrypoint continues past a failing
# startup script, and a container that boots without a git identity is far
# better than one that does not boot. setup-git applies obvious fallback values
# (Devcontainer <devcontainer@localhost>) when the real identity is unavailable.

if ! setup-git; then
    echo "[startup] WARNING: setup-git failed; git identity may be unconfigured" >&2
fi

exit 0
