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
if compgen -G "${WORKING_DIR}/*.Rproj" > /dev/null || [ -f "${WORKING_DIR}/.Rprofile" ]; then
    echo "=== R Project Detected ==="
    echo "R $(R --version | head -n 1) is installed"
    echo "User library: ${R_LIBS_USER}"
    echo "Project-specific packages can be installed with: r-install('package-name')"
fi

# Install project dependencies if packrat is used
if [ -f "${WORKING_DIR}/packrat/packrat.lock" ]; then
    echo "Packrat detected, restoring packages..."
    cd "${WORKING_DIR}" || return
    Rscript -e "if (!require('packrat')) install.packages('packrat'); packrat::restore()"
fi

# Install project dependencies if renv is used
if [ -f "${WORKING_DIR}/renv.lock" ]; then
    echo "renv detected, restoring packages..."
    cd "${WORKING_DIR}" || return
    Rscript -e "if (!require('renv')) install.packages('renv'); renv::restore()"
fi
