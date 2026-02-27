# Python development tools configuration

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Jupyter configuration
export JUPYTER_CONFIG_DIR="${JUPYTER_CONFIG_DIR:-$HOME/.jupyter}"
# Use new platformdirs to avoid deprecation warning
export JUPYTER_PLATFORM_DIRS=1

# IPython configuration
export IPYTHONDIR="${IPYTHONDIR:-$HOME/.ipython}"

# Pre-commit cache
export PRE_COMMIT_HOME="${PRE_COMMIT_HOME:-$HOME/.cache/pre-commit}"

# MyPy cache
export MYPY_CACHE_DIR="${MYPY_CACHE_DIR:-$HOME/.mypy_cache}"

# Black cache
export BLACK_CACHE_DIR="${BLACK_CACHE_DIR:-$HOME/.cache/black}"

# Pylint configuration
export PYLINTHOME="${PYLINTHOME:-$HOME/.cache/pylint}"

# Set Python development mode for better error messages
export PYTHONDEVMODE=1

# All Python development tools are installed globally via pip
# They are available in /usr/local/bin alongside Python itself
