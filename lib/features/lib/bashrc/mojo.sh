# ----------------------------------------------------------------------------
# Mojo Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# Mojo environment configuration
export PIXI_CACHE_DIR="/cache/pixi"
export MOJO_PROJECT_DIR="/cache/mojo/project/mojo-env"

# Mojo aliases
alias mojo-repl='mojo'
alias mojo-build='mojo build'
alias mojo-run='mojo run'
alias mojo-test='mojo test'
alias mojo-format='mojo format'
alias mojo-doc='mojo doc'

# Helper function to activate Mojo environment
mojo-shell() {
    cd "${MOJO_PROJECT_DIR}" && pixi shell
}

# Helper function to run Mojo with pixi
mojo-exec() {
    cd "${MOJO_PROJECT_DIR}" && pixi run "$@"
}

# Helper function to add packages to Mojo environment
mojo-add() {
    cd "${MOJO_PROJECT_DIR}" && pixi add "$@"
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
