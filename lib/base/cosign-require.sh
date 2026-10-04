#!/bin/bash
# Cosign Availability Guard
#
# The docker.sh and kubernetes.sh features both use cosign (Sigstore) to
# verify binaries and container images. Neither installs it: cosign is a base
# tool, installed unconditionally by lib/base/setup.sh at the pinned
# COSIGN_VERSION before any feature script runs. This helper asserts that the
# base install actually happened — and that PATH resolves `cosign` to that
# install at /usr/local/bin/cosign, not to some earlier-on-PATH substitute —
# and fails the feature build loudly if not.
#
# Why the resolved path is pinned (#940):
#   setup.sh's install is checksum-verified; any other cosign is not. Accepting
#   whatever `command -v cosign` returns would let a binary from a compromised
#   or misconfigured base image (or a future build step) perform Sigstore
#   verification for docker.sh/kubernetes.sh unchecked.
#
# Why there is only one cosign (#935):
#   This file used to download and dpkg-install a second, separately pinned
#   cosign .deb. That download was dead code — setup.sh puts cosign on
#   /usr/local/bin (first on PATH) at Dockerfile stage `base`, long before
#   the feature steps, so the old `command -v cosign` guard short-circuited
#   every time. The second pin only ever drifted: it was frozen at 3.0.2
#   while the tracked COSIGN_VERSION advanced, and it was invisible to
#   bin/check-versions.sh, so the weekly auto-patch could not bump it.
#
#   Keeping one cosign also keeps .trivyignore honest. Suppressions there are
#   bare CVE IDs, which are GLOBAL rather than per-binary — a second cosign
#   would silently inherit an entry whose unreachability evidence was only
#   ever established against the binary setup.sh ships.
#
# Dependencies (must be sourced before this file):
#   - feature-header.sh (log_message, log_error)
#
# Usage:
#   source /tmp/build-scripts/base/cosign-require.sh
#   require_cosign

# Prevent multiple sourcing
if [ -n "${_COSIGN_REQUIRE_LOADED:-}" ]; then
    return 0
fi
_COSIGN_REQUIRE_LOADED=1

# Where lib/base/setup.sh installs the checksum-verified cosign. Assigned
# unconditionally (not ${VAR:-default}) so the build environment cannot widen
# the pin; unit tests reassign it after sourcing.
_COSIGN_BASE_PATH="/usr/local/bin/cosign"

# Source export utilities
# shellcheck source=lib/shared/export-utils.sh
if [ -f "/tmp/build-scripts/shared/export-utils.sh" ]; then
    source "/tmp/build-scripts/shared/export-utils.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../shared/export-utils.sh"
fi

# ============================================================================
# Cosign Availability
# ============================================================================

# require_cosign - Assert PATH resolves cosign to the base install
#
# Returns 0 and logs the resolved path when `cosign` resolves to
# $_COSIGN_BASE_PATH. Returns 1 with an actionable error when cosign is missing
# (lib/base/setup.sh did not run or its install regressed) or resolves anywhere
# else (an unverified substitute shadows the base install, #940) — either would
# silently downgrade Sigstore verification in the calling feature.
require_cosign() {
    if ! command -v cosign >/dev/null 2>&1; then
        log_error "cosign not found on PATH."
        log_error "cosign is installed by lib/base/setup.sh (COSIGN_VERSION) before"
        log_error "feature scripts run; its absence means the base stage did not"
        log_error "complete. Not installing a second copy here — see #935."
        return 1
    fi

    local resolved
    resolved="$(command -v cosign)"
    if [ "$resolved" != "$_COSIGN_BASE_PATH" ]; then
        log_error "cosign resolved to $resolved, not the base install at $_COSIGN_BASE_PATH."
        log_error "Something earlier on PATH shadows the checksum-verified cosign from"
        log_error "lib/base/setup.sh; refusing to verify signatures with it — see #940."
        return 1
    fi

    log_message "Using cosign from base install: $resolved"
    return 0
}

# Export function for use in other scripts
protected_export require_cosign
