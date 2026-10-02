#!/bin/bash
# Privilege probe for the startup reconcile steps
# Sourced by entrypoint.sh — do not execute directly
#
# Every reconcile step (docker socket, /cache, /run, bindfs) asks "can I run
# this privileged?" before trying. The old probe was `sudo -n true`, which only
# answers that question under NOPASSWD:ALL. Under ENABLE_PASSWORDLESS_SUDO=scoped
# (lib/base/sudoers.sh) `true` is not in the CONTAINER_STARTUP allowlist, so the
# probe failed and every step warn-and-skipped while the exact commands it
# needed WERE allowed (issue #996).
#
# `sudo -n -l <cmd> [args]` asks sudo whether that specific command line is
# permitted without a password — it answers correctly under NOPASSWD:ALL, under
# the scoped allowlist, and (non-zero) when sudo is absent or password-gated.
#
# Depends on globals from entrypoint.sh:
#   RUNNING_AS_ROOT

# Prevent multiple sourcing
if [ -n "${_PRIVILEGED_LOADED:-}" ]; then
    return 0
fi
_PRIVILEGED_LOADED=1

# can_run_privileged <cmd> [args...]
#
# Returns 0 when <cmd> [args...] can be run via run_privileged() — directly as
# root, or through passwordless sudo for that exact command line. Probe with the
# same command and arguments the caller is about to run, or a scoped rule with
# pinned arguments will (correctly) refuse.
can_run_privileged() {
    if [ "${RUNNING_AS_ROOT:-false}" = "true" ]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n -l "$@" >/dev/null 2>&1
}
