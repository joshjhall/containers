# ----------------------------------------------------------------------------
# Keyboard Bindings Enhancement
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u

# Only configure keybindings in interactive shells
if [[ $- != *i* ]]; then
    return 0
fi

# Ensure readline is being used
if [[ -z "${BASH_VERSION:-}" ]]; then
    return 0
fi

# Re-read inputrc to ensure our settings are loaded
if [ -f /etc/inputrc ]; then
    bind -f /etc/inputrc 2>/dev/null || true
fi

# Disable flow control (Ctrl+S/Ctrl+Q) to free up Ctrl+S for forward search
if command -v stty >/dev/null 2>&1; then
    stty -ixon 2>/dev/null || true
fi

# Show which keybinding profile is active (only on first shell)
if [ -z "${_KEYBINDINGS_SHOWN:-}" ]; then
    export _KEYBINDINGS_SHOWN=1
fi
