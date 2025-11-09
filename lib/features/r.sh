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

# Source version validation utilities
source /tmp/build-scripts/base/version-validation.sh

# ============================================================================
# Version Configuration
# ============================================================================
R_VERSION="${R_VERSION:-4.5.1}"

# Validate R version format to prevent shell injection
validate_r_version "$R_VERSION" || {
    log_error "Build failed due to invalid R_VERSION"
    exit 1
}

# Extract major version for repository (R 4.x uses cran40)
R_VERSION_MAJOR=$(echo "${R_VERSION}" | cut -d. -f1)
R_VERSION_SHORT="${R_VERSION_MAJOR}0"

# Start logging
log_feature_start "R" "${R_VERSION}"

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

# Method 1: Try to download the key directly from CRAN
if log_command "Downloading R repository key from CRAN" \
    bash -c "wget -qO- https://cloud.r-project.org/bin/linux/debian/marutter_pubkey.asc 2>/dev/null | gpg --dearmor > /usr/share/keyrings/r-project-archive-keyring.gpg 2>/dev/null"; then
    log_message "Key downloaded from CRAN"
else
    log_warning "CRAN key failed, trying keyserver..."
    # Method 2: Get key from keyserver using the Johannes Ranke key
    if log_command "Getting key from keyserver" \
        bash -c "gpg --keyserver keyserver.ubuntu.com --recv-keys '95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7' && \
        gpg --export '95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7' | gpg --dearmor > /usr/share/keyrings/r-project-archive-keyring.gpg"; then
        log_message "Key obtained from keyserver"
    else
        log_warning "Keyserver failed, trying direct download..."
        # Method 3: Direct download from keyserver
        log_command "Direct download from keyserver" \
            bash -c "wget -O- 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7' | \
                sed -n '/-----BEGIN/,/-----END/p' | \
                gpg --dearmor > /usr/share/keyrings/r-project-archive-keyring.gpg"
    fi
fi

# Verify we have a keyring file
if [ ! -f /usr/share/keyrings/r-project-archive-keyring.gpg ]; then
    log_error "Failed to create R keyring"
    log_feature_end
    exit 1
fi

# Add R repository for Debian with signed-by option (dynamically detect codename)
log_command "Adding R repository" \
    bash -c "echo 'deb [signed-by=/usr/share/keyrings/r-project-archive-keyring.gpg] https://cloud.r-project.org/bin/linux/debian $(. /etc/os-release && echo \"\$VERSION_CODENAME\")-cran${R_VERSION_SHORT}/' > /etc/apt/sources.list.d/r-cran.list"

# Update and install specific R version
# Update package lists with R repository
apt_update

# Install R with version pinning
log_message "Installing R packages..."
if apt-cache show r-base-core | grep -q "Version: ${R_VERSION}"; then
    # Install specific version if available
    log_message "Installing R version ${R_VERSION}..."
    if ! apt_install \
            r-base-core=${R_VERSION}-* \
            r-base-dev=${R_VERSION}-* \
            r-recommended=${R_VERSION}-*; then
        log_warning "Exact version ${R_VERSION} not found, installing latest available"
        log_message "Installing latest R version..."
        apt_install \
                r-base \
                r-base-dev \
                r-recommended
    fi
else
    log_warning "Version ${R_VERSION} not available, installing latest from repository"
    log_message "Installing latest R version from repository..."
    apt_install \
            r-base \
            r-base-dev \
            r-recommended
fi

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
export R_HOME="/usr/lib/R"  # System R installation
export R_LIBS_USER="/cache/r/library"
export R_CACHE_DIR="/cache/r"

# Create cache directories with correct ownership
log_message "Creating R cache directories..."
log_command "Creating R library directory" \
    mkdir -p "${R_LIBS_USER}"
log_command "Creating R temp directory" \
    mkdir -p "${R_CACHE_DIR}/tmp"

log_command "Setting R cache directory ownership" \
    chown -R ${USER_UID}:${USER_GID} "${R_CACHE_DIR}"

log_message "R library path: ${R_LIBS_USER}"
log_message "R cache directory: ${R_CACHE_DIR}"

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

# Create system-wide R configuration
write_bashrc_content /etc/bashrc.d/40-r.sh "R environment configuration" << 'R_BASHRC_EOF'
# ----------------------------------------------------------------------------
# R environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

# R environment configuration
export R_LIBS_USER="/cache/r/library"
export R_CACHE_DIR="/cache/r"

# Use cache directory for temporary files
export TMPDIR="${R_CACHE_DIR}/tmp"

# R package installation settings
export R_INSTALL_STAGED=FALSE  # Avoid permission issues
export R_LIBS_SITE="${R_LIBS_USER}"

R_BASHRC_EOF

log_command "Setting R bashrc script permissions" \
    chmod +x /etc/bashrc.d/40-r.sh

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up R aliases and helpers..."

write_bashrc_content /etc/bashrc.d/40-r.sh "R aliases and helpers" << 'R_BASHRC_EOF'

# ----------------------------------------------------------------------------
# R Aliases
# ----------------------------------------------------------------------------
alias R='R --no-save'                    # Don't save workspace by default
alias Rscript='Rscript --vanilla'        # Clean environment for scripts

# ----------------------------------------------------------------------------
# r-install - Install R packages easily
#
# Arguments:
#   $@ - Package names to install
#
# Example:
#   r-install ggplot2 dplyr tidyr
# ----------------------------------------------------------------------------
r-install() {
    if [ $# -eq 0 ]; then
        echo "Usage: r-install <package1> [package2] ..."
        return 1
    fi

    echo "Installing R packages: $@"
    Rscript -e "
        packages <- commandArgs(trailingOnly = TRUE)
        for (pkg in packages) {
            if (!require(pkg, character.only = TRUE)) {
                install.packages(pkg, repos = 'https://cloud.r-project.org/')
            }
        }
    " "$@"
}

# ----------------------------------------------------------------------------
# r-update - Update all installed R packages
# ----------------------------------------------------------------------------
r-update() {
    echo "Updating all R packages..."
    Rscript -e "update.packages(ask = FALSE, repos = 'https://cloud.r-project.org/')"
}

# ----------------------------------------------------------------------------
# r-libs - List installed R packages
# ----------------------------------------------------------------------------
r-libs() {
    Rscript -e "installed.packages()[,c('Package', 'Version')]" | column -t
}

# ----------------------------------------------------------------------------
# r-search - Search for R packages on CRAN
#
# Arguments:
#   $1 - Search term
#
# Example:
#   r-search "machine learning"
# ----------------------------------------------------------------------------
r-search() {
    if [ -z "$1" ]; then
        echo "Usage: r-search <search-term>"
        return 1
    fi

    echo "Searching CRAN for: $1"
    Rscript -e "
        if (!require('utils')) install.packages('utils')
        available.packages(repos = 'https://cloud.r-project.org/')[
            grep('$1', available.packages()[,'Package'], ignore.case = TRUE),
            c('Package', 'Version')
        ]
    " | column -t
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
R_BASHRC_EOF

# ============================================================================
# Global R Configuration
# ============================================================================
log_message "Creating global R configuration"

# Create system-wide Rprofile
log_command "Creating R config directory" \
    mkdir -p /etc/R
cat > /etc/R/Rprofile.site << 'EOF'
# System-wide R startup configuration
local({
    # Set default CRAN mirror
    options(repos = c(CRAN = "https://cloud.r-project.org/"))

    # Configure library paths
    r_libs_user <- Sys.getenv("R_LIBS_USER", "/cache/r/library")
    .libPaths(c(r_libs_user, .libPaths()))

    # Set cache directory for downloaded packages
    options(pkgType = "source")

    # Suppress startup messages in non-interactive mode
    if (!interactive()) {
        options(warn = -1)
    }
})
EOF

# Create system-wide Renviron
cat > /etc/R/Renviron.site << EOF
# System-wide R environment variables
R_LIBS_USER=/cache/r/library
R_LIBS_SITE=/cache/r/library
R_MAX_NUM_DLLS=150
R_INSTALL_STAGED=FALSE
TMPDIR=/cache/r/tmp
EOF

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating R startup script"

# Create startup directory if it doesn't exist
log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

cat > /etc/container/first-startup/10-r-setup.sh << 'EOF'
#!/bin/bash
# R development environment setup

# Set up cache paths
export R_LIBS_USER="/cache/r/library"
export R_CACHE_DIR="/cache/r"
export TMPDIR="${R_CACHE_DIR}/tmp"

# Ensure directories exist with correct permissions
for dir in "${R_LIBS_USER}" "${TMPDIR}"; do
    if [ ! -d "${dir}" ]; then
        mkdir -p "${dir}"
    fi
done

# Check for R project files
if [ -f ${WORKING_DIR}/*.Rproj ] || [ -f ${WORKING_DIR}/.Rprofile ]; then
    echo "=== R Project Detected ==="
    echo "R $(R --version | head -n 1) is installed"
    echo "User library: ${R_LIBS_USER}"
    echo "Project-specific packages can be installed with: r-install('package-name')"
fi

# Install project dependencies if packrat is used
if [ -f ${WORKING_DIR}/packrat/packrat.lock ]; then
    echo "Packrat detected, restoring packages..."
    cd ${WORKING_DIR}
    Rscript -e "if (!require('packrat')) install.packages('packrat'); packrat::restore()"
fi

# Install project dependencies if renv is used
if [ -f ${WORKING_DIR}/renv.lock ]; then
    echo "renv detected, restoring packages..."
    cd ${WORKING_DIR}
    Rscript -e "if (!require('renv')) install.packages('renv'); renv::restore()"
fi
EOF
log_command "Setting R startup script permissions" \
    chmod +x /etc/container/first-startup/10-r-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating R verification script..."

cat > /usr/local/bin/test-r << 'EOF'
#!/bin/bash
echo "=== R Installation Status ==="
if command -v R &> /dev/null; then
    R --version | head -n 1
    echo "R binary: $(which R)"
    echo "R home: $(R RHOME)"
    echo "R library paths:"
    Rscript -e ".libPaths()" | sed 's/^/  /'
else
    echo "✗ R is not installed"
fi

echo ""
if command -v Rscript &> /dev/null; then
    echo "✓ Rscript is available at $(which Rscript)"
else
    echo "✗ Rscript is not found"
fi
EOF
log_command "Setting test-r script permissions" \
    chmod +x /usr/local/bin/test-r

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying R installation..."

log_command "Checking R version" \
    /usr/local/bin/R --version | head -n 1 || log_warning "R symlink not found"

log_command "Checking Rscript version" \
    /usr/local/bin/Rscript --version 2>&1 | head -n 1 || log_warning "Rscript symlink not found"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of R directories..."
log_command "Final ownership fix for R cache directories" \
    chown -R ${USER_UID}:${USER_GID} "${R_CACHE_DIR}" || true

# End logging
log_feature_end

echo ""
echo "Run 'test-r' to verify R installation"
echo "Run 'check-build-logs.sh r' to review installation logs"
