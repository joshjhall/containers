# ----------------------------------------------------------------------------
# Node.js environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# Export paths and environment variables
export NPM_CACHE_DIR="/cache/npm"
export YARN_CACHE_DIR="/cache/yarn"
export PNPM_STORE_DIR="/cache/pnpm"
export NPM_GLOBAL_DIR="/cache/npm-global"

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Add global package directories to PATH
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "${NPM_GLOBAL_DIR}/bin" 2>/dev/null || export PATH="${NPM_GLOBAL_DIR}/bin:$PATH"
else
    export PATH="${NPM_GLOBAL_DIR}/bin:$PATH"
fi

# Package manager cache environment variables
export npm_config_cache="${NPM_CACHE_DIR}"
export YARN_CACHE_FOLDER="${YARN_CACHE_DIR}"
export PNPM_STORE="${PNPM_STORE_DIR}"
export npm_config_prefix="${NPM_GLOBAL_DIR}"
