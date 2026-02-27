#!/bin/bash
# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Install Python dependencies if pyproject.toml exists
if [ -n "${WORKING_DIR:-}" ] && [ -f "${WORKING_DIR}/pyproject.toml" ]; then
    echo "Installing Poetry dependencies..."
    cd "${WORKING_DIR}" || return
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "/opt/pipx/bin" 2>/dev/null || export PATH="/opt/pipx/bin:$PATH"
    else
        export PATH="/opt/pipx/bin:$PATH"
    fi
    poetry install --no-interaction || echo "Poetry install failed, continuing..."
fi

# Install pip requirements if requirements.txt exists
if [ -n "${WORKING_DIR:-}" ] && [ -f "${WORKING_DIR}/requirements.txt" ]; then
    echo "Installing pip requirements..."
    cd "${WORKING_DIR}" || return
    python3 -m pip install -r requirements.txt || echo "pip install failed, continuing..."
fi
