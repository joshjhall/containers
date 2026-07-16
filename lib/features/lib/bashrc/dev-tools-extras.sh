# fzf configuration
if [ -f /opt/fzf/bin/fzf ]; then
    # Source shell integration files if they exist
    if [ -f /opt/fzf/shell/key-bindings.bash ]; then
        source /opt/fzf/shell/key-bindings.bash 2>/dev/null || true
    fi
    if [ -f /opt/fzf/shell/completion.bash ]; then
        source /opt/fzf/shell/completion.bash 2>/dev/null || true
    fi

    # Better fzf defaults
    export FZF_DEFAULT_OPTS="--height 40% --layout=reverse --border --info=inline"

    # Use fd for fzf if available
    if command -v fd &>/dev/null; then
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
        export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
        export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
    fi
fi

# direnv hook
if command -v direnv &>/dev/null; then
    safe_eval "direnv hook bash" direnv hook bash
fi

# lazygit alias
if command -v lazygit &>/dev/null; then
    alias lg='lazygit'
    alias lzg='lazygit'
fi

# just aliases
if command -v just &>/dev/null; then
    alias j='just'
    # just completion with validation
    COMPLETION_FILE="/tmp/just-completion.$$.bash"
    if just --completions bash >"$COMPLETION_FILE" 2>/dev/null; then
        # Validate completion output before sourcing
        # Use 'command grep' to bypass any aliases (e.g., grep='rg')
        if [ -f "$COMPLETION_FILE" ] &&
            [ "$(wc -c <"$COMPLETION_FILE")" -lt 100000 ] &&
            ! command grep -qE '(rm -rf|curl.*bash|wget.*bash|eval.*\$)' "$COMPLETION_FILE"; then
            # shellcheck disable=SC1090  # Dynamic source is validated
            source "$COMPLETION_FILE"
        fi
    fi
    command rm -f "$COMPLETION_FILE"
fi

# mkcert helpers
if command -v mkcert &>/dev/null; then
    alias mkcert-install='mkcert -install'
    alias mkcert-uninstall='mkcert -uninstall'
fi

# Helper function for fzf git operations
if command -v fzf &>/dev/null && command -v git &>/dev/null; then
    # Git branch selector
    # Use 'command grep' to bypass aliases for reliable filtering
    fgb() {
        git branch -a | command grep -v HEAD | fzf --preview 'git log --oneline --graph --date=short --color=always --pretty="format:%C(auto)%cd %h%d %s" $(echo {} | command sed "s/.* //")' | command sed "s/.* //"
    }

    # Git checkout with fzf
    fco() {
        local branch
        branch=$(fgb)
        [ -n "$branch" ] && git checkout "$branch"
    }

    # Git log browser
    fgl() {
        git log --graph --color=always --format="%C(auto)%h%d %s %C(black)%C(bold)%cr" "$@" |
            fzf --ansi --no-sort --reverse --tiebreak=index --bind=ctrl-s:toggle-sort \
                --bind "ctrl-m:execute:
                (command grep -o '[a-f0-9]\{7\}' | head -1 |
                xargs -I % sh -c 'git show --color=always % | less -R') <<< '{}'"
    }
fi

# GitHub Actions (act) aliases
if command -v act &>/dev/null; then
    alias act-list='act -l'
    alias act-dry='act -n'
    alias act-ci='act push'
    alias act-pr='act pull_request'
fi

# GitLab CLI aliases
if command -v glab &>/dev/null; then
    alias gl='glab'
    alias glmr='glab mr create'
    alias glmrs='glab mr list'
    alias glmrv='glab mr view'
    alias glis='glab issue list'
    alias gliv='glab issue view'
    alias glpipe='glab pipeline list'
    alias glci='glab ci view'
fi

# golem shortcut — a terse `golem attach <N>` for attaching to issue N's golem
# session during parallel-golem orchestration. The underlying script lives in the
# librarian `workflow` plugin (scripts/golem-attach.sh), so the shortcut is
# defined ONLY when that plugin is installed and locatable — a broken alias that
# errors on every shell without the plugin would be worse than no alias.
#
# Resolution goes through workflow-scripts-dir.sh (installed on PATH by
# dev-tools.sh), the same hardened resolver the justfile golem recipes use: it
# finds the installed plugin's scripts dir dynamically, so a `claude plugin
# update` never strands the shortcut at a stale version path. Gate the definition
# at source time (define-only-if-installed) but re-resolve inside the function at
# call time — bash has no closures, and re-resolving picks up a plugin update
# without needing a fresh shell. (#731)
if command -v workflow-scripts-dir.sh &>/dev/null &&
    _golem_scripts="$(workflow-scripts-dir.sh 2>/dev/null)" &&
    [ -n "$_golem_scripts" ] && [ -x "$_golem_scripts/golem-attach.sh" ]; then
    golem() {
        local scripts
        scripts="$(workflow-scripts-dir.sh 2>/dev/null || true)"
        case "${1:-}" in
            attach)
                shift
                if [ -n "$scripts" ] && [ -x "$scripts/golem-attach.sh" ]; then
                    "$scripts/golem-attach.sh" "$@"
                else
                    command echo "golem: librarian workflow plugin scripts not found" >&2
                    return 1
                fi
                ;;
            *)
                command echo "usage: golem attach <N>" >&2
                return 2
                ;;
        esac
    }
    unset _golem_scripts
fi
