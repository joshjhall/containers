#!/bin/bash
# OS validation and version detection
# Validates Bash version, Debian/Ubuntu base, and exports version variables.
#
# Exports: DEBIAN_VERSION (Debian only), UBUNTU_VERSION (Ubuntu only)
# Include guard: _OS_VALIDATION_LOADED

# Prevent multiple sourcing
if [ -n "${_OS_VALIDATION_LOADED:-}" ]; then
    return 0
fi
_OS_VALIDATION_LOADED=1

# Source shared Debian version detection
# shellcheck source=lib/base/debian-version.sh
if [ -f "/tmp/build-scripts/base/debian-version.sh" ]; then
    source "/tmp/build-scripts/base/debian-version.sh"
elif [ -f "$(dirname "${BASH_SOURCE[0]}")/debian-version.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/debian-version.sh"
fi

# ============================================================================
# Bash Version Check
# ============================================================================

if [ -z "${BASH_VERSION}" ]; then
    echo "Error: This script requires Bash, but appears to be running in a different shell"
    exit 1
fi

BASH_MAJOR_VERSION="${BASH_VERSION%%.*}"
if [ "${BASH_MAJOR_VERSION}" -lt 5 ]; then
    echo "Error: This script requires Bash 5.0 or newer"
    echo "Current version: ${BASH_VERSION}"
    echo "Please use a base image with a newer Bash version"
    exit 1
fi

# ============================================================================
# OS Detection
# ============================================================================

if [ ! -f /etc/os-release ]; then
    echo "Error: Cannot determine OS version - /etc/os-release not found"
    exit 1
fi

# Source OS information
source /etc/os-release

# Validate OS type
if [ "${ID}" != "debian" ] && [ "${ID_LIKE}" != "debian" ]; then
    echo "Error: This script requires a Debian-based system"
    echo "Current OS: ${ID} ${VERSION_ID}"
    echo "These scripts use apt package manager and Debian-specific configurations"
    exit 1
fi

# Detect Debian/Ubuntu version for logging and export for feature scripts
if [ "${ID}" = "debian" ]; then
    DEBIAN_VERSION="$(get_debian_major_version)"
    export DEBIAN_VERSION
    echo "Detected Debian ${VERSION_ID} (${VERSION_CODENAME:-unknown})"

    # Note: This build system supports Debian 11 (Bullseye), 12 (Bookworm), and 13 (Trixie)
    # Version-specific package handling is done in apt-utils.sh using apt_install_conditional
elif [ "${ID}" = "ubuntu" ]; then
    UBUNTU_VERSION="${VERSION_ID%%.*}"
    export UBUNTU_VERSION
    echo "Detected Ubuntu ${VERSION_ID}"

    # Note: Ubuntu 20.04+ is supported. Some features use version detection for compatibility
fi
