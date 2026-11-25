#!/bin/bash
# R Statistical Computing Environment - Version-specific Installation
#
# Description:
#   Installs a specific version of R statistical computing environment.
#   Uses R-project repositories to enable version selection.
#
# Features:
#   - Specific R version installation
#   - R base system and development tools
#   - Common build dependencies for R packages
#   - Helper functions for package management
#   - RStudio Server compatible environment
#
# Environment Variables:
#   - R_VERSION: Version to install (e.g., 4.5.1)
#
# Supported Versions:
#   - 4.5.x (latest stable)
#   - 4.4.x (previous stable)
#   - 4.3.x (LTS)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Source retry utilities for network operations
source /tmp/build-scripts/base/retry-utils.sh

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh
source /tmp/build-scripts/base/cache-utils.sh

# ============================================================================
# Version Configuration
# ============================================================================
R_VERSION="${R_VERSION:-4.5.3}"

# Validate R version format to prevent shell injection
validate_r_version "$R_VERSION" || {
    log_error "Build failed due to invalid R_VERSION"
    exit 1
}

# Extract major version for repository (R 4.x uses cran40)
R_VERSION_MAJOR=$(echo "${R_VERSION}" | command cut -d. -f1)
R_VERSION_SHORT="${R_VERSION_MAJOR}0"

# ============================================================================
# Posit Package Manager (PPM) binary repository
# ============================================================================
# CRAN ships R packages as source by default, so install.packages() compiles
# from source — the cold cost that blew the r-dev CI build budget (#531).
# PPM serves prebuilt binary packages for Debian 11/12/13 via its
# __linux__/<codename>/<snapshot> path; install.packages() untars them with no
# compile. Pin a dated snapshot for reproducibility. Both the build scripts and
# the runtime R config (Renviron.site + Rprofile.site) read R_PPM_REPO so user
# install.packages() also gets binaries. Override either var at build time.
# VERSION_CODENAME comes from /etc/os-release (sourced by feature-header.sh).
#
# NOTE: PPM Linux binaries are x86_64 only. On aarch64/arm64 PPM transparently
# serves source, so install.packages() still compiles — which is why r-dev's
# apt build-dependency set is kept as a safety net. The PR-tier CI cell that
# this targets is amd64 (debian:trixie x amd64, #408), so it gets binaries.
R_PPM_SNAPSHOT="${R_PPM_SNAPSHOT:-2026-06-02}"
R_PPM_REPO="${R_PPM_REPO:-https://packagemanager.posit.co/cran/__linux__/${VERSION_CODENAME}/${R_PPM_SNAPSHOT}}"

# Start logging
log_feature_start "R" "${R_VERSION}"

# ============================================================================
# Build Dependency Cleanup Strategy
# ============================================================================
# Determine if we should cleanup build dependencies after installation
# Only cleanup if neither dev-tools nor r-dev is enabled
CLEANUP_BUILD_DEPS="false"
if [ "${INCLUDE_DEV_TOOLS:-false}" != "true" ] && [ "${INCLUDE_R_DEV:-false}" != "true" ]; then
    CLEANUP_BUILD_DEPS="true"
    log_message "📦 Production build detected - build dependencies will be removed after installation"
fi

# ============================================================================
# R Installation from CRAN Repository
# ============================================================================
log_message "Setting up R repository..."

# Install dependencies for adding repositories
log_message "Installing repository dependencies..."

# Update package lists with retry logic
apt_update

# Install repository dependencies with retry logic
apt_install \
    gnupg \
    dirmngr \
    ca-certificates \
    wget

# Create gnupg directory
log_command "Creating gnupg directory" \
    mkdir -p /root/.gnupg
log_command "Setting gnupg permissions" \
    chmod 700 /root/.gnupg

# Add R CRAN repository key (using new keyring method)
log_message "Adding R repository key..."

# CRAN's Debian repo is signed by Johannes Ranke's key. CRAN no longer serves
# it as a file (marutter_pubkey.asc is 404), so fetch it by fingerprint from
# the Ubuntu keyserver over HTTPS, falling back to the HKP protocol, then
# verify the fingerprint of whatever landed in the keyring (#1666).
# Fingerprint in spaced groups (as docker.sh/aws.sh do); spaces stripped below.
R_CRAN_KEY_FINGERPRINT="95C0 FAF3 8DB3 CCAD 0C08  0A7B DC78 B2DD EABC 47B7"
R_CRAN_KEY_FINGERPRINT="${R_CRAN_KEY_FINGERPRINT// /}"
R_KEYRING="/usr/share/keyrings/r-project-archive-keyring.gpg"

log_message "Downloading R repository key ${R_CRAN_KEY_FINGERPRINT} from keyserver"
if retry_with_backoff bash -c "command wget -qO- 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${R_CRAN_KEY_FINGERPRINT}' | \
        command sed -n '/-----BEGIN/,/-----END/p' | \
        gpg --dearmor > '${R_KEYRING}' && test -s '${R_KEYRING}'"; then
    log_message "Key downloaded from keyserver (HTTPS)"
else
    log_warning "HTTPS key download failed, trying gpg --recv-keys..."
    # gpg --export emits binary keyring format already — no --dearmor
    log_command "Getting key from keyserver" \
        bash -c "gpg --keyserver keyserver.ubuntu.com --recv-keys '${R_CRAN_KEY_FINGERPRINT}' && \
        gpg --export '${R_CRAN_KEY_FINGERPRINT}' > '${R_KEYRING}'"
fi

# Verify the keyring contains the expected signing key (fails on a missing,
# empty, or wrong-key keyring)
_r_key_fingerprints=$(gpg --show-keys --with-colons "${R_KEYRING}" 2>/dev/null |
    command awk -F: '$1 == "fpr" {print $10}' || true)
if ! printf '%s\n' "$_r_key_fingerprints" | command grep -qx "${R_CRAN_KEY_FINGERPRINT}"; then
    log_error "R repository keyring missing or does not contain key ${R_CRAN_KEY_FINGERPRINT}"
    log_feature_end
    exit 1
fi

# Add R repository for Debian with signed-by option
# VERSION_CODENAME is available from /etc/os-release (sourced by feature-header.sh)
log_command "Adding R repository" \
    bash -c "echo 'deb [signed-by=/usr/share/keyrings/r-project-archive-keyring.gpg] https://cloud.r-project.org/bin/linux/debian ${VERSION_CODENAME}-cran${R_VERSION_SHORT}/' > /etc/apt/sources.list.d/r-cran.list"

# Update and install specific R version
# Update package lists with R repository
apt_update

# Install R with version pinning.
#
# Fail closed: if CRAN's Debian repo does not publish R_VERSION for this
# codename, abort with the versions it DOES publish. Never fall back to an
# unpinned r-base (CRAN latest or Debian's own build) — that silently ships a
# different R than the pin claims, which is how a 4.6.x pin produced R 4.5.3
# images (#1666). bin/check-versions.sh derives R "latest" from these same
# {codename}-cran40 listings so auto-patch can't pin an unpublished version.
log_message "Installing R ${R_VERSION} from CRAN (${VERSION_CODENAME}-cran${R_VERSION_SHORT})..."

_r_available=$(apt-cache madison r-base-core 2>/dev/null |
    command awk -F'|' '{gsub(/ /, "", $2); print $2}' || true)
if ! printf '%s\n' "$_r_available" | command grep -q "^${R_VERSION//./\\.}-"; then
    log_error "R_VERSION=${R_VERSION} is not published for ${VERSION_CODENAME} in ${VERSION_CODENAME}-cran${R_VERSION_SHORT}"
    log_error "Available r-base-core versions: $(printf '%s' "${_r_available:-<none>}" | command tr '\n' ' ')"
    log_error "Pin R_VERSION to an available version (see docs/reference/versions.md)"
    log_feature_end
    exit 1
fi

apt_install \
    r-base-core="${R_VERSION}-*" \
    r-base-dev="${R_VERSION}-*" \
    r-recommended="${R_VERSION}-*"

# ============================================================================
# Build Dependencies
# ============================================================================
log_message "Installing build dependencies for R packages"

# Install libraries commonly needed for R package compilation
log_message "Installing R package build dependencies..."
apt_install \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libcairo2-dev

# ============================================================================
# Cache and Path Configuration
# ============================================================================
log_message "Configuring R cache and paths"

# ALWAYS use /cache paths for consistency with other languages
# This will either use cache mount (faster rebuilds) or be created in the image
export R_HOME="/usr/lib/R" # System R installation
export R_LIBS_USER="/cache/r/library"
export R_CACHE_DIR="/cache/r"

# Create cache directories with correct ownership
log_message "Creating R cache directories..."
# Use shared utility for atomic directory creation with correct ownership
# Important: Create parent /cache/r directory first to ensure correct ownership
create_cache_directories "${R_CACHE_DIR}" "${R_LIBS_USER}" "${R_CACHE_DIR}/tmp"

log_message "R library path: ${R_LIBS_USER}"
log_message "R cache directory: ${R_CACHE_DIR}"

# ============================================================================
# Clean Up Build Dependencies (Production Builds Only)
# ============================================================================
if [ "${CLEANUP_BUILD_DEPS}" = "true" ]; then
    log_message "Removing build dependencies (production build)..."

    # Mark runtime libraries as manually installed to prevent autoremove from removing them
    log_command "Marking runtime libraries as manually installed" \
        apt-mark manual \
        libcurl4 \
        libxml2 \
        libfontconfig1 \
        libharfbuzz0b \
        libfribidi0 \
        libfreetype6 \
        libpng16-16 \
        libtiff6 \
        libjpeg62-turbo \
        libcairo2 \
        libssl3 2>/dev/null || true

    # Remove build dependencies for R package compilation
    # Note: We keep r-base-dev as some R packages may need it at runtime
    # We also keep ca-certificates, wget, gnupg, and dirmngr for runtime operations
    log_command "Removing R package build dependencies" \
        apt-get remove --purge -y \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        libfontconfig1-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        libfreetype6-dev \
        libpng-dev \
        libtiff5-dev \
        libjpeg-dev \
        libcairo2-dev || true # Don't fail if some packages aren't installed

    # Now safe to remove orphaned dependencies (runtime libs are marked manual)
    log_command "Removing orphaned dependencies" \
        apt-get autoremove -y

    log_command "Cleaning apt cache" \
        apt-get clean

    log_message "✓ Build dependencies removed successfully"
fi

# ============================================================================
# Create symlinks for R binaries
# ============================================================================
log_message "Creating R symlinks..."

# Find R installation directory
R_BIN_DIR="/usr/bin"

# Create /usr/local/bin symlinks for consistency with other languages
for cmd in R Rscript; do
    if [ -f "${R_BIN_DIR}/${cmd}" ]; then
        create_symlink "${R_BIN_DIR}/${cmd}" "/usr/local/bin/${cmd}" "${cmd} command"
    fi
done

# ============================================================================
# System-wide Environment Configuration
# ============================================================================
log_message "Configuring system-wide R environment..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Create system-wide R configuration (content in lib/bashrc/r-env.sh)
write_bashrc_content /etc/bashrc.d/40-r.sh "R environment configuration" \
    </tmp/build-scripts/features/lib/bashrc/r-env.sh

log_command "Setting R bashrc script permissions" \
    chmod +x /etc/bashrc.d/40-r.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up R aliases and helpers..."

# R aliases and helpers (content in lib/bashrc/r-aliases.sh)
write_bashrc_content /etc/bashrc.d/40-r.sh "R aliases and helpers" \
    </tmp/build-scripts/features/lib/bashrc/r-aliases.sh

# ============================================================================
# Global R Configuration
# ============================================================================
log_message "Creating global R configuration"

# Create system-wide Rprofile
log_command "Creating R config directory" \
    mkdir -p /etc/R
install -m 644 /tmp/build-scripts/features/lib/r/Rprofile.site \
    /etc/R/Rprofile.site

# Create system-wide Renviron
# R_PPM_REPO is read by Rprofile.site (and the r-dev install scripts) to serve
# prebuilt binary packages from Posit Package Manager instead of compiling from
# source. Unquoted heredoc so ${R_PPM_REPO} interpolates.
command cat >/etc/R/Renviron.site <<EOF
# System-wide R environment variables
R_LIBS_USER=/cache/r/library
R_LIBS_SITE=/cache/r/library
R_MAX_NUM_DLLS=150
R_INSTALL_STAGED=FALSE
TMPDIR=/cache/r/tmp
R_PPM_REPO=${R_PPM_REPO}
EOF

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating R startup script"

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

install -m 755 /tmp/build-scripts/features/lib/r/10-r-setup.sh \
    /etc/container/first-startup/10-r-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating R verification script..."

install -m 755 /tmp/build-scripts/features/lib/r/test-r.sh \
    /usr/local/bin/test-r

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying R installation..."

# Capture the full output rather than piping into `head -n 1`: under pipefail
# head's early exit SIGPIPEs R and fired a spurious "symlink not found" (#1666).
# Assert the installed version matches the pin — the build must not ship a
# different R than R_VERSION claims.
_r_version_line=$(/usr/local/bin/R --version 2>&1) || {
    log_error "/usr/local/bin/R --version failed"
    log_feature_end
    exit 1
}
_r_version_line=${_r_version_line%%$'\n'*}
log_message "Installed: ${_r_version_line}"
case "$_r_version_line" in
    "R version ${R_VERSION} "*) ;;
    *)
        log_error "Installed R does not match R_VERSION=${R_VERSION}: ${_r_version_line}"
        log_feature_end
        exit 1
        ;;
esac

log_command "Checking Rscript version" \
    /usr/local/bin/Rscript --version

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of R directories..."
log_command "Final ownership fix for R cache directories" \
    chown -R "${USER_UID}":"${USER_GID}" "${R_CACHE_DIR}" || true

# Log feature summary
# Export directory paths for feature summary (also defined in bashrc for runtime)
export R_CACHE_DIR="/cache/r"
export R_LIBS_SITE="/cache/r/library"
export R_LIBS_USER="/cache/r/library"
export R_PPM_REPO

log_feature_summary \
    --feature "R" \
    --version "${R_VERSION}" \
    --tools "R,Rscript" \
    --paths "${R_LIBS_USER},${R_LIBS_SITE},${R_CACHE_DIR}" \
    --env "R_LIBS_USER,R_LIBS_SITE,R_CACHE_DIR,R_VERSION,R_PPM_REPO" \
    --commands "R,Rscript,r-version,r-install-packages,r-update-packages,r-clean-cache" \
    --next-steps "Run 'test-r' to verify installation. Use 'R' for interactive console, 'Rscript' for scripts. Install packages with 'r-install-packages <pkg1> <pkg2>'."

# End logging
log_feature_end

log_feature_instructions "test-r" "r"
