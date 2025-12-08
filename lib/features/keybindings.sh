#!/bin/bash
# Keyboard Bindings - Terminal-specific keyboard shortcuts configuration
#
# Description:
#   Configures readline and shell keybindings for improved terminal navigation.
#   Supports multiple terminal profiles to avoid keybinding conflicts.
#
# Configuration:
#   Set KEYBINDING_PROFILE environment variable to select which bindings to use:
#     - "iterm" (default): iTerm2 and macOS Terminal.app optimized
#     - "xterm": Standard xterm sequences
#     - "minimal": Only basic readline improvements, no custom key sequences
#
#   Can be set at build time: --build-arg KEYBINDING_PROFILE=iterm
#   Or at runtime: export KEYBINDING_PROFILE=xterm
#
# Features:
#   - Word navigation: Option+Left/Right to move by word
#   - Word deletion: Option+Delete/Backspace to delete word backward
#   - Line operations: Standard Ctrl sequences
#   - Case-insensitive tab completion
#   - Show all completions immediately when ambiguous
#   - History search with arrow keys
#
# iTerm2 Profile (default):
#   Optimized for iTerm2 with "Option sends Esc+" configured.
#   Also works with macOS Terminal.app with "Use Option as Meta key" enabled.
#
#   Key Bindings:
#     - Option + Left Arrow  → Move backward one word
#     - Option + Right Arrow → Move forward one word
#     - Option + Backspace   → Delete word backward
#     - Option + Delete      → Delete word forward
#     - Shift + Return       → Insert soft line continuation (backslash + newline)
#
#   iTerm2 Shift+Return Setup:
#     Preferences → Profiles → Keys → Key Mappings → + (add)
#     Keyboard Shortcut: Shift+Return
#     Action: Send Escape Sequence
#     Value: [13;2u
#
# xterm Profile:
#   Standard xterm escape sequences for Linux terminals and SSH.
#
#   Key Bindings:
#     - Alt + Left Arrow  → Move backward one word
#     - Alt + Right Arrow → Move forward one word
#     - Alt + Backspace   → Delete word backward
#     - Alt + Delete      → Delete word forward
#
# Minimal Profile:
#   Only readline improvements (completion, history), no custom key sequences.
#   Use this if you have custom terminal key mappings or experience conflicts.
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source bashrc helpers for configuration
source /tmp/build-scripts/base/bashrc-helpers.sh

# Start logging
log_feature_start "Keyboard Bindings"

# Get the keybinding profile (default to iterm)
KEYBINDING_PROFILE="${KEYBINDING_PROFILE:-iterm}"
log_message "Configuring keybindings for profile: ${KEYBINDING_PROFILE}"

# ============================================================================
# Common inputrc Settings (all profiles)
# ============================================================================
log_message "Creating base inputrc configuration..."

command cat > /etc/inputrc << 'INPUTRC_COMMON_EOF'
# /etc/inputrc - System-wide readline configuration
# Profile-specific bindings are appended below

# ============================================================================
# General Settings
# ============================================================================

# Use emacs editing mode (works with Option/Alt key bindings)
set editing-mode emacs

# Case-insensitive tab completion
set completion-ignore-case on

# Treat hyphens and underscores as equivalent for completion
set completion-map-case on

# Show all completions immediately if ambiguous (no double-tab required)
set show-all-if-ambiguous on

# Show all completions if there are more than one
set show-all-if-unmodified on

# Add trailing slash to completed directory names
set mark-directories on
set mark-symlinked-directories on

# Color the common prefix in completions
set colored-completion-prefix on

# Color completions by file type (like ls --color)
set colored-stats on

# Don't beep on error
set bell-style none

# Show extra file info during completion (like ls -F)
set visible-stats on

# ============================================================================
# Standard Readline Bindings (all profiles)
# ============================================================================

# Line navigation (Ctrl sequences - universal)
"\C-a": beginning-of-line
"\C-e": end-of-line

# Line editing
"\C-u": unix-line-discard
"\C-k": kill-line
"\C-w": unix-word-rubout

# History
"\C-r": reverse-search-history
"\C-s": forward-search-history

# Other
"\C-l": clear-screen
"\C-_": undo
"\C-y": yank
"\C-v": quoted-insert

INPUTRC_COMMON_EOF

# ============================================================================
# Profile-Specific Key Bindings
# ============================================================================

case "${KEYBINDING_PROFILE}" in
    iterm|macos)
        log_message "Adding iTerm2/macOS Terminal keybindings..."
        command cat >> /etc/inputrc << 'INPUTRC_ITERM_EOF'

# ============================================================================
# iTerm2 / macOS Terminal Key Bindings
# ============================================================================
# Requires iTerm2: Preferences → Profiles → Keys → General
#   Set "Left Option key" to "Esc+"
#
# Or Terminal.app: Preferences → Profiles → Keyboard
#   Check "Use Option as Meta key"
# ============================================================================

# Word Navigation (Option + Arrow)
# Meta+f and Meta+b are the standard readline bindings for word movement
"\ef": forward-word
"\eb": backward-word

# iTerm2 sends these sequences for Option+Arrow with "Esc+" setting
"\e[1;3C": forward-word
"\e[1;3D": backward-word

# macOS Terminal.app with Meta key enabled
"\e[5C": forward-word
"\e[5D": backward-word

# Word Deletion
# Meta+backspace for word deletion
"\e\C-?": backward-kill-word
"\e\C-h": backward-kill-word
"\e\177": backward-kill-word

# Meta+d for forward word deletion
"\ed": kill-word
"\e[3;3~": kill-word

# History Search (type partial command, then arrow)
"\e[A": history-search-backward
"\e[B": history-search-forward

# Soft line continuation (Shift + Return → backslash + newline)
# Requires iTerm2 key mapping: Shift+Return → Send Escape Sequence → [13;2u
# This inserts a backslash followed by a newline for multi-line commands
"\e[13;2u": "\\\n"

INPUTRC_ITERM_EOF
        ;;

    xterm|linux)
        log_message "Adding xterm/Linux terminal keybindings..."
        command cat >> /etc/inputrc << 'INPUTRC_XTERM_EOF'

# ============================================================================
# xterm / Linux Terminal Key Bindings
# ============================================================================
# Standard xterm escape sequences for Alt+Arrow and Alt+Backspace
# Works with most Linux terminal emulators and SSH clients
# ============================================================================

# Word Navigation (Alt + Arrow)
# Ctrl+Arrow sequences (common in xterm)
"\e[1;5C": forward-word
"\e[1;5D": backward-word

# Alt+Arrow sequences
"\e[1;3C": forward-word
"\e[1;3D": backward-word

# Application mode arrow keys
"\eOC": forward-word
"\eOD": backward-word

# Standard Meta bindings
"\ef": forward-word
"\eb": backward-word

# Word Deletion (Alt + Backspace/Delete)
"\e\C-?": backward-kill-word
"\e\C-h": backward-kill-word
"\ed": kill-word
"\e[3;5~": kill-word
"\e[3;3~": kill-word

# xterm modifyOtherKeys mode
"\e[27;3;127~": backward-kill-word
"\e[27;5;127~": backward-kill-word

# History Search (type partial command, then arrow)
"\e[A": history-search-backward
"\e[B": history-search-forward
"\eOA": history-search-backward
"\eOB": history-search-forward

# Soft line continuation (Shift + Return → backslash + newline)
# Works with terminals supporting CSI u protocol (kitty, foot, etc.)
"\e[13;2u": "\\\n"

INPUTRC_XTERM_EOF
        ;;

    minimal|none)
        log_message "Using minimal keybindings (no custom key sequences)..."
        command cat >> /etc/inputrc << 'INPUTRC_MINIMAL_EOF'

# ============================================================================
# Minimal Key Bindings
# ============================================================================
# Only basic history navigation, no custom word/line movement sequences
# Use this profile if you have custom terminal keybindings
# ============================================================================

# Standard Meta bindings (may or may not work depending on terminal)
"\ef": forward-word
"\eb": backward-word
"\ed": kill-word

INPUTRC_MINIMAL_EOF
        ;;

    *)
        log_warning "Unknown keybinding profile: ${KEYBINDING_PROFILE}, using minimal"
        ;;
esac

# ============================================================================
# Bash Keybinding Configuration
# ============================================================================
log_message "Adding bash-specific keybinding configuration..."

# Create bashrc.d script for keybinding setup
write_bashrc_content /etc/bashrc.d/10-keybindings.sh "keyboard bindings configuration" << 'KEYBINDINGS_BASHRC_EOF'
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

KEYBINDINGS_BASHRC_EOF

# Make the script executable
log_command "Setting keybindings bashrc script permissions" \
    chmod 755 /etc/bashrc.d/10-keybindings.sh

# ============================================================================
# User inputrc Template
# ============================================================================
log_message "Creating user inputrc template..."

command cat > /etc/skel/.inputrc << 'USER_INPUTRC_EOF'
# ~/.inputrc - User readline configuration
# This file is sourced by readline after /etc/inputrc
#
# To change the keybinding profile, set KEYBINDING_PROFILE in your shell:
#   export KEYBINDING_PROFILE=xterm  # or: iterm, minimal
#
# Then restart your shell or run: bind -f /etc/inputrc

# Include system defaults
$include /etc/inputrc

# ============================================================================
# User Customizations Below
# ============================================================================

# Example: Override specific bindings
# "\C-p": previous-history
# "\C-n": next-history

# Example: Enable vi-style editing mode
# set editing-mode vi

USER_INPUTRC_EOF

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating keybindings verification script..."

command cat > /usr/local/bin/test-keybindings << 'EOF'
#!/bin/bash
echo "=== Keyboard Bindings Status ==="
echo ""
echo "Active Profile: ${KEYBINDING_PROFILE:-iterm}"
echo ""
echo "Configuration Files:"
[ -f /etc/inputrc ] && echo "  ✓ /etc/inputrc" || echo "  ✗ /etc/inputrc not found"
[ -f /etc/bashrc.d/10-keybindings.sh ] && echo "  ✓ /etc/bashrc.d/10-keybindings.sh" || echo "  ✗ /etc/bashrc.d/10-keybindings.sh not found"
[ -f ~/.inputrc ] && echo "  ℹ ~/.inputrc exists (may override system settings)"

echo ""
echo "Readline Settings:"
bind -v 2>/dev/null | grep -E "(completion-ignore-case|show-all-if-ambiguous|editing-mode)" | sed 's/^/  /'

echo ""
case "${KEYBINDING_PROFILE:-iterm}" in
    iterm|macos)
        echo "iTerm2/macOS Terminal Key Bindings:"
        echo "  Word Navigation:"
        echo "    - Option + Left Arrow  → Move backward one word"
        echo "    - Option + Right Arrow → Move forward one word"
        echo ""
        echo "  Word Deletion:"
        echo "    - Option + Backspace   → Delete word backward"
        echo "    - Option + Delete      → Delete word forward"
        echo ""
        echo "  Line Continuation:"
        echo "    - Shift + Return       → Insert soft return (backslash + newline)"
        echo ""
        echo "  Setup Required:"
        echo "    iTerm2: Preferences → Profiles → Keys → General"
        echo "            Set 'Left Option key' to 'Esc+'"
        echo ""
        echo "    For Shift+Return (soft line continuation):"
        echo "      Preferences → Profiles → Keys → Key Mappings"
        echo "      Click '+' to add new mapping:"
        echo "        Keyboard Shortcut: Shift+Return"
        echo "        Action: Send Escape Sequence"
        echo "        Value: [13;2u"
        echo ""
        echo "    Terminal.app: Preferences → Profiles → Keyboard"
        echo "                  Check 'Use Option as Meta key'"
        ;;
    xterm|linux)
        echo "xterm/Linux Terminal Key Bindings:"
        echo "  Word Navigation:"
        echo "    - Alt + Left Arrow  → Move backward one word"
        echo "    - Alt + Right Arrow → Move forward one word"
        echo ""
        echo "  Word Deletion:"
        echo "    - Alt + Backspace   → Delete word backward"
        echo "    - Alt + Delete      → Delete word forward"
        ;;
    minimal|none)
        echo "Minimal Key Bindings:"
        echo "  Only basic readline improvements enabled."
        echo "  No custom word/line movement sequences."
        ;;
esac

echo ""
echo "Standard Bindings (all profiles):"
echo "  - Ctrl + A → Beginning of line"
echo "  - Ctrl + E → End of line"
echo "  - Ctrl + U → Delete to beginning of line"
echo "  - Ctrl + K → Delete to end of line"
echo "  - Ctrl + W → Delete word backward"
echo "  - Ctrl + R → Reverse search history"
echo "  - Up/Down  → Search history (after typing partial command)"

echo ""
echo "To change profile: export KEYBINDING_PROFILE=xterm  # or: iterm, minimal"
EOF

log_command "Setting test-keybindings script permissions" \
    chmod +x /usr/local/bin/test-keybindings

# ============================================================================
# Feature Summary
# ============================================================================

log_feature_summary \
    --feature "Keyboard Bindings" \
    --tools "readline,inputrc" \
    --paths "/etc/inputrc,/etc/bashrc.d/10-keybindings.sh,/etc/skel/.inputrc" \
    --env "KEYBINDING_PROFILE" \
    --commands "test-keybindings" \
    --next-steps "Profile: ${KEYBINDING_PROFILE}. Run 'test-keybindings' for setup instructions."

# End logging
log_feature_end

echo ""
echo "Keybinding profile: ${KEYBINDING_PROFILE}"
echo "Run 'test-keybindings' to verify configuration and see available shortcuts"
echo "Run 'check-build-logs.sh keybindings' to review installation logs"
