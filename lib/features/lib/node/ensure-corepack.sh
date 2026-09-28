#!/bin/bash
# Corepack provisioning for the Node.js feature
#
# Description:
#   Node.js release tarballs bundled corepack through 24.x; from 25 on they
#   ship only node, npm, and npx (#983). node.sh relies on corepack for the
#   yarn and pnpm shims, so when the extracted tarball has no corepack this
#   installs the pinned release from npm instead.
#
#   Detection is by presence, not by major version, so a bundled corepack is
#   always preferred and nothing here has to track which releases carry it.
#
# Usage:
#   source /tmp/build-scripts/features/lib/node/ensure-corepack.sh
#   ensure_corepack || exit 1
#
# Requirements:
#   - node and npm on PATH (the extracted tarball)
#   - log_message / log_command / log_error (feature-header.sh)
#
# Environment Variables:
#   COREPACK_VERSION - npm version to install when corepack is not bundled
#                      (pinned in node.sh; tracked by bin/check-versions.sh)

# ensure_corepack - make `corepack` resolvable, installing it if needed
#
# Returns 0 when corepack is on PATH afterwards, 1 otherwise. An install
# failure is a build failure: no fallback to an unpinned version.
ensure_corepack() {
    if command -v corepack >/dev/null 2>&1; then
        log_message "Using corepack bundled with Node.js"
        return 0
    fi

    if [ -z "${COREPACK_VERSION:-}" ]; then
        log_error "corepack is not bundled with this Node.js and COREPACK_VERSION is unset"
        return 1
    fi

    log_message "corepack not bundled with this Node.js (removed in 25+); installing corepack@${COREPACK_VERSION} from npm"
    # corepack ships no lifecycle scripts; --ignore-scripts keeps it that way
    # for a package that goes on to fetch every image's yarn and pnpm.
    if ! log_command "Installing corepack@${COREPACK_VERSION}" \
        npm install -g --ignore-scripts "corepack@${COREPACK_VERSION}"; then
        log_error "Failed to install corepack@${COREPACK_VERSION}"
        return 1
    fi

    # npm can exit 0 yet link the binary outside PATH (e.g. a non-default
    # prefix), which would only surface later as a bare exit 127.
    hash -r
    if ! command -v corepack >/dev/null 2>&1; then
        log_error "corepack@${COREPACK_VERSION} installed but 'corepack' is not on PATH"
        log_error "npm global prefix: $(npm config get prefix 2>/dev/null || echo unknown)"
        return 1
    fi

    log_message "✓ corepack $(corepack --version 2>/dev/null || echo "${COREPACK_VERSION}") installed"
    return 0
}
