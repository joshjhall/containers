
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

    echo "Installing R packages: $*"
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


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
