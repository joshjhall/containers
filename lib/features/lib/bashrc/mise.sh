# ----------------------------------------------------------------------------
# Mise - Polyglot runtime version manager
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u # Don't error on unset variables
set +e # Don't exit on errors

# Check if we're in an interactive shell — mise's activate emits prompt hooks
# that misbehave in non-interactive shells.
if [[ $- != *i* ]]; then
    return 0
fi

# Cache / data dirs (persisted via the /cache volume)
export MISE_DATA_DIR="${MISE_DATA_DIR:-/cache/mise}"
export MISE_CACHE_DIR="${MISE_CACHE_DIR:-/cache/mise-cache}"

# Auto-trust .mise.toml files under the mounted workspace so dev-container users
# don't have to run `mise trust` on every project they open.
export MISE_TRUSTED_CONFIG_PATHS="${MISE_TRUSTED_CONFIG_PATHS:-/workspace}"

if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi
