# ----------------------------------------------------------------------------
# Ruby environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Ruby gem cache locations
export GEM_HOME="/cache/ruby/gems"
export GEM_PATH="/cache/ruby/gems"
export BUNDLE_PATH="/cache/ruby/bundle"

# Only add gem bin path if not already there
if [ -d "${GEM_HOME}/bin" ] && [[ ":$PATH:" != *":${GEM_HOME}/bin:"* ]]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "${GEM_HOME}/bin" 2>/dev/null || export PATH="${GEM_HOME}/bin:$PATH"
    else
        export PATH="${GEM_HOME}/bin:$PATH"
    fi
fi

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
