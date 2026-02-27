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


# R environment configuration
export R_LIBS_USER="/cache/r/library"
export R_CACHE_DIR="/cache/r"

# Use cache directory for temporary files
export TMPDIR="${R_CACHE_DIR}/tmp"

# R package installation settings
export R_INSTALL_STAGED=FALSE  # Avoid permission issues
export R_LIBS_SITE="${R_LIBS_USER}"
