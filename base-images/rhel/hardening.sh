#!/usr/bin/env bash
# RHEL/UBI hardening library for v5 evidence base images.
#
# Sibling of base-images/debian/hardening.sh and base-images/alpine/hardening.sh:
# exports the same four-function interface with the same argument shapes so a
# per-tuple Dockerfile is the only distro-specific surface. Kept ARCH-AGNOSTIC —
# the rhel/9/arm64 tuple (sub-issue #436) reuses this file verbatim.
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
#   base-images/rhel/9/amd64/Dockerfile  (this issue, #435)
#   base-images/rhel/9/arm64/Dockerfile  (sub-issue #436)
#
# Intentional divergences from debian/hardening.sh:
#   - Like the alpine sibling, this file calls user-management tools by BARE
#     NAME (groupadd/useradd/getent/usermod) and lets PATH resolve them rather
#     than hardcoding absolute paths. RHEL ships FULL shadow-utils (not busybox),
#     so the tools take the same debian-style long flags (--uid/--gid/...).
#   - bash is NOT installed by the Dockerfile: UBI 9 ships bash 5.1 by default,
#     which satisfies lib/base/os-validation.sh's bash >= 5.0 requirement, the
#     #!/usr/bin/env bash shebang, and the /etc/shells→bash invariant for free
#     (contrast alpine, which had to `apk add bash` on top of busybox ash).

set -euo pipefail

RESTRICT_SHELLS="${RESTRICT_SHELLS:-true}"
PRODUCTION_MODE="${PRODUCTION_MODE:-true}"
ENABLE_PASSWORDLESS_SUDO="${ENABLE_PASSWORDLESS_SUDO:-false}"

# RHEL/UBI 9's stock service users. The loop skips absent users via `id … ||
# continue`, so an over-broad list is harmless. Debian-only accounts
# (www-data, _apt, proxy, backup, list, irc, gnats) and alpine-only accounts
# (postgres, cron, uucp, man, news) are intentionally dropped.
SERVICE_USERS=(
    bin
    daemon
    adm
    lp
    sync
    shutdown
    halt
    mail
    operator
    games
    ftp
    nobody
)

log() {
    echo "  [hardening:rhel] $*"
}

warn() {
    echo "  [hardening:rhel] WARNING: $*" >&2
}

# ----------------------------------------------------------------------------
# create_user USERNAME UID GID
#
# Creates a non-root user with home directory and bash login shell using
# shadow-utils groupadd/useradd. Like the debian/alpine siblings, this does NOT
# scan for free UID/GID slots — evidence base images own the slot, so a
# collision is a build error worth surfacing (warn, reuse, keep going).
#
# Tooling is resolved by bare name on PATH (see the file header).
# ----------------------------------------------------------------------------
create_user() {
    local username="${1:?username required}"
    local uid="${2:?uid required}"
    local gid="${3:?gid required}"

    log "Creating user ${username} (${uid}:${gid})"

    if getent group "${gid}" >/dev/null 2>&1; then
        warn "GID ${gid} already in use; reusing existing group"
    else
        groupadd --gid "${gid}" "${username}"
    fi

    if getent passwd "${uid}" >/dev/null 2>&1; then
        warn "UID ${uid} already in use; reusing existing user"
    else
        useradd \
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
# Near-verbatim port of the alpine function; the bash-presence guard passes
# because UBI 9 ships bash (both /bin/bash and /usr/bin/bash via usrmerge).
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
# Sets login shell to a deny-login shell for known service users when
# PRODUCTION_MODE=true. Prefers /usr/sbin/nologin (or /sbin/nologin), but
# ubi-minimal ships neither by default, so the chain bottoms out at
# /usr/bin/false — a coreutils binary that is always present and is an
# equally valid non-login shell (the hardening invariant explicitly allows a
# "distro equivalent", and both this function and verify() treat */false as
# hardened). NIST 800-53 AC-6, FedRAMP CM-7.
# ----------------------------------------------------------------------------
harden_service_users() {
    if [ "${PRODUCTION_MODE}" != "true" ]; then
        log "Service-user hardening disabled (PRODUCTION_MODE=${PRODUCTION_MODE})"
        return 0
    fi

    # Pick the first available deny-login shell. /usr/bin/false is the
    # guaranteed floor on a minimal image where nologin is not installed.
    local nologin=""
    local candidate
    for candidate in /usr/sbin/nologin /sbin/nologin /usr/bin/false /bin/false; do
        if [ -x "${candidate}" ]; then
            nologin="${candidate}"
            break
        fi
    done
    if [ -z "${nologin}" ]; then
        warn "no deny-login shell found; skipping service-user hardening"
        return 0
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
# Adds USERNAME to RHEL's native sudo group `wheel` and enables %wheel in
# sudoers. `groupadd wheel` is defensive — wheel preexists on RHEL — so the
# `|| true` swallows the expected "already exists". Passwordless sudo is OFF by
# default; flip via ENABLE_PASSWORDLESS_SUDO=true only when a tool's install
# genuinely requires it (the resulting image is NOT production-safe). Requires
# the sudo package (installed in the Dockerfile).
# ----------------------------------------------------------------------------
configure_sudo() {
    local username="${1:?username required}"

    groupadd wheel 2>/dev/null || true
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

    echo "=== rhel hardening: starting ==="
    echo "  USERNAME=${username} UID=${uid} GID=${gid}"
    echo "  RESTRICT_SHELLS=${RESTRICT_SHELLS}"
    echo "  PRODUCTION_MODE=${PRODUCTION_MODE}"
    echo "  ENABLE_PASSWORDLESS_SUDO=${ENABLE_PASSWORDLESS_SUDO}"

    create_user "${username}" "${uid}" "${gid}"
    restrict_shells
    harden_service_users
    configure_sudo "${username}"
    verify

    echo "=== rhel hardening: complete ==="
}

# Allow this file to be sourced (function library) or invoked (RUN script).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
