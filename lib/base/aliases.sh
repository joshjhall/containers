#!/bin/bash
# Base aliases for all environments
#
# Description:
#   Sets up common aliases and environment variables for improved shell experience
#
# Features:
#   - Common file navigation aliases (ll, la, .., ...)
#   - Safety aliases (interactive rm, cp, mv)
#   - Git shortcuts (gs, gd, gco, etc.)
#   - Environment improvements (history, colors, completion)
#   - Zoxide integration if available
#

# Source bashrc helpers if available
if [ -f /tmp/build-scripts/base/bashrc-helpers.sh ]; then
    source /tmp/build-scripts/base/bashrc-helpers.sh
fi

# ============================================================================
# Shell Aliases and Environment Setup
# ============================================================================
command cat >> /etc/bash.bashrc << 'EOF'

# ----------------------------------------------------------------------------
# Security: Safe eval for tool initialization
# ----------------------------------------------------------------------------
# Validates command output before eval to prevent command injection
safe_eval() {
    local output
    if ! output=$("$@" 2>/dev/null); then
        return 1
    fi
    # Check for suspicious patterns
    # Use 'command grep' to bypass any aliases (e.g., grep='rg' from dev-tools)
    if echo "$output" | command grep -qE '(rm -rf|curl.*bash|wget.*bash|;\s*rm|\$\(.*rm)|exec\s+[^$]|/bin/sh.*-c|bash.*-c.*http)'; then
        echo "WARNING: Suspicious output detected, skipping initialization of: $*" >&2
        return 1
    fi
    eval "$output"
}

# ----------------------------------------------------------------------------
# File and Directory Navigation
# ----------------------------------------------------------------------------
alias ll='ls -alF'
alias la='ls -al'
alias l='ls -CF'
alias lt='ls -la --tree 2>/dev/null || tree'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# Color support for grep
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# ----------------------------------------------------------------------------
# Safety Aliases - Prevent accidental file operations
# ----------------------------------------------------------------------------
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# ----------------------------------------------------------------------------
# Productivity Shortcuts
# ----------------------------------------------------------------------------
alias h='history'
alias hgrep='history | grep'
alias j='jobs -l'
alias which='type -a'
alias path='echo -e ${PATH//:/\\n}'
alias now='date +"%T"'
alias nowdate='date +"%Y-%m-%d"'
alias psg='ps aux | grep -v grep | grep -i'
alias ports='lsof -i -P -n'
alias listening='lsof -i -P -n | grep LISTEN'
alias myip='curl -s https://ipinfo.io/ip'
alias weather='curl -s wttr.in'

# ----------------------------------------------------------------------------
# Git Shortcuts - Common git commands
# ----------------------------------------------------------------------------
alias g='git'
alias gs='git status'
alias gst='git status'
alias gd='git diff'
alias gl='git log --oneline'
alias ga='git add'
alias gc='git commit'
alias gcm='git commit -m'
alias gco='git checkout'
alias gb='git branch'
alias gp='git push'
alias gpo='git push origin'
alias gpu='git pull'
alias gpl='git pull'

# ----------------------------------------------------------------------------
# Environment Configuration
# ----------------------------------------------------------------------------
export TERM=xterm-256color
export COLORTERM=truecolor
export LESS="-R"
export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth:erasedups
export PROMPT_DIRTRIM=3

EOF

# ============================================================================
# Bash-Specific Configuration
# ============================================================================
command cat >> /etc/bash.bashrc << 'EOF'

# ----------------------------------------------------------------------------
# Shell Options - Improve bash behavior
# ----------------------------------------------------------------------------
shopt -s histappend
shopt -s checkwinsize
shopt -s globstar 2>/dev/null || true
shopt -s autocd 2>/dev/null || true
shopt -s cdspell 2>/dev/null || true
shopt -s dirspell 2>/dev/null || true
shopt -s nocaseglob 2>/dev/null || true

# ----------------------------------------------------------------------------
# Bash Completion
# ----------------------------------------------------------------------------
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi

# ----------------------------------------------------------------------------
# Zoxide Integration - Smarter directory navigation
# ----------------------------------------------------------------------------
if command -v zoxide &> /dev/null; then
    safe_eval zoxide init bash
    # Override cd with zoxide
    alias cd='z'
    alias cdi='zi'  # Interactive selection
fi

EOF
