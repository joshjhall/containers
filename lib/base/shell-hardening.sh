#!/usr/bin/env bash
# Shell Hardening Script
# Version: 1.0.0
#
# Description:
#   Hardens the shell environment by restricting available shells and
#   setting nologin for service users in production mode.
#
# Usage:
#   Called from Dockerfile during base setup
#
# Environment Variables:
#   RESTRICT_SHELLS    - Restrict /etc/shells to bash only (default: true)
#   PRODUCTION_MODE    - Enable production hardening (default: false)
#
# Compliance Coverage:
#   - CIS Docker Benchmark 4.1: Container user management
#   - NIST 800-53 AC-6: Least privilege
#   - PCI DSS 2.2.4: Remove unnecessary functionality
#   - FedRAMP CM-7: Least functionality

set -eo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Default values (can be overridden by build args)
RESTRICT_SHELLS="${RESTRICT_SHELLS:-true}"
PRODUCTION_MODE="${PRODUCTION_MODE:-false}"

# Service users to set nologin (in production mode)
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

# ============================================================================
# Functions
# ============================================================================

log_message() {
    echo "  [shell-hardening] $*"
}

log_warning() {
    echo "  [shell-hardening] WARNING: $*" >&2
}

# Restrict /etc/shells to bash only
restrict_shells() {
    if [ "$RESTRICT_SHELLS" != "true" ]; then
        log_message "Shell restriction disabled"
        return 0
    fi

    log_message "Restricting /etc/shells to bash only..."

    # Backup original
    if [ -f /etc/shells ]; then
        cp /etc/shells /etc/shells.bak
    fi

    # Create new restricted shells file
    cat > /etc/shells << 'EOF'
# /etc/shells: valid login shells
# Restricted for security - only bash allowed
# See CIS Docker Benchmark 4.1, NIST 800-53 AC-6
/bin/bash
/usr/bin/bash
EOF

    # Verify bash exists
    if [ ! -x /bin/bash ] && [ ! -x /usr/bin/bash ]; then
        log_warning "bash not found, restoring original /etc/shells"
        if [ -f /etc/shells.bak ]; then
            mv /etc/shells.bak /etc/shells
        fi
        return 1
    fi

    # Remove backup
    rm -f /etc/shells.bak

    log_message "Restricted /etc/shells to bash only"
    return 0
}

# Set nologin for service users (production mode only)
harden_service_users() {
    if [ "$PRODUCTION_MODE" != "true" ]; then
        log_message "Production mode disabled, keeping service user shells"
        return 0
    fi

    log_message "Setting nologin for service users (production mode)..."

    local hardened_count=0
    local nologin_shell="/usr/sbin/nologin"

    # Ensure nologin exists
    if [ ! -x "$nologin_shell" ]; then
        if [ -x /sbin/nologin ]; then
            nologin_shell="/sbin/nologin"
        else
            log_warning "nologin not found, skipping service user hardening"
            return 1
        fi
    fi

    for user in "${SERVICE_USERS[@]}"; do
        if id "$user" &>/dev/null; then
            # Get current shell
            current_shell=$(getent passwd "$user" | cut -d: -f7)

            # Skip if already nologin
            if [[ "$current_shell" == */nologin ]] || [[ "$current_shell" == */false ]]; then
                continue
            fi

            # Set nologin
            if usermod -s "$nologin_shell" "$user" 2>/dev/null; then
                hardened_count=$((hardened_count + 1))
            fi
        fi
    done

    log_message "Set nologin for $hardened_count service users"
    return 0
}

# Verify hardening was applied
verify_hardening() {
    local issues=0

    # Check /etc/shells
    if [ "$RESTRICT_SHELLS" = "true" ]; then
        local shell_count
        shell_count=$(grep -c "^/" /etc/shells 2>/dev/null || echo 0)
        if [ "$shell_count" -gt 2 ]; then
            log_warning "More than 2 shells in /etc/shells: $shell_count"
            issues=$((issues + 1))
        fi
    fi

    # Check service users in production mode
    if [ "$PRODUCTION_MODE" = "true" ]; then
        for user in "${SERVICE_USERS[@]}"; do
            if id "$user" &>/dev/null; then
                current_shell=$(getent passwd "$user" | cut -d: -f7)
                if [[ "$current_shell" != */nologin ]] && [[ "$current_shell" != */false ]]; then
                    log_warning "Service user $user has shell: $current_shell"
                    issues=$((issues + 1))
                fi
            fi
        done
    fi

    if [ "$issues" -eq 0 ]; then
        log_message "Shell hardening verification passed"
    else
        log_warning "Shell hardening verification found $issues issues"
    fi

    return 0
}

# Print summary
print_summary() {
    echo ""
    log_message "Shell Hardening Summary:"
    log_message "  RESTRICT_SHELLS: $RESTRICT_SHELLS"
    log_message "  PRODUCTION_MODE: $PRODUCTION_MODE"

    if [ "$RESTRICT_SHELLS" = "true" ]; then
        log_message "  Allowed shells: /bin/bash, /usr/bin/bash"
    fi

    if [ "$PRODUCTION_MODE" = "true" ]; then
        log_message "  Service users: nologin"
    fi
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo "=== Applying shell hardening ==="

    # Apply hardening measures
    restrict_shells
    harden_service_users

    # Verify and summarize
    verify_hardening
    print_summary

    echo "=== Shell hardening complete ==="
}

main "$@"
