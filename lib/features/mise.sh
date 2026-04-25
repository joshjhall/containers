#!/bin/bash
# Mise - Polyglot runtime version manager
#
# Description:
#   Installs mise (https://mise.jdx.dev) for per-project runtime version
#   management via .mise.toml / .tool-versions. Complements — rather than
#   replaces — the baked-in language features (INCLUDE_PYTHON, INCLUDE_NODE,
#   etc.): baked-in features give reproducible team baselines, while mise
#   floats runtime versions per project and supports on-demand installs of
#   less-common runtimes (bun, deno, zig, etc.).
#
# Architecture Support:
#   - amd64 (x86_64)
#   - arm64 (aarch64)
#
# Security Features:
#   - 4-tier checksum verification via verify_download_or_fail
#   - Pinned version via MISE_VERSION (auto-bumped by bin/check-versions.sh)
#
# Environment Variables (runtime):
#   - MISE_DATA_DIR: where mise installs runtimes (default /cache/mise)
#   - MISE_CACHE_DIR: mise download/build cache (default /cache/mise-cache)
#   - MISE_TRUSTED_CONFIG_PATHS: auto-trusted .mise.toml paths (default /workspace)
#
# Note:
#   Installing runtimes that compile from source (e.g. Python via mise) requires
#   INCLUDE_DEV_TOOLS=true for build toolchain availability.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header-bootstrap.sh

# Source retry + checksum utilities for secure binary downloads
source /tmp/build-scripts/base/retry-utils.sh
source /tmp/build-scripts/base/checksum-fetch.sh
source /tmp/build-scripts/base/download-verify.sh
source /tmp/build-scripts/base/checksum-verification.sh

# Source bashrc helpers for activation fragment install
source /tmp/build-scripts/base/bashrc-helpers.sh

# Version configuration
MISE_VERSION="${MISE_VERSION:-2026.4.20}"

log_feature_start "Mise" "${MISE_VERSION}"

# ============================================================================
# Architecture Detection
# ============================================================================
log_message "Detecting system architecture..."

ARCH=$(dpkg --print-architecture)
case "${ARCH}" in
    amd64)
        MISE_ARCH="x64"
        ;;
    arm64 | aarch64)
        MISE_ARCH="arm64"
        ;;
    *)
        log_error "Unsupported architecture: ${ARCH}"
        log_feature_end
        exit 1
        ;;
esac

MISE_FILENAME="mise-v${MISE_VERSION}-linux-${MISE_ARCH}.tar.gz"
MISE_URL="https://github.com/jdx/mise/releases/download/v${MISE_VERSION}/${MISE_FILENAME}"

# ============================================================================
# Download + Verify
# ============================================================================
log_message "Installing mise ${MISE_VERSION} for ${ARCH}..."

# Register Tier 3 fetcher for mise checksums (SHASUMS256.txt contains all assets)
_fetch_mise_checksum() {
    local _ver="$1"
    local _arch="$2"
    local _asset_arch="x64"
    [ "$_arch" = "arm64" ] && _asset_arch="arm64"
    local _fn="mise-v${_ver}-linux-${_asset_arch}.tar.gz"
    local _url="https://github.com/jdx/mise/releases/download/v${_ver}/SHASUMS256.txt"
    fetch_github_checksums_txt "$_url" "$_fn" 2>/dev/null
}
register_tool_checksum_fetcher "mise" "_fetch_mise_checksum"

BUILD_TEMP=$(create_secure_temp_dir)
cd "${BUILD_TEMP}"

log_message "Downloading mise from ${MISE_URL}..."
if ! command curl -L -f --retry 8 --retry-delay 10 --retry-all-errors --progress-bar -o "mise.tar.gz" "${MISE_URL}"; then
    log_error "Failed to download mise ${MISE_VERSION}"
    cd /
    rm -rf "${BUILD_TEMP}"
    log_feature_end
    exit 1
fi

# Run 4-tier verification
verify_download_or_fail "tool" "mise" "${MISE_VERSION}" "mise.tar.gz" "${ARCH}" || {
    cd /
    rm -rf "${BUILD_TEMP}"
    log_feature_end
    exit 1
}

# Extract — upstream tarball layout is mise/bin/mise
log_command "Extracting mise archive" \
    tar -xzf mise.tar.gz

if [ ! -x "${BUILD_TEMP}/mise/bin/mise" ]; then
    log_error "Expected binary at mise/bin/mise not found after extract"
    cd /
    rm -rf "${BUILD_TEMP}"
    log_feature_end
    exit 1
fi

install -m 755 "${BUILD_TEMP}/mise/bin/mise" /usr/local/bin/mise
cd /
rm -rf "${BUILD_TEMP}"

# ============================================================================
# Cache Directories
# ============================================================================
log_message "Configuring mise cache directories..."

export MISE_DATA_DIR="/cache/mise"
export MISE_CACHE_DIR="/cache/mise-cache"

mkdir -p "${MISE_DATA_DIR}" "${MISE_CACHE_DIR}"
chown -R "${USER_UID}:${USER_GID}" "${MISE_DATA_DIR}" "${MISE_CACHE_DIR}"

log_message "  MISE_DATA_DIR: ${MISE_DATA_DIR}"
log_message "  MISE_CACHE_DIR: ${MISE_CACHE_DIR}"

# ============================================================================
# Shell Activation
# ============================================================================
# Numbered 70- so it loads after language env fragments in the 50- range
# (Python, Node, Go, etc.) and before dev-tools at 80-. This lets mise shims
# layer on top of baked-in runtimes when a project has a .mise.toml.
log_message "Installing mise activation fragment..."

write_bashrc_content /etc/bashrc.d/70-mise.sh "Mise activation" \
    </tmp/build-scripts/features/lib/bashrc/mise.sh
chmod +x /etc/bashrc.d/70-mise.sh

# ============================================================================
# Verification
# ============================================================================
log_message "Verifying mise installation..."

if mise --version >/dev/null 2>&1; then
    MISE_VER=$(mise --version 2>&1 | command head -1)
    log_message "  ${MISE_VER}"
else
    log_error "mise installation verification failed"
    log_feature_end
    exit 1
fi

# ============================================================================
# Feature Summary
# ============================================================================

log_feature_summary \
    --feature "Mise" \
    --version "${MISE_VERSION}" \
    --tools "mise" \
    --paths "/usr/local/bin/mise,${MISE_DATA_DIR},${MISE_CACHE_DIR},/etc/bashrc.d/70-mise.sh" \
    --env "MISE_DATA_DIR,MISE_CACHE_DIR,MISE_TRUSTED_CONFIG_PATHS" \
    --next-steps "Drop a .mise.toml in your project and run 'mise install'. Compile-from-source runtimes require INCLUDE_DEV_TOOLS=true."

log_feature_end
