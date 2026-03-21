#!/bin/bash
# Standard header for feature scripts
# Source this at the beginning of each feature script to get consistent user handling
#
# This is a composition layer that sources the bootstrap header (os-validation,
# user-env, logging, bashrc-helpers) plus optional modules (arch-utils,
# cleanup-handler, feature-utils) in dependency order.
# See docs/architecture/god-modules.md for the full API contract.
#
# For simple features that only need the bootstrap layer, source
# feature-header-bootstrap.sh instead to reduce coupling.
#
# API Contract:
#   Exported vars: DEBIAN_VERSION, UBUNTU_VERSION, USERNAME, USER_UID,
#                  USER_GID, WORKING_DIR
#   Sub-modules:   feature-header-bootstrap.sh (os-validation, user-env,
#                  logging, bashrc-helpers), arch-utils.sh,
#                  cleanup-handler.sh, feature-utils.sh
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
# Bootstrap Layer (os-validation, user-env, logging, bashrc-helpers)
# ============================================================================

# shellcheck source=lib/base/feature-header-bootstrap.sh
if [ -f "/tmp/build-scripts/base/feature-header-bootstrap.sh" ]; then
    source "/tmp/build-scripts/base/feature-header-bootstrap.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/feature-header-bootstrap.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/feature-header-bootstrap.sh"
fi

# ============================================================================
# Optional Modules (arch-utils, cleanup-handler, feature-utils)
# ============================================================================

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
