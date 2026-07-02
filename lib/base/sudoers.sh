#!/bin/bash
# Sudoers rendering for command-scoped passwordless sudo (least privilege)
#
# The container's final USER is the non-root ${USERNAME}, so the entrypoint runs
# unprivileged and lib/runtime/entrypoint.sh run_privileged() falls back to
# `sudo` for startup permission/mount reconciliation. That reconciliation needs
# only a small, fixed set of privileged commands — NOT arbitrary root.
#
# render_scoped_sudoers prints a sudoers file body that grants passwordless
# access to ONLY those startup commands via a Cmnd_Alias, so that a compromised
# process running as ${USERNAME} (interactive shell, agent tool call, pulled-in
# dependency) cannot escalate to root the way NOPASSWD:ALL allows.
#
# The privileged command set is derived from every run_privileged call in
# lib/runtime/ (keep this list in sync if that set changes):
#   - bindfs …                                   lib/runtime/lib/setup-bindfs.sh
#   - chown -R <uid>:<gid> /cache                lib/runtime/lib/fix-cache-permissions.sh
#   - chown <uid>:<gid> /run                     lib/runtime/lib/fix-run-permissions.sh
#   - groupadd docker                            lib/runtime/lib/fix-docker-socket.sh
#   - chown root:docker /var/run/docker.sock     lib/runtime/lib/fix-docker-socket.sh
#   - chmod 660 /var/run/docker.sock             lib/runtime/lib/fix-docker-socket.sh
#   - usermod -aG docker <USERNAME>              lib/runtime/lib/fix-docker-socket.sh
#
# Why the two variable chowns are NOT granted as `chown` directly: sudo joins a
# command's arguments and fnmatch()-matches them as one string, and `chown`
# accepts multiple operands, so a rule like `chown * /cache` matches
# `chown -R me:me /etc/sudoers.d /cache` — letting the user take ownership of
# /etc/sudoers.d and escalate to full root. A `*` wildcard cannot bound
# "numeric uid:gid then exactly /cache", and sudoers regex matching (which
# could) requires sudo >= 1.9.10, excluding Debian 11 (sudo 1.9.5). So the two
# runtime chowns whose uid:gid vary are instead run through fixed-purpose,
# path-hardcoded wrapper commands (reconcile-cache-owner / reconcile-run-owner,
# lib/runtime/commands/), and sudoers grants ONLY those wrappers. The remaining
# commands have fixed arguments and are pinned exactly.
#
# Usage:
#   source /tmp/build-scripts/base/sudoers.sh
#   render_scoped_sudoers "${USERNAME}" | install -m 0440 -o root -g root \
#       /dev/stdin /etc/sudoers.d/"${USERNAME}"
#
# Include guard: _SUDOERS_LOADED

# Prevent multiple sourcing
if [ -n "${_SUDOERS_LOADED:-}" ]; then
    return 0
fi
_SUDOERS_LOADED=1

# _resolve_cmd_path <command> <fallback>
#
# Resolve a command to an absolute path for use in a sudoers Cmnd_Alias. sudo
# requires fully-qualified paths, and command paths are distro-sensitive. Prefer
# the resolved location from PATH, falling back to a canonical absolute path when
# the command is not yet installed at render time (e.g. bindfs, which is
# installed by a later feature step than user.sh).
_resolve_cmd_path() {
    local cmd="$1" fallback="$2" resolved
    resolved="$(command -v "$cmd" 2>/dev/null || true)"
    # command -v may return a shell builtin/alias without a leading slash; only
    # trust an absolute path, otherwise use the canonical fallback.
    case "$resolved" in
        /*) printf '%s\n' "$resolved" ;;
        *) printf '%s\n' "$fallback" ;;
    esac
}

# Absolute install path of the chown wrapper commands (Dockerfile COPYs
# lib/runtime/commands/reconcile-* here). Kept as constants so both the render
# and its callers agree on the exact strings that appear in the sudoers file.
_RECONCILE_CACHE_CMD="/usr/local/sbin/reconcile-cache-owner"
_RECONCILE_RUN_CMD="/usr/local/sbin/reconcile-run-owner"

# render_scoped_sudoers <username>
#
# Print (to stdout) a command-scoped /etc/sudoers.d/<username> body granting
# passwordless sudo for ONLY the startup-reconciliation commands.
#
# Matching model: every entry either is a fixed-purpose wrapper whose target is
# hardcoded inside the wrapper (the reconcile-* commands — the trailing `*` only
# lets the caller pass <uid> <gid>, which the wrapper validates as numeric), or
# is pinned to its exact fixed arguments (groupadd/chmod/usermod, and the
# socket chown whose args are the literal `root:docker /var/run/docker.sock`).
# No rule grants bare `chown` with a wildcard path operand, so the
# /etc/sudoers.d-takeover escape that `chown * /cache` would allow is closed.
#
# Known limitation: `bindfs *` permits arbitrary bindfs arguments. bindfs is a
# FUSE helper (not a general root primitive) and its grant is far narrower than
# NOPASSWD:ALL; pinning its mount targets behind a wrapper too is a possible
# follow-up, intentionally out of scope here.
render_scoped_sudoers() {
    local username="$1"
    local bindfs chown chmod groupadd usermod

    bindfs="$(_resolve_cmd_path bindfs /usr/bin/bindfs)"
    chown="$(_resolve_cmd_path chown /usr/bin/chown)"
    chmod="$(_resolve_cmd_path chmod /usr/bin/chmod)"
    groupadd="$(_resolve_cmd_path groupadd /usr/sbin/groupadd)"
    usermod="$(_resolve_cmd_path usermod /usr/sbin/usermod)"

    # The socket chown has fixed args, so pin it exactly. The `:` in the
    # `root:docker` operand must be backslash-escaped — an unescaped colon is
    # the sudoers Runas separator and is a parse error inside a command's args.
    command cat <<EOF
# /etc/sudoers.d/${username} — command-scoped passwordless sudo (least privilege)
# Generated by lib/base/sudoers.sh (ENABLE_PASSWORDLESS_SUDO=scoped).
# Grants ONLY the privileged startup-reconciliation commands run by
# lib/runtime/entrypoint.sh run_privileged(); NOT arbitrary root. The two
# variable chowns go through path-hardcoded wrappers so no bare chown with a
# wildcard path operand is ever granted (see lib/base/sudoers.sh header).
Cmnd_Alias CONTAINER_STARTUP = \\
    ${bindfs} *, \\
    ${_RECONCILE_CACHE_CMD} *, \\
    ${_RECONCILE_RUN_CMD} *, \\
    ${groupadd} docker, \\
    ${chown} root\\:docker /var/run/docker.sock, \\
    ${chmod} 660 /var/run/docker.sock, \\
    ${usermod} -aG docker ${username}
${username} ALL=(ALL) NOPASSWD: CONTAINER_STARTUP
EOF
}
