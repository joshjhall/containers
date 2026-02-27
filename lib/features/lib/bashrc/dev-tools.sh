# ----------------------------------------------------------------------------
# Development Tools Configuration and Helpers
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# Override with modern tool aliases when available
# Prefer eza (maintained) over exa (deprecated but still in older Debian)
if command -v eza &> /dev/null; then
    alias ls='eza'
    alias ll='eza -l'
    alias la='eza -la'
    alias l='eza -F'
    alias tree='eza --tree'
elif command -v exa &> /dev/null; then
    alias ls='exa'
    alias ll='exa -l'
    alias la='exa -la'
    alias l='exa -F'
    alias tree='exa --tree'
fi

if command -v batcat &> /dev/null; then
    alias cat='batcat --style=plain'
    alias bat='batcat'
    alias less='batcat --paging=always'
    export LESSOPEN="| /usr/bin/env batcat --color=always --style=plain %s 2>/dev/null"
elif command -v bat &> /dev/null; then
    alias cat='bat --style=plain'
    alias less='bat --paging=always'
    export LESSOPEN="| /usr/bin/env bat --color=always --style=plain %s 2>/dev/null"
fi

if command -v fdfind &> /dev/null; then
    alias fd='fdfind'
    alias find='fdfind'  # Direct override for muscle memory
elif command -v fd &> /dev/null; then
    alias find='fd'  # Direct override for muscle memory
fi

if command -v rg &> /dev/null; then
    alias grep='rg'
    alias egrep='rg'
    alias fgrep='rg -F'
fi

if command -v duf &> /dev/null; then
    alias df='duf'
fi

if command -v ncdu &> /dev/null; then
    alias du='echo "Hint: Try ncdu for an interactive disk usage analyzer" && du'
fi

if command -v htop &> /dev/null; then
    alias top='htop'
fi

# Git aliases with delta
if command -v delta &> /dev/null; then
    alias gd='git diff'
    alias gdc='git diff --cached'
    alias gdh='git diff HEAD'
fi

# GitHub CLI aliases
if command -v gh &> /dev/null; then
    alias ghpr='gh pr create'
    alias ghprs='gh pr list'
    alias ghprv='gh pr view'
    alias ghprc='gh pr checks'
    alias ghis='gh issue list'
    alias ghiv='gh issue view'
    alias ghruns='gh run list'
    alias ghrunv='gh run view'
fi

# Additional modern tool shortcuts
# (ipython alias moved to python-dev where ipython is actually installed)

# Override basic tools with modern equivalents
alias diff='colordiff' 2>/dev/null || true
alias gitlog='tig' 2>/dev/null || true
alias diskusage='ncdu' 2>/dev/null || true

# Override lt alias to use eza/exa if available
if command -v eza &> /dev/null; then
    alias lt='eza -la --tree'
elif command -v exa &> /dev/null; then
    alias lt='exa -la --tree'
fi

# Entr helper functions
if command -v entr &> /dev/null; then
    # Watch and run tests
    # Use 'command find' to bypass the find='fd' alias (fd has different syntax)
    watch-test() {
        command find . -name "*.py" -o -name "*.sh" | entr -c "$@"
    }

    # Watch and reload service
    watch-reload() {
        echo "$1" | entr -r "$@"
    }

    # Watch and run make
    # Use 'command find' to bypass the find='fd' alias (fd has different syntax)
    watch-make() {
        command find . -name "*.c" -o -name "*.h" -o -name "Makefile" | entr -c make "$@"
    }
fi


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
