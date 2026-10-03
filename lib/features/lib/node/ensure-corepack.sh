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
#   The npm install is verified before it lands (#985). The Node tarball goes
#   through the 4-tier checksum system; this package gets the npm equivalent:
#   install into a scratch tree, `npm audit signatures` that tree, then install
#   globally FROM the audited directory — the same verify-then-install sequence
#   dev-tools uses for agnix (#814; see install-binary-tools.sh for the full
#   rationale). A registry signature rather than an inline sha512 keeps the
#   weekly auto-patch able to bump COREPACK_VERSION with no checksum to chase.
#
# Usage:
#   source /tmp/build-scripts/features/lib/npm-audit-verdict.sh
#   source /tmp/build-scripts/features/lib/node/ensure-corepack.sh
#   ensure_corepack || exit 1
#
# Requirements:
#   - node and npm on PATH (the extracted tarball)
#   - log_message / log_command / log_error (feature-header.sh)
#   - create_secure_temp_dir (feature-utils.sh)
#   - npm_audit_verdict (features/lib/npm-audit-verdict.sh)
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

    # An exact X.Y.Z only: a dist-tag or range would reach npm verbatim and
    # defeat the pin (NODE_VERSION gets the same check via validate_node_version).
    if ! [[ "$COREPACK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "COREPACK_VERSION must be an exact X.Y.Z version, got '${COREPACK_VERSION}'"
        return 1
    fi

    log_message "corepack not bundled with this Node.js (removed in 25+); installing corepack@${COREPACK_VERSION} from npm"

    local scratch
    if ! scratch=$(create_secure_temp_dir) || [ -z "$scratch" ] || [ ! -d "$scratch" ]; then
        log_error "Could not create a scratch directory to verify corepack@${COREPACK_VERSION}"
        return 1
    fi

    local rc=0
    _install_verified_corepack "$scratch" || rc=$?
    command rm -rf "$scratch"
    [ "$rc" -eq 0 ] || return 1

    # npm can exit 0 yet link the binary outside PATH (e.g. a non-default
    # prefix), which would only surface later as a bare exit 127.
    hash -r
    if ! command -v corepack >/dev/null 2>&1; then
        log_error "corepack@${COREPACK_VERSION} installed but 'corepack' is not on PATH"
        log_error "npm global prefix: $(npm config get prefix 2>/dev/null || echo unknown)"
        return 1
    fi

    log_message "✓ corepack $(corepack --version 2>/dev/null || echo "${COREPACK_VERSION}") installed (registry signature verified)"
    return 0
}

# _install_verified_corepack SCRATCH - audit, then install, corepack@COREPACK_VERSION
#
# Every npm call gets `--cache` inside SCRATCH. node.sh only moves npm's cache
# to /cache after this runs, so npm's default (/root/.npm) would otherwise
# leave the downloaded tarball in the image layer. The caller removes SCRATCH.
_install_verified_corepack() {
    local scratch="$1"
    local cache="${scratch}/.npm-cache"
    local audit_json audit_err="${scratch}/audit.stderr" verdict

    # corepack ships no lifecycle scripts; --ignore-scripts keeps it that way,
    # and it is what lets the audit run before any of the package's code does.
    if ! log_command "Fetching corepack@${COREPACK_VERSION} for verification" \
        npm install --prefix "$scratch" --cache "$cache" --ignore-scripts \
        "corepack@${COREPACK_VERSION}"; then
        log_error "Failed to fetch corepack@${COREPACK_VERSION}"
        return 1
    fi

    # The verdict comes from the JSON on stdout, never from the exit code,
    # which is non-zero for both a mismatch and an audit that could not run.
    audit_json=$(cd "$scratch" &&
        npm audit signatures --json --cache "$cache" 2>"$audit_err" || true)
    verdict=$(npm_audit_verdict "$audit_json")

    case "$verdict" in
        install) ;;
        fatal)
            log_error "corepack signature verification FAILED for ${COREPACK_VERSION} — npm served a tarball that does not match its published registry signature. Refusing to install. Audit output: ${audit_json}"
            return 1
            ;;
        *)
            # Stricter than agnix, which skips an optional tool here: corepack
            # is required (yarn and pnpm hang off it), and installing bytes
            # nobody verified is the fallback this file refuses everywhere.
            log_error "corepack@${COREPACK_VERSION} signature could not be verified (the audit did not run — registry or network problem?). Refusing to install unverified. Audit stdout: ${audit_json:-<empty>}. Audit stderr: $(command head -c 500 "$audit_err" 2>/dev/null || true)"
            return 1
            ;;
    esac

    # Install the AUDITED BYTES, not a fresh resolve of the name: re-resolving
    # "corepack@X" would be a second fetch nobody verified. --install-links
    # copies the package in; without it npm 10 links the global entry back to
    # SCRATCH, which the caller deletes. corepack has no dependencies, so the
    # pack of this directory is the whole audited closure.
    if ! log_command "Installing verified corepack@${COREPACK_VERSION}" \
        npm install -g --cache "$cache" --ignore-scripts --install-links \
        "${scratch}/node_modules/corepack"; then
        log_error "Failed to install corepack@${COREPACK_VERSION}"
        return 1
    fi
}
