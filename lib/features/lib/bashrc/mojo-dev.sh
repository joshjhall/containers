# ----------------------------------------------------------------------------
# Mojo Development Tools Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# ----------------------------------------------------------------------------
# Mojo Development Aliases
# ----------------------------------------------------------------------------
# Common shortcuts
alias mjr='mojo run'
alias mjb='mojo build'
alias mjt='mojo test'
alias mjf='mojo format'

# Build variants
alias mjbo='mojo build -O3'        # Optimized build
alias mjbd='mojo build --debug-info'  # Debug build

# ----------------------------------------------------------------------------
# mojo-debug - Debug Mojo program with LLDB
# ----------------------------------------------------------------------------
mojo-debug() {
    if [ -z "$1" ]; then
        echo "Usage: mojo-debug <mojo-file>"
        return 1
    fi

    mojo debug "$1" "${@:2}"
}

# ----------------------------------------------------------------------------
# mojo-jupyter - Start Jupyter with Mojo kernel
# ----------------------------------------------------------------------------
mojo-jupyter() {
    if ! command -v jupyter &> /dev/null; then
        echo "Jupyter not installed. Install with: pip install jupyter"
        return 1
    fi

    echo "Starting Jupyter with Mojo kernel..."
    jupyter notebook "$@"
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
