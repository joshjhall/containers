# ----------------------------------------------------------------------------
# Ollama Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# Model storage location (may be in /cache for volume persistence)
export OLLAMA_MODELS="${OLLAMA_MODELS_DIR}"

# Default host configuration
export OLLAMA_HOST="\${OLLAMA_HOST:-0.0.0.0:11434}"

# Helper aliases
alias ollama-status='pgrep -x ollama > /dev/null && echo "Ollama is running" || echo "Ollama is not running"'
alias ollama-logs='tail -f \${LOG_FILE:-/var/log/ollama.log}'
alias ollama-models='ollama list'


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
