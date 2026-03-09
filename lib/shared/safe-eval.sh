#!/bin/bash
# Shared safe_eval function for runtime use
#
# Safely evaluates command output with validation to mitigate command injection
# risks when using eval with tool initialization commands (e.g., rbenv init,
# direnv hook, zoxide init).
#
# Dependencies:
#   log_warning, log_error from shared/logging.sh (must be sourced first)

# Prevent multiple sourcing
if [ -n "${_SHARED_SAFE_EVAL_LOADED:-}" ]; then
    return 0
fi
_SHARED_SAFE_EVAL_LOADED=1

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/export-utils.sh"
elif [ -f "/opt/container-runtime/shared/export-utils.sh" ]; then
    source "/opt/container-runtime/shared/export-utils.sh"
fi

# ============================================================================
# safe_eval - Safely evaluate command output with validation
#
# Arguments:
#   $1 - Description of command (e.g., "zoxide init bash")
#   $@ - The command to execute
#
# Returns:
#   0 - Command executed successfully
#   1 - Command failed or suspicious output detected
#
# Example:
#   safe_eval "zoxide init bash" zoxide init bash
#   safe_eval "direnv hook" direnv hook bash
# ============================================================================
safe_eval() {
    local description="$1"
    shift
    local output
    local exit_code=0

    # Try to execute the command and capture output
    if ! output=$("$@" 2>/dev/null); then
        log_warning "Failed to initialize $description"
        return 1
    fi

    # Blocklist of dangerous patterns — defined once for maintainability.
    # Uses a blocklist (not allowlist) because inputs are complex, multi-line
    # shell code from tools like zoxide/direnv that changes between versions.
    # Inputs are NOT user-controlled; this is defense-in-depth against supply
    # chain compromise.
    local _SAFE_EVAL_BLOCKLIST='rm -rf|curl.*bash|\bwget\b|;\s*rm|\$\(.*rm|exec\s+[^$]|/bin/sh.*-c|bash.*-c.*http|\bmkfifo\b|\bnc\b|\bncat\b|\bchmod\b.*\+s|\bpython[23]?\b.*-c|\bperl\b.*-e'

    # Use 'command grep' to bypass any aliases (e.g., grep='rg' from dev-tools)
    if echo "$output" | command grep -qE "$_SAFE_EVAL_BLOCKLIST"; then
        log_error "SECURITY: Suspicious output from $description, skipping initialization"
        log_error "This may indicate a compromised tool or supply chain attack"
        return 1
    fi

    # Output looks safe, evaluate it
    # NOTE: eval is intentional here — this function exists specifically to
    # safely wrap eval with blocklist validation for tool init commands
    # (zoxide init, direnv hook, etc.)
    eval "$output" || exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_warning "$description initialization completed with non-zero exit code: $exit_code"
        return $exit_code
    fi

    return 0
}

# Export function
protected_export safe_eval
