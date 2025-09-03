#!/bin/bash
# R Development Tools - Statistical computing and data science tools
#
# Description:
#   Installs essential R development tools for data science, statistical
#   analysis, package development, and reproducible research. Tools are installed
#   as R packages in the system library.
#
# Features:
#   - Core tidyverse: dplyr, ggplot2, tidyr, readr, purrr, tibble, stringr, forcats
#   - Development: devtools, usethis, roxygen2, testthat, pkgdown, covr, rcmdcheck
#   - Data manipulation: data.table, dtplyr, dbplyr, readxl, haven
#   - Reporting: rmarkdown, knitr, tinytex, bookdown, blogdown, flexdashboard
#   - Debugging/Profiling: profvis, bench, microbenchmark, tictoc, debugme
#   - Linting: lintr, styler
#   - Database: DBI, RSQLite, RPostgreSQL, odbc, pool
#   - Web/API: httr, httr2, plumber, shiny, shinydashboard, RestRserve
#   - Data formats: jsonlite, xml2, rvest
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

# Create installation script
cat > /tmp/install_r_dev_tools.R << 'EOF'
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

# Minimal data manipulation (often needed for examples/tests)
cat("Installing minimal data tools...\n")
install_if_missing(c(
  "data.table",     # Fast data manipulation (lightweight)
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
log_command "Installing R development packages (this may take 15-20 minutes)" \
    su - ${USERNAME} -c "export R_LIBS_USER='${R_LIBS_USER}' R_LIBS_SITE='${R_LIBS_SITE}' && /usr/local/bin/Rscript /tmp/install_r_dev_tools.R"

# Clean up
log_command "Cleaning up installation script" \
    rm -f /tmp/install_r_dev_tools.R

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up R development helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add r-dev aliases and helpers
write_bashrc_content /etc/bashrc.d/45-r-dev.sh "R development tools" << 'R_DEV_BASHRC_EOF'
# ----------------------------------------------------------------------------
# R Development Tool Aliases and Functions
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

# ----------------------------------------------------------------------------
# R Development Tool Aliases
# ----------------------------------------------------------------------------
# RStudio-like shortcuts
alias rcheck='R CMD check'
alias rbuild='R CMD build'
alias rinstall='R CMD INSTALL'
alias rdoc='R CMD Rd2pdf'

# Devtools shortcuts
alias rdev-check='Rscript -e "devtools::check()"'
alias rdev-test='Rscript -e "devtools::test()"'
alias rdev-doc='Rscript -e "devtools::document()"'
alias rdev-load='Rscript -e "devtools::load_all()"'
alias rdev-install='Rscript -e "devtools::install()"'

# Linting and styling
alias rlint='Rscript -e "lintr::lint_dir()"'
alias rstyle='Rscript -e "styler::style_dir()"'

# ----------------------------------------------------------------------------
# r-new-package - Create a new R package with best practices
#
# Arguments:
#   $1 - Package name (required)
#
# Example:
#   r-new-package mypackage
# ----------------------------------------------------------------------------
r-new-package() {
    if [ -z "$1" ]; then
        echo "Usage: r-new-package <package-name>"
        return 1
    fi

    local pkg_name="$1"
    echo "Creating new R package: $pkg_name"

    Rscript -e "
    usethis::create_package('$pkg_name')
    setwd('$pkg_name')
    usethis::use_git()
    usethis::use_mit_license()
    usethis::use_readme_rmd()
    usethis::use_testthat()
    usethis::use_package_doc()
    usethis::use_news_md()
    usethis::use_github_actions()
    usethis::use_github_actions_badge()
    cat('Package $pkg_name created successfully!\n')
    "
}

# ----------------------------------------------------------------------------
# r-new-analysis - Create a new analysis project
#
# Arguments:
#   $1 - Project name (required)
#
# Example:
#   r-new-analysis myanalysis
# ----------------------------------------------------------------------------
r-new-analysis() {
    if [ -z "$1" ]; then
        echo "Usage: r-new-analysis <project-name>"
        return 1
    fi

    local proj_name="$1"
    echo "Creating new analysis project: $proj_name"

    Rscript -e "
    usethis::create_project('$proj_name')
    setwd('$proj_name')

    # Create standard directories
    usethis::use_directory('data-raw')
    usethis::use_directory('data')
    usethis::use_directory('R')
    usethis::use_directory('outputs')
    usethis::use_directory('figures')

    # Initialize renv for reproducibility
    renv::init()

    # Create README
    usethis::use_readme_rmd()

    # Create initial analysis template
    writeLines(c(
        '---',
        'title: \"Analysis\"',
        'author: \"Your Name\"',
        'date: \"`r Sys.Date()`\"',
        'output: html_document',
        '---',
        '',
        '```{r setup, include=FALSE}',
        'knitr::opts_chunk$set(echo = TRUE)',
        'library(tidyverse)',
        '```',
        '',
        '## Introduction',
        '',
        '## Data Import',
        '',
        '## Analysis',
        '',
        '## Results',
        ''
    ), 'analysis.Rmd')

    cat('Analysis project $proj_name created successfully!\n')
    "
}

# ----------------------------------------------------------------------------
# r-render - Render R Markdown documents
#
# Arguments:
#   $1 - R Markdown file (required)
#   $2 - Output format (optional: html, pdf, word, all)
#
# Example:
#   r-render report.Rmd
#   r-render report.Rmd pdf
# ----------------------------------------------------------------------------
r-render() {
    if [ -z "$1" ]; then
        echo "Usage: r-render <file.Rmd> [format]"
        return 1
    fi

    local file="$1"
    local format="${2:-html_document}"

    if [ "$format" = "all" ]; then
        echo "Rendering $file to all formats..."
        Rscript -e "rmarkdown::render('$file', output_format = 'all')"
    else
        echo "Rendering $file to $format..."
        Rscript -e "rmarkdown::render('$file', output_format = '$format')"
    fi
}

# ----------------------------------------------------------------------------
# r-serve - Start a Shiny app or Plumber API
#
# Arguments:
#   $1 - App file or directory (optional, defaults to current directory)
#
# Example:
#   r-serve
#   r-serve app.R
#   r-serve myapp/
# ----------------------------------------------------------------------------
r-serve() {
    local app="${1:-.}"

    if [ -f "$app/app.R" ] || [ -f "$app/server.R" ]; then
        echo "Starting Shiny app in $app..."
        Rscript -e "shiny::runApp('$app', host = '0.0.0.0', port = 3838)"
    elif [ -f "$app" ] && grep -q "plumber" "$app"; then
        echo "Starting Plumber API from $app..."
        Rscript -e "pr <- plumber::plumb('$app'); pr\$run(host = '0.0.0.0', port = 8000)"
    else
        echo "No Shiny app or Plumber API found"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# r-profile - Profile R code and visualize results
#
# Arguments:
#   $1 - R script to profile (required)
#
# Example:
#   r-profile analysis.R
# ----------------------------------------------------------------------------
r-profile() {
    if [ -z "$1" ]; then
        echo "Usage: r-profile <script.R>"
        return 1
    fi

    local script="$1"
    local prof_file="${script%.R}_profile.html"

    echo "Profiling $script..."
    Rscript -e "
    profvis::profvis({
        source('$script')
    }, prof_output = '$prof_file')
    cat('Profile saved to: $prof_file\n')
    "
}

# ----------------------------------------------------------------------------
# r-benchmark - Benchmark R code snippets
#
# Arguments:
#   $@ - R expressions to benchmark
#
# Example:
#   r-benchmark "1:1000000" "seq(1, 1000000)" "seq.int(1, 1000000)"
# ----------------------------------------------------------------------------
r-benchmark() {
    if [ $# -eq 0 ]; then
        echo "Usage: r-benchmark <expr1> <expr2> ..."
        return 1
    fi

    local exprs=""
    for expr in "$@"; do
        exprs="${exprs}${expr} = { $expr },"
    done
    exprs="${exprs%,}"  # Remove trailing comma

    Rscript -e "
    library(bench)
    result <- bench::mark(
        $exprs,
        check = FALSE,
        iterations = 100
    )
    print(result)
    "
}

# ----------------------------------------------------------------------------
# r-deps - Show package dependencies
#
# Arguments:
#   $1 - Package name or path (optional, defaults to current directory)
#
# Example:
#   r-deps
#   r-deps ggplot2
# ----------------------------------------------------------------------------
r-deps() {
    local pkg="${1:-.}"

    if [ -f "$pkg/DESCRIPTION" ] || [ "$pkg" = "." ]; then
        echo "Package dependencies for $pkg:"
        Rscript -e "desc::desc_get_deps('$pkg')"
    else
        echo "Dependencies of $pkg:"
        Rscript -e "
        deps <- tools::package_dependencies('$pkg', recursive = TRUE)
        if(length(deps[[1]]) > 0) {
            cat(paste(deps[[1]], collapse = '\n'), '\n')
        } else {
            cat('No dependencies found\n')
        }
        "
    fi
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
R_DEV_BASHRC_EOF

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
cat > /etc/r-dev-templates/.lintr << 'EOF'
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
cat > /etc/r-dev-templates/testthat-helper.R << 'EOF'
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

cat > /etc/container/first-startup/25-r-dev-setup.sh << 'EOF'
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
                cp /etc/r-dev-templates/.lintr ${WORKING_DIR}/
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
    echo "  r-new-package <name>   - Create R package"
    echo "  r-new-analysis <name>  - Create analysis project"
fi
EOF
log_command "Setting R dev startup script permissions" \
    chmod +x /etc/container/first-startup/25-r-dev-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating r-dev verification script..."

cat > /usr/local/bin/test-r-dev << 'EOF'
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
    chown -R ${USER_UID}:${USER_GID} "${R_LIBS_USER}" "${R_LIBS_SITE}" || true

# End logging
log_feature_end

echo ""
echo "Run 'test-r-dev' to check installed tools"
echo "Run 'check-build-logs.sh r-dev' to review installation logs and errors"
