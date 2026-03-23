#!/bin/bash
# Minimal bootstrap header for simple feature scripts
# Source this instead of feature-header.sh when your script only needs:
#   - OS validation (DEBIAN_VERSION, UBUNTU_VERSION)
#   - User identity (USERNAME, USER_UID, USER_GID, WORKING_DIR)
#   - Logging functions (log_message, log_error, log_feature_start, etc.)
#   - Bashrc helpers (write_bashrc_content)
#
# If your script also needs arch-utils (map_arch, map_arch_or_skip),
# cleanup-handler (register_cleanup), or feature-utils (create_symlink,
# create_secure_temp_dir), source feature-header.sh instead.
#
# See docs/architecture/god-modules.md for the full API contract.
#
# API Contract:
#   Exported vars: DEBIAN_VERSION, UBUNTU_VERSION, USERNAME, USER_UID,
#                  USER_GID, WORKING_DIR
#   Sub-modules:   os-validation.sh, user-env.sh, logging.sh, bashrc-helpers.sh
#   Include guard: _FEATURE_HEADER_BOOTSTRAP_LOADED

# Prevent multiple sourcing
if [ -n "${_FEATURE_HEADER_BOOTSTRAP_LOADED:-}" ]; then
    return 0
fi
_FEATURE_HEADER_BOOTSTRAP_LOADED=1

# ============================================================================
# Source Sub-Modules (dependency order)
# ============================================================================

# OS validation: Bash version check, Debian/Ubuntu detection
# shellcheck source=lib/base/os-validation.sh
if [ -f "/tmp/build-scripts/base/os-validation.sh" ]; then
    source "/tmp/build-scripts/base/os-validation.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/os-validation.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/os-validation.sh"
fi

# User identity: USERNAME, USER_UID, USER_GID, WORKING_DIR
# shellcheck source=lib/base/user-env.sh
if [ -f "/tmp/build-scripts/base/user-env.sh" ]; then
    source "/tmp/build-scripts/base/user-env.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/user-env.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/user-env.sh"
fi

# Logging support
# shellcheck source=lib/base/logging.sh
if [ -f /tmp/build-scripts/base/logging.sh ]; then
    source /tmp/build-scripts/base/logging.sh
fi

# Bashrc helper functions
# shellcheck source=lib/base/bashrc-helpers.sh
if [ -f /tmp/build-scripts/base/bashrc-helpers.sh ]; then
    source /tmp/build-scripts/base/bashrc-helpers.sh
fi

# Check that a prerequisite binary exists, or exit with a clear error.
# Usage: require_feature_binary "/usr/local/bin/mojo" "INCLUDE_MOJO"
require_feature_binary() {
    local binary_path="$1"
    local feature_name="$2"
    if [ ! -f "$binary_path" ]; then
        local binary_name
        binary_name=$(/usr/bin/basename "$binary_path")
        log_error "${binary_name} not found at ${binary_path}"
        log_error "The ${feature_name} feature must be enabled first"
        log_feature_end
        exit 1
    fi
}
