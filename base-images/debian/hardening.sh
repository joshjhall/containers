#!/usr/bin/env bash
# Debian hardening library for v5 evidence base images.
#
# Generalized from v4 lib/base/shell-hardening.sh, lib/base/user.sh, and
# lib/base/user-env.sh into a stable per-distro interface. Other distro
# libraries (alpine/, rhel/) export the same four functions with the same
# argument shapes:
#
#   create_user             USERNAME UID GID
#   restrict_shells         (no args; reads RESTRICT_SHELLS)
#   harden_service_users    (no args; reads PRODUCTION_MODE)
#   configure_sudo          USERNAME (reads ENABLE_PASSWORDLESS_SUDO)
#
# Compliance carried forward from v4:
#   CIS Docker Benchmark 4.1, NIST 800-53 AC-6, PCI DSS 2.2.4, FedRAMP CM-7
#
# Used by:
#   base-images/debian/12/amd64/Dockerfile  (pilot)
#   base-images/debian/12/arm64/Dockerfile  (sub-issue)
#   base-images/debian/13/amd64/Dockerfile  (sub-issue)
#   base-images/debian/13/arm64/Dockerfile  (sub-issue)

set -euo pipefail

RESTRICT_SHELLS="${RESTRICT_SHELLS:-true}"
PRODUCTION_MODE="${PRODUCTION_MODE:-true}"
ENABLE_PASSWORDLESS_SUDO="${ENABLE_PASSWORDLESS_SUDO:-false}"

SERVICE_USERS=(
    www-data
    nobody
    daemon
    sys
    sync
    games
    man
    lp
    mail
    news
    uucp
    proxy
    backup
    list
    irc
    gnats
    _apt
)

log() {
    /usr/bin/echo "  [hardening:debian] $*"
}

warn() {
    /usr/bin/echo "  [hardening:debian] WARNING: $*" >&2
}

# ----------------------------------------------------------------------------
# create_user USERNAME UID GID
#
# Creates a non-root user with home directory and bash login shell. Unlike
# v4's user.sh, this does NOT scan for free UID/GID slots — evidence base
# images own the slot, so a collision is a build error worth surfacing.
# ----------------------------------------------------------------------------
create_user() {
    local username="${1:?username required}"
    local uid="${2:?uid required}"
    local gid="${3:?gid required}"

    log "Creating user ${username} (${uid}:${gid})"

    if /usr/bin/getent group "${gid}" >/dev/null 2>&1; then
        warn "GID ${gid} already in use; reusing existing group"
    else
        /usr/sbin/groupadd --gid "${gid}" "${username}"
    fi

    if /usr/bin/getent passwd "${uid}" >/dev/null 2>&1; then
        warn "UID ${uid} already in use; reusing existing user"
    else
        /usr/sbin/useradd \
            --uid "${uid}" \
            --gid "${gid}" \
            --shell /bin/bash \
            --create-home \
            "${username}"
    fi

    log "User ${username} ready"
}

# ----------------------------------------------------------------------------
# restrict_shells
#
# Restricts /etc/shells to bash entries only. CIS Docker Benchmark 4.1.
# ----------------------------------------------------------------------------
restrict_shells() {
    if [ "${RESTRICT_SHELLS}" != "true" ]; then
        log "Shell restriction disabled (RESTRICT_SHELLS=${RESTRICT_SHELLS})"
        return 0
    fi

    log "Restricting /etc/shells to bash"

    if [ ! -x /bin/bash ] && [ ! -x /usr/bin/bash ]; then
        warn "bash not found; refusing to restrict /etc/shells"
        return 1
    fi

    /usr/bin/cat >/etc/shells <<'EOF'
# /etc/shells: valid login shells
# Restricted for security — only bash allowed
# CIS Docker Benchmark 4.1, NIST 800-53 AC-6, PCI DSS 2.2.4, FedRAMP CM-7
/bin/bash
/usr/bin/bash
EOF
}

# ----------------------------------------------------------------------------
# harden_service_users
#
# Sets login shell to /usr/sbin/nologin for known service users when
# PRODUCTION_MODE=true. Default in evidence base images is true (the dev
# container kept it false for ergonomics; evidence runs do not need it).
# NIST 800-53 AC-6, FedRAMP CM-7.
# ----------------------------------------------------------------------------
harden_service_users() {
    if [ "${PRODUCTION_MODE}" != "true" ]; then
        log "Service-user hardening disabled (PRODUCTION_MODE=${PRODUCTION_MODE})"
        return 0
    fi

    local nologin="/usr/sbin/nologin"
    if [ ! -x "${nologin}" ]; then
        if [ -x /sbin/nologin ]; then
            nologin="/sbin/nologin"
        else
            warn "nologin not found; skipping service-user hardening"
            return 1
        fi
    fi

    log "Setting nologin for service users"
    local hardened=0 user current
    for user in "${SERVICE_USERS[@]}"; do
        /usr/bin/id "${user}" >/dev/null 2>&1 || continue
        current=$(/usr/bin/getent passwd "${user}" | /usr/bin/cut -d: -f7)
        case "${current}" in
            */nologin | */false)
                continue
                ;;
        esac
        if /usr/sbin/usermod -s "${nologin}" "${user}" 2>/dev/null; then
            hardened=$((hardened + 1))
        fi
    done
    log "Hardened ${hardened} service users"
}

# ----------------------------------------------------------------------------
# configure_sudo USERNAME
#
# Adds USERNAME to the sudo group. Passwordless sudo is OFF by default —
# flipped from v4's dev-container default. Evidence runs do not need
# password-less sudo; flip via ENABLE_PASSWORDLESS_SUDO=true if a tool's
# install genuinely requires it (the resulting image will not be a
# production base).
# ----------------------------------------------------------------------------
configure_sudo() {
    local username="${1:?username required}"

    /usr/sbin/usermod -aG sudo "${username}"

    if [ "${ENABLE_PASSWORDLESS_SUDO}" = "true" ]; then
        warn "Passwordless sudo enabled — image is NOT production-safe"
        /usr/bin/echo "${username} ALL=(ALL) NOPASSWD:ALL" |
            /usr/bin/install -m 0440 -o root -g root /dev/stdin "/etc/sudoers.d/${username}"
    else
        log "Passwordless sudo disabled (default; production-safe)"
    fi
}

# ----------------------------------------------------------------------------
# verify
#
# Best-effort post-hardening verification. Logs warnings rather than failing,
# so a single non-fatal slip doesn't tank a multi-tuple build matrix.
# ----------------------------------------------------------------------------
verify() {
    local issues=0

    if [ "${RESTRICT_SHELLS}" = "true" ]; then
        local shells
        shells=$(/usr/bin/grep -c "^/" /etc/shells 2>/dev/null || /usr/bin/echo 0)
        if [ "${shells}" -gt 2 ]; then
            warn "/etc/shells has ${shells} entries (expected 2)"
            issues=$((issues + 1))
        fi
    fi

    if [ "${PRODUCTION_MODE}" = "true" ]; then
        local user current
        for user in "${SERVICE_USERS[@]}"; do
            /usr/bin/id "${user}" >/dev/null 2>&1 || continue
            current=$(/usr/bin/getent passwd "${user}" | /usr/bin/cut -d: -f7)
            case "${current}" in
                */nologin | */false) ;;
                *)
                    warn "Service user ${user} still has shell ${current}"
                    issues=$((issues + 1))
                    ;;
            esac
        done
    fi

    log "Verification complete (${issues} issues)"
}

# ----------------------------------------------------------------------------
# main USERNAME UID GID
#
# Convenience entrypoint for Dockerfile RUN. Equivalent to invoking the
# four exported functions in order.
# ----------------------------------------------------------------------------
main() {
    local username="${1:?username required}"
    local uid="${2:?uid required}"
    local gid="${3:?gid required}"

    /usr/bin/echo "=== debian hardening: starting ==="
    /usr/bin/echo "  USERNAME=${username} UID=${uid} GID=${gid}"
    /usr/bin/echo "  RESTRICT_SHELLS=${RESTRICT_SHELLS}"
    /usr/bin/echo "  PRODUCTION_MODE=${PRODUCTION_MODE}"
    /usr/bin/echo "  ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO}"

    create_user "${username}" "${uid}" "${gid}"
    restrict_shells
    harden_service_users
    configure_sudo "${username}"
    verify

    /usr/bin/echo "=== debian hardening: complete ==="
}

# Allow this file to be sourced (function library) or invoked (RUN script).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
