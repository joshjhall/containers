#!/bin/bash
# R Development Tools - Statistical computing and data science tools
#
# Description:
#   Installs essential R development tools for data science, statistical
#   analysis, package development, and reproducible research. Tools are installed
#   as R packages in the system library.
#
# Features:
#   - Tidyverse ecosystem: dplyr, ggplot2, tidyr, readr, purrr, tibble, stringr, forcats
#   - Development tools: devtools, usethis, roxygen2, testthat
#   - Documentation: rmarkdown, knitr
#   - Code quality: lintr, styler
#   - Data manipulation: data.table (alternative to dplyr), jsonlite
#   - Package checking: rcmdcheck, covr
#
# Requirements:
#   - R must be installed (via INCLUDE_R=true)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "R Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check if R is available
if [ ! -f "/usr/local/bin/R" ]; then
    log_error "R not found at /usr/local/bin/R"
    log_error "The INCLUDE_R feature must be enabled before r-dev tools can be installed"
    log_feature_end
    exit 1
fi

# Check if Rscript is available
if [ ! -f "/usr/local/bin/Rscript" ]; then
    log_error "Rscript not found at /usr/local/bin/Rscript"
    log_error "The INCLUDE_R feature must be enabled first"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
# Update package lists with retry logic
apt_update

log_message "Installing R package build dependencies"
apt_install \
    libgit2-dev \
    libssh2-1-dev \
    libgmp-dev \
    libmpfr-dev \
    libudunits2-dev \
    libgdal-dev \
    libgeos-dev \
    libproj-dev \
    libmagick++-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libnode-dev \
    libglpk-dev \
    libxt6 \
    pandoc \
    texlive-base \
    texlive-latex-base \
    texlive-fonts-recommended \
    texlive-fonts-extra \
    texlive-latex-extra \
    libsodium-dev

# ============================================================================
# R Development Tools Installation
# ============================================================================
log_message "Preparing R package installation..."

# Set library paths
export R_LIBS_USER="/cache/r/library"
export R_LIBS_SITE="/cache/r/library"

BUILD_TEMP=$(create_secure_temp_dir)

# Create installation script
command cat > "${BUILD_TEMP}/install_r_dev_tools.R" << 'EOF'
# R Development Tools Installation Script

# Use CRAN mirror
options(repos = c(CRAN = "https://cloud.r-project.org/"))

# Configure for faster installation
options(
  # Use all available cores for compilation
  Ncpus = parallel::detectCores(),
  # Increase timeout for slow downloads
  timeout = 300,
  # Show download progress
  download.file.method = "libcurl",
  download.file.extra = "-L -f --retry 5 --retry-delay 2"
)

# Helper function to install packages with progress
install_if_missing <- function(packages) {
  new_packages <- packages[!(packages %in% installed.packages()[,"Package"])]
  if(length(new_packages) > 0) {
    cat(sprintf("Installing %d packages: %s\n",
                length(new_packages),
                paste(new_packages, collapse=", ")))
    install.packages(new_packages, dependencies = TRUE, quiet = FALSE)
  } else {
    cat("All packages already installed\n")
  }
}

# Core development tools only
cat("Installing essential R development tools...\n")
install_if_missing(c(
  "devtools",       # Package development (includes remotes, pkgbuild, etc.)
  "usethis",        # Project/package setup automation
  "testthat",       # Unit testing framework
  "roxygen2"        # Documentation generation
))

# Documentation tools
cat("Installing documentation tools...\n")
install_if_missing(c(
  "rmarkdown",      # Dynamic documents (essential for R development)
  "knitr"           # Dynamic report generation (required by rmarkdown)
))

# Code quality tools
cat("Installing code quality tools...\n")
install_if_missing(c(
  "lintr",          # Code linting
  "styler"          # Code formatting
))

# Tidyverse - Modern R data science ecosystem
# This is the de-facto standard for R development
# Includes: dplyr, ggplot2, tidyr, readr, purrr, tibble, stringr, forcats
cat("Installing tidyverse (this may take 10-15 minutes)...\n")
install_if_missing(c(
  "tidyverse"       # Complete modern R data science ecosystem
))

# Additional data manipulation tools
cat("Installing additional data tools...\n")
install_if_missing(c(
  "data.table",     # Fast data manipulation (alternative to dplyr)
  "jsonlite"        # JSON parsing (very common need)
))

# Package checking
cat("Installing package checking tools...\n")
install_if_missing(c(
  "rcmdcheck",      # R CMD check wrapper
  "covr"            # Code coverage
))

cat("R development tools installation complete!\n")
EOF

# Run the installation script as the user
log_command "Installing R development packages (this may take 25-30 minutes due to tidyverse)" \
    su - "${USERNAME}" -c "export R_LIBS_USER='${R_LIBS_USER}' R_LIBS_SITE='${R_LIBS_SITE}' && /usr/local/bin/Rscript '${BUILD_TEMP}/install_r_dev_tools.R'"

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up R development helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add r-dev aliases and helpers (content in lib/bashrc/r-dev.sh)
write_bashrc_content /etc/bashrc.d/45-r-dev.sh "R development tools" \
    < /tmp/build-scripts/features/lib/bashrc/r-dev.sh

log_command "Setting R dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/45-r-dev.sh

# ============================================================================
# Create helpful templates
# ============================================================================
log_message "Creating R development templates..."

# Create directory for templates
log_command "Creating R dev templates directory" \
    mkdir -p /etc/r-dev-templates

# .lintr configuration template
command cat > /etc/r-dev-templates/.lintr << 'EOF'
linters: linters_with_defaults(
    line_length_linter(120),
    commented_code_linter = NULL,
    implicit_integer_linter = NULL,
    extraction_operator_linter = NULL
)
exclusions: list(
    "renv",
    "packrat",
    "tests/testthat.R"
)
EOF

# testthat helper template
command cat > /etc/r-dev-templates/testthat-helper.R << 'EOF'
# Helper functions for testthat

# Skip tests on CI
skip_on_ci <- function() {
  if (!identical(Sys.getenv("CI"), "")) {
    skip("On CI")
  }
}

# Skip slow tests
skip_if_slow <- function() {
  if (!identical(Sys.getenv("R_TEST_SLOW"), "true")) {
    skip("Slow test")
  }
}

# Test data path helper
test_path <- function(...) {
  testthat::test_path(...)
}
EOF

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating r-dev startup script..."

log_command "Creating container startup directory" \
    mkdir -p /etc/container/first-startup

command cat > /etc/container/first-startup/25-r-dev-setup.sh << 'EOF'
#!/bin/bash
# R development tools configuration
if command -v R &> /dev/null; then
    echo "=== R Development Tools ==="

    # Check for R project indicators
    if [ -f ${WORKING_DIR}/DESCRIPTION ] || [ -f ${WORKING_DIR}/*.Rproj ]; then
        echo "R package/project detected!"

        # Copy templates if files don't exist
        if [ ! -f ${WORKING_DIR}/.lintr ] && command -v Rscript &> /dev/null; then
            if Rscript -e "requireNamespace('lintr', quietly = TRUE)" &> /dev/null; then
                command cp /etc/r-dev-templates/.lintr ${WORKING_DIR}/
                echo "Created .lintr configuration"
            fi
        fi

        # Check if renv is being used
        if [ -f ${WORKING_DIR}/renv.lock ]; then
            echo "renv detected - run 'renv::restore()' to restore packages"
        fi

        # Check if this is a package
        if [ -f ${WORKING_DIR}/DESCRIPTION ]; then
            echo ""
            echo "Package development commands:"
            echo "  rdev-check    - Run R CMD check"
            echo "  rdev-test     - Run tests"
            echo "  rdev-doc      - Generate documentation"
            echo "  rlint         - Lint code"
            echo "  rstyle        - Format code"
        fi
    fi

    # Check for R Markdown files
    if compgen -G "${WORKING_DIR}/*.Rmd" > /dev/null; then
        echo ""
        echo "R Markdown files detected!"
        echo "Use 'r-render file.Rmd' to render documents"
    fi

    # Check for Shiny apps
    if [ -f ${WORKING_DIR}/app.R ] || [ -f ${WORKING_DIR}/server.R ]; then
        echo ""
        echo "Shiny app detected!"
        echo "Use 'r-serve' to start the app on port 3838"
    fi

    # Show available dev tools
    echo ""
    echo "R development tools available:"
    echo "  tidyverse, devtools, testthat, roxygen2"
    echo "  rmarkdown, knitr, shiny, plumber"
    echo "  lintr, styler, profvis, bench"
    echo ""
    echo "Create new projects:"
    echo "  r-init-package <name>   - Create R package"
    echo "  r-init-analysis <name>  - Create analysis project"
fi
EOF
log_command "Setting R dev startup script permissions" \
    chmod +x /etc/container/first-startup/25-r-dev-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating r-dev verification script..."

command cat > /usr/local/bin/test-r-dev << 'EOF'
#!/bin/bash
echo "=== R Development Tools Status ==="

# Check core packages
packages=(
    "devtools" "usethis" "testthat" "roxygen2"
    "tidyverse" "rmarkdown" "knitr" "shiny"
    "lintr" "styler" "profvis" "renv"
)

echo "Checking installed packages..."
for pkg in "${packages[@]}"; do
    if Rscript -e "if(!requireNamespace('$pkg', quietly = TRUE)) quit(status = 1)" 2>/dev/null; then
        echo "✓ $pkg is installed"
    else
        echo "✗ $pkg is not found"
    fi
done

echo ""
echo "Run 'r-libs' to see all installed packages"
EOF
log_command "Setting test-r-dev script permissions" \
    chmod +x /usr/local/bin/test-r-dev

# ============================================================================
# R Language Server (for IDE support)
# ============================================================================
log_message "Installing R language server for IDE support..."

# Install R languageserver package
log_command "Installing R languageserver" \
    su - "${USERNAME}" -c "export R_LIBS_USER='${R_LIBS_USER}' R_LIBS_SITE='${R_LIBS_SITE}' && /usr/local/bin/Rscript -e \"install.packages('languageserver', repos='https://cloud.r-project.org/', quiet=TRUE)\""

# Verify LSP installation
if /usr/local/bin/Rscript -e "library(languageserver)" &>/dev/null; then
    log_message "R LSP installed successfully"
else
    log_warning "R LSP installation could not be verified"
fi

# ============================================================================
# Final verification
# ============================================================================
log_message "Verifying key R development tools..."

log_command "Checking devtools version" \
    /usr/local/bin/Rscript -e "packageVersion('devtools')" || log_warning "devtools not installed"

log_command "Checking tidyverse version" \
    /usr/local/bin/Rscript -e "packageVersion('tidyverse')" || log_warning "tidyverse not installed"

log_command "Checking rmarkdown version" \
    /usr/local/bin/Rscript -e "packageVersion('rmarkdown')" || log_warning "rmarkdown not installed"

# ============================================================================
# Final ownership fix
# ============================================================================
log_message "Ensuring correct ownership of R directories..."
log_command "Final ownership fix for R cache directories" \
    chown -R "${USER_UID}":"${USER_GID}" "${R_LIBS_USER}" "${R_LIBS_SITE}" || true

# Log feature summary
# Export directory paths for feature summary (also defined in parent r.sh)
export R_LIBS_SITE="/cache/R/library"
export R_LIBS_USER="/cache/R/user-library"

log_feature_summary \
    --feature "R Development Tools" \
    --tools "devtools,testthat,roxygen2,pkgdown,lintr,styler,rmarkdown,knitr,tidyverse,data.table,ggplot2,shiny" \
    --paths "${R_LIBS_USER},${R_LIBS_SITE}" \
    --env "R_LIBS_USER,R_LIBS_SITE" \
    --commands "R,Rscript,r-package-init,r-test,r-document,r-check,r-lint" \
    --next-steps "Run 'test-r-dev' to check installed tools. Use 'r-package-init <name>' to create packages. Run 'r-test' for tests, 'r-document' for docs, 'r-lint' for code style."

# End logging
log_feature_end

echo ""
echo "Run 'test-r-dev' to check installed tools"
echo "Run 'check-build-logs.sh r-dev' to review installation logs and errors"
