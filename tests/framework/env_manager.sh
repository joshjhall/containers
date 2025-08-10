#!/usr/bin/env bash
# Test Environment Manager
# Version: 2.0.0
#
# Provides centralized management of environment state during testing:
# - Git configuration (user.name, user.email, signing settings)
# - SSH environment (SSH_AUTH_SOCK, SSH_AGENT_PID)
# - Environment variables
# - File system state (HOME directory, SSH keys)
#
# Ensures tests can safely modify environment and restore original state

# Initialize buildkit if needed
if [[ -z "${BUILDKIT_LIB_LOADER:-}" ]]; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/buildkit.sh"
fi

# Import dependencies
import_once core.source_guard
import_once core.logging
import_once core.validation
import_once core.sanitization

# Global state storage
declare -gA TEST_ENV_ORIGINAL_GIT
declare -gA TEST_ENV_ORIGINAL_SSH
declare -gA TEST_ENV_ORIGINAL_VARS
declare -g TEST_ENV_ORIGINAL_HOME=""
declare -g TEST_ENV_MANAGER_INITIALIZED=0

# Initialize environment manager
#
# Sets up tracking for environment state that may be modified during tests
#
# Returns:
#   0 on success
#   1 on failure
init_env_manager() {
    if [ "$TEST_ENV_MANAGER_INITIALIZED" -eq 1 ]; then
        log_debug "Environment manager already initialized"
        return 0
    fi

    log_debug "Initializing test environment manager"

    # Clear state arrays
    TEST_ENV_ORIGINAL_GIT=()
    TEST_ENV_ORIGINAL_SSH=()
    TEST_ENV_ORIGINAL_VARS=()

    TEST_ENV_MANAGER_INITIALIZED=1
    return 0
}

# Save git configuration state
#
# Captures current git global configuration for later restoration
#
# Returns:
#   0 always
save_git_config() {
    init_env_manager

    log_debug "Saving git configuration state"

    # Save git user configuration
    TEST_ENV_ORIGINAL_GIT[user_name]=$(git config --global user.name 2>/dev/null || echo "")
    TEST_ENV_ORIGINAL_GIT[user_email]=$(git config --global user.email 2>/dev/null || echo "")

    # Save git signing configuration
    TEST_ENV_ORIGINAL_GIT[signing_key]=$(git config --global user.signingkey 2>/dev/null || echo "")
    TEST_ENV_ORIGINAL_GIT[commit_gpgsign]=$(git config --global commit.gpgsign 2>/dev/null || echo "")
    TEST_ENV_ORIGINAL_GIT[gpg_format]=$(git config --global gpg.format 2>/dev/null || echo "")

    log_debug "Git configuration saved: name='${TEST_ENV_ORIGINAL_GIT[user_name]}', email='${TEST_ENV_ORIGINAL_GIT[user_email]}'"
    return 0
}

# Restore git configuration state
#
# Restores git global configuration to previously saved state
#
# Returns:
#   0 always
restore_git_config() {
    if [ "$TEST_ENV_MANAGER_INITIALIZED" -ne 1 ]; then
        log_warn "Environment manager not initialized, cannot restore git config"
        return 1
    fi

    log_debug "Restoring git configuration state"

    # Restore git user configuration
    if [ -n "${TEST_ENV_ORIGINAL_GIT[user_name]:-}" ]; then
        git config --global user.name "${TEST_ENV_ORIGINAL_GIT[user_name]}"
    else
        git config --global --unset user.name 2>/dev/null || true
    fi

    if [ -n "${TEST_ENV_ORIGINAL_GIT[user_email]:-}" ]; then
        git config --global user.email "${TEST_ENV_ORIGINAL_GIT[user_email]}"
    else
        git config --global --unset user.email 2>/dev/null || true
    fi

    # Restore git signing configuration
    if [ -n "${TEST_ENV_ORIGINAL_GIT[signing_key]:-}" ]; then
        git config --global user.signingkey "${TEST_ENV_ORIGINAL_GIT[signing_key]}"
    else
        git config --global --unset user.signingkey 2>/dev/null || true
    fi

    if [ -n "${TEST_ENV_ORIGINAL_GIT[commit_gpgsign]:-}" ]; then
        git config --global commit.gpgsign "${TEST_ENV_ORIGINAL_GIT[commit_gpgsign]}"
    else
        git config --global --unset commit.gpgsign 2>/dev/null || true
    fi

    if [ -n "${TEST_ENV_ORIGINAL_GIT[gpg_format]:-}" ]; then
        git config --global gpg.format "${TEST_ENV_ORIGINAL_GIT[gpg_format]}"
    else
        git config --global --unset gpg.format 2>/dev/null || true
    fi

    log_debug "Git configuration restored"
    return 0
}

# Save SSH environment state
#
# Captures current SSH agent environment for later restoration
#
# Returns:
#   0 always
save_ssh_env() {
    init_env_manager

    log_debug "Saving SSH environment state"

    TEST_ENV_ORIGINAL_SSH[auth_sock]="${SSH_AUTH_SOCK:-}"
    TEST_ENV_ORIGINAL_SSH[agent_pid]="${SSH_AGENT_PID:-}"

    log_debug "SSH environment saved: sock='${TEST_ENV_ORIGINAL_SSH[auth_sock]}', pid='${TEST_ENV_ORIGINAL_SSH[agent_pid]}'"
    return 0
}

# Restore SSH environment state
#
# Restores SSH agent environment to previously saved state
#
# Returns:
#   0 always
restore_ssh_env() {
    if [ "$TEST_ENV_MANAGER_INITIALIZED" -ne 1 ]; then
        log_warn "Environment manager not initialized, cannot restore SSH environment"
        return 1
    fi

    log_debug "Restoring SSH environment state"

    if [ -n "${TEST_ENV_ORIGINAL_SSH[auth_sock]:-}" ]; then
        export SSH_AUTH_SOCK="${TEST_ENV_ORIGINAL_SSH[auth_sock]}"
    else
        unset SSH_AUTH_SOCK 2>/dev/null || true
    fi

    if [ -n "${TEST_ENV_ORIGINAL_SSH[agent_pid]:-}" ]; then
        export SSH_AGENT_PID="${TEST_ENV_ORIGINAL_SSH[agent_pid]}"
    else
        unset SSH_AGENT_PID 2>/dev/null || true
    fi

    log_debug "SSH environment restored"
    return 0
}

# Save environment variable
#
# Captures current value of an environment variable for later restoration
#
# Arguments:
#   $1 - Variable name to save
#
# Returns:
#   0 on success
#   1 if variable name is invalid
save_env_var() {
    local var_name="$1"

    # Validate variable name
    if ! validate_env_var_name "$var_name"; then
        log_error "Invalid environment variable name: $var_name"
        return 1
    fi

    init_env_manager

    log_debug "Saving environment variable: $var_name"

    # Save current value (use indirect expansion)
    TEST_ENV_ORIGINAL_VARS["$var_name"]="${!var_name:-__UNSET__}"

    return 0
}

# Restore environment variable
#
# Restores environment variable to previously saved state
#
# Arguments:
#   $1 - Variable name to restore
#
# Returns:
#   0 on success
#   1 if variable name is invalid or not saved
restore_env_var() {
    local var_name="$1"

    # Validate variable name
    if ! validate_env_var_name "$var_name"; then
        log_error "Invalid environment variable name: $var_name"
        return 1
    fi

    if [ "$TEST_ENV_MANAGER_INITIALIZED" -ne 1 ]; then
        log_warn "Environment manager not initialized, cannot restore variable: $var_name"
        return 1
    fi

    if [ -z "${TEST_ENV_ORIGINAL_VARS[$var_name]+x}" ]; then
        log_warn "Variable not saved, cannot restore: $var_name"
        return 1
    fi

    log_debug "Restoring environment variable: $var_name"

    local saved_value="${TEST_ENV_ORIGINAL_VARS[$var_name]}"

    if [ "$saved_value" = "__UNSET__" ]; then
        unset "$var_name" 2>/dev/null || true
    else
        export "$var_name"="$saved_value"
    fi

    return 0
}

# Save HOME directory state
#
# Captures current HOME directory for later restoration
#
# Returns:
#   0 always
save_home_dir() {
    init_env_manager

    log_debug "Saving HOME directory state: $HOME"

    TEST_ENV_ORIGINAL_HOME="$HOME"
    return 0
}

# Restore HOME directory state
#
# Restores HOME directory to previously saved state
#
# Returns:
#   0 always
restore_home_dir() {
    if [ "$TEST_ENV_MANAGER_INITIALIZED" -ne 1 ]; then
        log_warn "Environment manager not initialized, cannot restore HOME directory"
        return 1
    fi

    if [ -z "$TEST_ENV_ORIGINAL_HOME" ]; then
        log_warn "HOME directory not saved, cannot restore"
        return 1
    fi

    log_debug "Restoring HOME directory: $TEST_ENV_ORIGINAL_HOME"

    export HOME="$TEST_ENV_ORIGINAL_HOME"
    return 0
}

# Save complete environment state
#
# Convenience function to save all tracked environment state
#
# Returns:
#   0 always
save_all_env() {
    log_debug "Saving complete environment state"

    save_git_config
    save_ssh_env
    save_home_dir

    # Save common environment variables that tests might modify
    save_env_var "PATH" 2>/dev/null || true
    save_env_var "USER" 2>/dev/null || true
    save_env_var "TERM" 2>/dev/null || true

    return 0
}

# Restore complete environment state
#
# Convenience function to restore all tracked environment state
#
# Returns:
#   0 always
restore_all_env() {
    log_debug "Restoring complete environment state"

    restore_git_config
    restore_ssh_env
    restore_home_dir

    # Restore common environment variables
    restore_env_var "PATH" 2>/dev/null || true
    restore_env_var "USER" 2>/dev/null || true
    restore_env_var "TERM" 2>/dev/null || true

    return 0
}

# Clean up environment manager
#
# Clears all saved state and resets the manager
#
# Returns:
#   0 always
cleanup_env_manager() {
    log_debug "Cleaning up environment manager"

    # Clear state arrays
    TEST_ENV_ORIGINAL_GIT=()
    TEST_ENV_ORIGINAL_SSH=()
    TEST_ENV_ORIGINAL_VARS=()
    TEST_ENV_ORIGINAL_HOME=""

    TEST_ENV_MANAGER_INITIALIZED=0
    return 0
}

# Export functions
export -f init_env_manager
export -f save_git_config restore_git_config
export -f save_ssh_env restore_ssh_env
export -f save_env_var restore_env_var
export -f save_home_dir restore_home_dir
export -f save_all_env restore_all_env
export -f cleanup_env_manager
