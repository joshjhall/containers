#!/bin/bash
# Python tool installation: pipx, Poetry, and uv
#
# Expected variables from parent script:
#   USERNAME, PIP_CACHE_DIR, PIPX_HOME, PIPX_BIN_DIR, POETRY_VERSION, UV_VERSION
#
# Source this file from python.sh after pip is installed.

# ============================================================================
# Install pipx and Poetry
# ============================================================================
log_message "Installing pipx and Poetry..."

# Install pipx as the user
log_command "Installing pipx" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && /usr/local/bin/python3 -m pip install --no-cache-dir pipx"

# Ensure pipx bin directory is in PATH for build-time use (with security validation)
safe_add_to_path "${PIPX_BIN_DIR}" || export PATH="${PIPX_BIN_DIR}:$PATH"

# Use pipx to install Poetry with pinned version
POETRY_VERSION="${POETRY_VERSION:-2.3.2}"
log_command "Installing Poetry ${POETRY_VERSION} via pipx" \
    su - "${USERNAME}" -c "
    # Source path utilities for secure PATH management
    if [ -f /tmp/build-scripts/base/path-utils.sh ]; then
        source /tmp/build-scripts/base/path-utils.sh
    fi

    export PIPX_HOME='${PIPX_HOME}'
    export PIPX_BIN_DIR='${PIPX_BIN_DIR}'

    # Securely add to PATH
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path '${PIPX_BIN_DIR}' 2>/dev/null || export PATH='${PIPX_BIN_DIR}:$PATH'
        safe_add_to_path '/usr/local/bin' 2>/dev/null || export PATH='/usr/local/bin:$PATH'
    else
        export PATH='${PIPX_BIN_DIR}:/usr/local/bin:$PATH'
    fi

    /usr/local/bin/python3 -m pipx install poetry==${POETRY_VERSION}

    # Configure Poetry
    ${PIPX_BIN_DIR}/poetry config virtualenvs.in-project true
    ${PIPX_BIN_DIR}/poetry config cache-dir ${POETRY_CACHE_DIR}
"

# ============================================================================
# Install uv (fast Python package manager)
# ============================================================================
UV_VERSION="${UV_VERSION:-0.10.5}"
log_command "Installing uv ${UV_VERSION}" \
    su - "${USERNAME}" -c "export PIP_CACHE_DIR='${PIP_CACHE_DIR}' && \
    /usr/local/bin/python -m pip install --no-warn-script-location uv==${UV_VERSION}"
