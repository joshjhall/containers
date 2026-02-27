#!/bin/bash
# Python build dependency cleanup for production builds
#
# Expected variables from parent script:
#   CLEANUP_BUILD_DEPS
#
# Source this file from python.sh after Python is compiled.

if [ "${CLEANUP_BUILD_DEPS}" = "true" ]; then
    log_message "Removing build dependencies (production build)..."

    # Mark runtime libraries as manually installed to prevent autoremove from removing them
    log_command "Marking runtime libraries as manually installed" \
        apt-mark manual \
            libbz2-1.0 \
            libffi8 \
            libgdbm6 \
            liblzma5 \
            libncurses6 \
            libncursesw6 \
            libreadline8 \
            libsqlite3-0 \
            libssl3 \
            zlib1g 2>/dev/null || true

    # Remove build dependencies we installed earlier
    # Note: We keep wget and ca-certificates as they may be needed for runtime operations
    # Build the package list conditionally (lzma/lzma-dev only exist on Debian 11-12)
    _remove_pkgs=(
        build-essential gdb lcov libbz2-dev libffi-dev libgdbm-dev
        liblzma-dev libncurses5-dev libreadline-dev libsqlite3-dev
        libssl-dev tk-dev uuid-dev zlib1g-dev
    )
    if ! is_debian_version 13; then
        _remove_pkgs+=(lzma lzma-dev)
    fi
    log_command "Removing build packages" \
        apt-get remove --purge -y "${_remove_pkgs[@]}" || true

    # Now safe to remove orphaned dependencies (runtime libs are marked manual)
    log_command "Removing orphaned dependencies" \
        apt-get autoremove -y

    log_command "Cleaning apt cache" \
        apt-get clean

    log_message "✓ Build dependencies removed successfully"
fi
