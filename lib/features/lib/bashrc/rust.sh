# ----------------------------------------------------------------------------
# Rust environment configuration
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

# Rust toolchain paths
export CARGO_HOME="/cache/cargo"
export RUSTUP_HOME="/cache/rustup"

# Add cargo bin to PATH with security validation
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "${CARGO_HOME}/bin" 2>/dev/null || export PATH="${CARGO_HOME}/bin:$PATH"
else
    # Fallback if safe_add_to_path not available
    if [ -d "${CARGO_HOME}/bin" ]; then
        export PATH="${CARGO_HOME}/bin:$PATH"
    fi
fi

# Rust compiler flags for better error messages
export RUST_BACKTRACE=1

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
