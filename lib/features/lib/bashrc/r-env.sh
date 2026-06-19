# ----------------------------------------------------------------------------
# R environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u # Don't error on unset variables
set +e # Don't exit on errors

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
export R_INSTALL_STAGED=FALSE # Avoid permission issues
export R_LIBS_SITE="${R_LIBS_USER}"

# Posit Package Manager binary repo. Mirrored from /etc/R/Renviron.site (written
# at build time with the pinned snapshot) so the r-* helpers — which run
# `Rscript --vanilla` and therefore skip Renviron.site — still target binaries.
# See lib/features/r.sh and issue #531.
if [ -r /etc/R/Renviron.site ]; then
    _r_ppm_repo=$(command grep -E '^R_PPM_REPO=' /etc/R/Renviron.site 2>/dev/null | command cut -d= -f2-)
    [ -n "${_r_ppm_repo}" ] && export R_PPM_REPO="${_r_ppm_repo}"
    unset _r_ppm_repo
fi
