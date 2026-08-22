#!/bin/bash
# resolve-container-user.sh — resolve the non-root container user at RUN time
#
# Editors remap the container user's UID differently — Zed adopts the host UID
# (e.g. 501 on macOS), VS Code keeps the image-native UID (1000) — so nothing
# that needs the runtime user may assume a fixed name or number. This is the
# single ladder that answers "who is the container user right now".
#
# It lives in its own sub-module because it has TWO callers whose ladders must
# not drift apart (the LADDER is shared; see the caveat below on its inputs):
#
#   1. lib/runtime/entrypoint.sh, which drops privileges to this user.
#   2. lib/runtime/workspace-fs-health-cron.sh, whose /etc/cron.d entry runs as
#      root precisely so it can re-resolve here rather than carry a build-time
#      ${USERNAME} baked into cron's user column (issue #800).
#
# Caveat — shared code, not identical inputs. Both callers run the same ladder,
# but cron inherits none of `docker run -e`, so arm 1's CONTAINER_UID is visible
# to the entrypoint and (today) not to the cron leg, which resolves by shape.
# Same user on every image we ship, since each has exactly one regular login
# user; they could differ only on an image with two such accounts AND a
# CONTAINER_UID naming the non-obvious one. See workspace-fs-health-cron.sh's
# re-exec stage and docs/troubleshooting/case-sensitive-filesystems.md.
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
        # Apply arm 2's exclusions here too, so an override cannot select an
        # account the shape match would have rejected:
        #
        #   - NOT root. A CONTAINER_UID of 0 would otherwise resolve to "root",
        #     and the cron leg's `su -l root` would be a no-op — the privilege
        #     drop it exists to perform, silently skipped, with the repair's
        #     writes landing root-owned inside the user's workspace.
        #   - A real login shell. `su -l` into a nologin/false account just
        #     prints and exits, so the hourly repair would silently never run —
        #     the same class of silent no-op this whole change removes.
        #
        # Either rejection falls through to the shape match, and failing that
        # the caller's own guard, rather than resolving to something unusable.
        username=$(command getent passwd "${CONTAINER_UID}" | command awk -F: \
            '$1 != "root" && $7 !~ /(nologin|false)$/ { print $1; exit }') || true
    fi

    if [ -z "$username" ]; then
        username=$(command getent passwd | command awk -F: \
            '$1 != "root" && $6 ~ /^\/home\// && $7 !~ /(nologin|false)$/ { print $1; exit }') || true
    fi

    if [ -z "$username" ]; then
        return 1
    fi

    command printf '%s\n' "$username"
}
