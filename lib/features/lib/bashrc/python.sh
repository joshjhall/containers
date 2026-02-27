# Python environment configuration

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Python cache directories
export PIP_CACHE_DIR="/cache/pip"
export PIP_NO_CACHE_DIR=false
export PIP_DISABLE_PIP_VERSION_CHECK=1

# Poetry configuration
export POETRY_CACHE_DIR="/cache/poetry"
export POETRY_VIRTUALENVS_IN_PROJECT=true

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# pipx configuration
if [ -d /opt/pipx ] && [[ ":$PATH:" != *":/opt/pipx/bin:"* ]]; then
    export PIPX_HOME="/opt/pipx"
    export PIPX_BIN_DIR="/opt/pipx/bin"
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$PIPX_BIN_DIR" 2>/dev/null || export PATH="$PIPX_BIN_DIR:$PATH"
    else
        export PATH="$PIPX_BIN_DIR:$PATH"
    fi
fi
