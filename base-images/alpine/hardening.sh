#!/usr/bin/env bash
# Alpine hardening library for v5 evidence base images.
#
# Sibling of base-images/debian/hardening.sh: exports the same four-function
# interface with the same argument shapes so a per-tuple Dockerfile is the only
# distro-specific surface. Kept ARCH-AGNOSTIC — the alpine/3.21/arm64 tuple
# (sub-issue #434) reuses this file verbatim.
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
#   base-images/alpine/3.21/amd64/Dockerfile  (this issue, #433)
#   base-images/alpine/3.21/arm64/Dockerfile  (sub-issue #434)
#
# Intentional divergence from debian/hardening.sh: debian resolves coreutils
# and shadow tooling at hardcoded absolute paths (/usr/sbin/useradd, …). On
# Alpine those applets are busybox-provided and their on-disk locations differ
# (and shift between busybox layouts), so this file calls user-management tools
# by BARE NAME (addgroup/adduser/getent/usermod) and lets PATH resolve them.
# bash itself is installed (apk add bash) so this #!/usr/bin/env bash shebang
# and the restrict_shells /etc/shells→bash invariant both hold literally, and
# lib/base/os-validation.sh's bash >= 5.0 requirement is satisfied (Alpine 3.21
# ships bash 5.2).

set -euo pipefail

RESTRICT_SHELLS="${RESTRICT_SHELLS:-true}"
PRODUCTION_MODE="${PRODUCTION_MODE:-true}"
ENABLE_PASSWORDLESS_SUDO="${ENABLE_PASSWORDLESS_SUDO:-false}"

# Alpine's stock service users. The loop skips absent users via `id … ||
# continue`, so an over-broad list is harmless. Debian-only accounts
# (www-data, _apt, proxy, backup, gnats, irc, list) are intentionally dropped.
SERVICE_USERS=(
    nobody
    daemon
    bin
    sys
    sync
    games
    man
    lp
    mail
    news
    uucp
    operator
    ftp
    cron
    adm
    shutdown
    halt
    postgres
)

log() {
    echo "  [hardening:alpine] $*"
}

warn() {
    echo "  [hardening:alpine] WARNING: $*" >&2
}

# ----------------------------------------------------------------------------
# create_user USERNAME UID GID
#
# Creates a non-root user with home directory and bash login shell using
# busybox addgroup/adduser. Like the debian sibling, this does NOT scan for
# free UID/GID slots — evidence base images own the slot, so a collision is a
# build error worth surfacing (warn, reuse, keep going).
#
# Tooling is resolved by bare name on PATH (busybox applet locations differ
# from debian's absolute paths — see the file header).
# ----------------------------------------------------------------------------
create_user() {
    local username="${1:?username required}"
    local uid="${2:?uid required}"
    local gid="${3:?gid required}"

    log "Creating user ${username} (${uid}:${gid})"

    if getent group "${gid}" >/dev/null 2>&1; then
        warn "GID ${gid} already in use; reusing existing group"
    else
        addgroup -g "${gid}" "${username}"
    fi

    if getent passwd "${uid}" >/dev/null 2>&1; then
        warn "UID ${uid} already in use; reusing existing user"
    else
        adduser \
            -D \
            -u "${uid}" \
            -G "${username}" \
            -s /bin/bash \
            -h "/home/${username}" \
            "${username}"
    fi

    log "User ${username} ready"
}

# ----------------------------------------------------------------------------
# restrict_shells
#
# Restricts /etc/shells to bash entries only. CIS Docker Benchmark 4.1.
# Near-verbatim port of the debian function; the bash-presence guard passes
# because the Dockerfile installs bash.
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

    cat >/etc/shells <<'EOF'
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
# Sets login shell to nologin for known service users when PRODUCTION_MODE=true.
# Alpine's nologin lives at /sbin/nologin; the /usr/sbin→/sbin fallback chain
# (carried over from debian) lands there. NIST 800-53 AC-6, FedRAMP CM-7.
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
        id "${user}" >/dev/null 2>&1 || continue
        current=$(getent passwd "${user}" | cut -d: -f7)
        case "${current}" in
            */nologin | */false)
                continue
                ;;
        esac
        if usermod -s "${nologin}" "${user}" 2>/dev/null; then
            hardened=$((hardened + 1))
        fi
    done
    log "Hardened ${hardened} service users"
}

# ----------------------------------------------------------------------------
# configure_sudo USERNAME
#
# Adds USERNAME to Alpine's native sudo group `wheel` (NOT a `sudo` group) and
# enables %wheel in sudoers. Passwordless sudo is OFF by default; flip via
# ENABLE_PASSWORDLESS_SUDO=true only when a tool's install genuinely requires
# it (the resulting image is NOT production-safe).
# ----------------------------------------------------------------------------
configure_sudo() {
    local username="${1:?username required}"

    addgroup wheel 2>/dev/null || true
    usermod -aG wheel "${username}"

    # Enable the wheel group in sudoers (non-passwordless, default path).
    echo "%wheel ALL=(ALL) ALL" |
        install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/wheel

    if [ "${ENABLE_PASSWORDLESS_SUDO}" = "true" ]; then
        warn "Passwordless sudo enabled — image is NOT production-safe"
        echo "${username} ALL=(ALL) NOPASSWD:ALL" |
            install -m 0440 -o root -g root /dev/stdin "/etc/sudoers.d/${username}"
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
        shells=$(grep -c "^/" /etc/shells 2>/dev/null || echo 0)
        if [ "${shells}" -gt 2 ]; then
            warn "/etc/shells has ${shells} entries (expected 2)"
            issues=$((issues + 1))
        fi
    fi

    if [ "${PRODUCTION_MODE}" = "true" ]; then
        local user current
        for user in "${SERVICE_USERS[@]}"; do
            id "${user}" >/dev/null 2>&1 || continue
            current=$(getent passwd "${user}" | cut -d: -f7)
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

    echo "=== alpine hardening: starting ==="
    echo "  USERNAME=${username} UID=${uid} GID=${gid}"
    echo "  RESTRICT_SHELLS=${RESTRICT_SHELLS}"
    echo "  PRODUCTION_MODE=${PRODUCTION_MODE}"
    echo "  ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO}"

    create_user "${username}" "${uid}" "${gid}"
    restrict_shells
    harden_service_users
    configure_sudo "${username}"
    verify

    echo "=== alpine hardening: complete ==="
}

# Allow this file to be sourced (function library) or invoked (RUN script).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
