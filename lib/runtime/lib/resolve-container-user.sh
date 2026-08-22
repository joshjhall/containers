#!/bin/bash
# resolve-container-user.sh — resolve the non-root container user at RUN time
#
# Editors remap the container user's UID differently — Zed adopts the host UID
# (e.g. 501 on macOS), VS Code keeps the image-native UID (1000) — so nothing
# that needs the runtime user may assume a fixed name or number. This is the
# single ladder that answers "who is the container user right now".
#
# It lives in its own sub-module because it has TWO callers that must not drift:
#
#   1. lib/runtime/entrypoint.sh, which drops privileges to this user.
#   2. lib/runtime/workspace-fs-health-cron.sh, whose /etc/cron.d entry runs as
#      root precisely so it can re-resolve here rather than carry a build-time
#      ${USERNAME} baked into cron's user column (issue #800).
#
# Usage:
#   source /opt/container-runtime/lib/resolve-container-user.sh
#   user=$(resolve_container_user) || handle-failure
#
# Prints the resolved username on stdout. Returns 1 when no non-root container
# user can be determined; the caller decides whether that is fatal (the
# entrypoint errors out, the cron leg exits 0 silently).

# Prevent multiple sourcing
if [ -n "${_RESOLVE_CONTAINER_USER_LOADED:-}" ]; then
    return 0
fi
_RESOLVE_CONTAINER_USER_LOADED=1

# resolve_container_user
#
# Two arms, in order:
#   1. CONTAINER_UID, when set — an explicit override always wins.
#   2. The single regular login user, matched by SHAPE.
#
# Arm 2 cannot filter by UID range: Zed remaps the user to the host UID (e.g.
# 501 on macOS), which lands inside Debian's system-UID range (<1000), so a
# range filter would miss exactly the case this exists to handle. Match instead
# on a real home under /home plus a genuine login shell (not nologin/false),
# which our images' single regular user satisfies regardless of UID.
resolve_container_user() {
    local username=""

    # The trailing `|| true` on each getent is critical: under `set -e`, a miss
    # exits non-zero inside the command substitution and would abort a sourcing
    # caller before it could report the failure itself (silent exit 2).
    if [ -n "${CONTAINER_UID:-}" ]; then
        username=$(getent passwd "${CONTAINER_UID}" | command cut -d: -f1) || true
        # Never hand back root. Arm 2 excludes it by name, and this arm must
        # too: a CONTAINER_UID of 0 would otherwise resolve to "root", and the
        # cron leg's `su -l root` would be a no-op — the privilege drop it
        # exists to perform, silently skipped, with the repair's writes landing
        # root-owned inside the user's workspace. Falls through to the shape
        # match instead.
        if [ "$username" = "root" ]; then
            username=""
        fi
    fi

    if [ -z "$username" ]; then
        username=$(getent passwd | command awk -F: \
            '$1 != "root" && $6 ~ /^\/home\// && $7 !~ /(nologin|false)$/ { print $1; exit }') || true
    fi

    if [ -z "$username" ]; then
        return 1
    fi

    command printf '%s\n' "$username"
}
