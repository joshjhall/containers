#!/bin/bash
# Standard header for feature scripts
# Source this at the beginning of each feature script to get consistent user handling
#
# This is a composition layer that sources sub-modules in dependency order.
# See docs/architecture/god-modules.md for the full API contract.
#
# API Contract:
#   Exported vars: DEBIAN_VERSION, UBUNTU_VERSION, USERNAME, USER_UID,
#                  USER_GID, WORKING_DIR
#   Sub-modules:   os-validation.sh, user-env.sh, arch-utils.sh,
#                  cleanup-handler.sh, logging.sh, bashrc-helpers.sh,
#                  feature-utils.sh
#   Functions:     create_symlink(target, link_name, [description])
#                  create_secure_temp_dir() -> path
#   Include guard: _FEATURE_HEADER_LOADED

# Prevent multiple sourcing — re-executing re-registers traps and re-runs
# OS detection unnecessarily
if [ -n "${_FEATURE_HEADER_LOADED:-}" ]; then
    return 0
fi
_FEATURE_HEADER_LOADED=1

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

# Architecture mapping (map_arch, map_arch_or_skip)
# shellcheck source=lib/base/arch-utils.sh
if [ -f "/tmp/build-scripts/base/arch-utils.sh" ]; then
    source "/tmp/build-scripts/base/arch-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/arch-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/arch-utils.sh"
fi

# Cleanup handler (cleanup_on_interrupt, register_cleanup, unregister_cleanup)
# shellcheck source=lib/base/cleanup-handler.sh
if [ -f "/tmp/build-scripts/base/cleanup-handler.sh" ]; then
    source "/tmp/build-scripts/base/cleanup-handler.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/cleanup-handler.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/cleanup-handler.sh"
fi

# Feature utilities (create_symlink, create_secure_temp_dir)
# shellcheck source=lib/base/feature-utils.sh
if [ -f "/tmp/build-scripts/base/feature-utils.sh" ]; then
    source "/tmp/build-scripts/base/feature-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/feature-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/feature-utils.sh"
fi
