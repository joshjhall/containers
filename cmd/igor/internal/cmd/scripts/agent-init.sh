#!/bin/bash
# Agent initialization — runs once on first container start.
#
# Handles first-time setup: git hooks, dependency fetching.
# Called by agent-entrypoint.sh when .agent-initialized marker doesn't exist.
#
# Environment (set by entrypoint):
#   AGENT_NUM      — agent number (1-N)
#   AGENT_SUFFIX   — agent suffix (agent01, agent02, etc.)
#   AGENT_REPOS    — comma-separated repo names (set by igor)

set -euo pipefail

log_info()    { echo "[INIT]  $*"; }
log_success() { echo "[OK]    $*"; }
log_warn()    { echo "[WARN]  $*" >&2; }

log_info "Initializing agent ${AGENT_NUM:-?} (first-time setup)..."

# ============================================================================
# Git Hooks Configuration
# ============================================================================
# Worktrees share .git/hooks with the main repo. Configure each worktree
# to use the existing hooks from its main repo.

if [[ -n "${AGENT_REPOS:-}" ]]; then
    log_info "Configuring git hooks for worktrees..."
    IFS=',' read -ra REPOS <<< "${AGENT_REPOS}"
    for repo in "${REPOS[@]}"; do
        worktree="/workspace/${repo}-${AGENT_SUFFIX}"
        main_hooks="/workspace/${repo}/.git/hooks"
        if [[ -d "$worktree" && -d "$main_hooks" ]]; then
            cd "$worktree"
            git config --worktree core.hooksPath "${main_hooks}" 2>/dev/null || \
                log_warn "  ${repo}: failed to configure hooksPath"
            log_success "  ${repo}: hooks configured"
        fi
    done
fi

# ============================================================================
# Dependency Fetching (detect project type)
# ============================================================================
if [[ -n "${AGENT_REPOS:-}" ]]; then
    log_info "Fetching dependencies for available repos..."
    IFS=',' read -ra REPOS <<< "${AGENT_REPOS}"
    for repo in "${REPOS[@]}"; do
        worktree="/workspace/${repo}-${AGENT_SUFFIX}"
        [[ -d "$worktree" ]] || continue
        cd "$worktree"

        if [[ -f "Cargo.toml" ]] && command -v cargo &>/dev/null; then
            log_info "  ${repo}: fetching Rust dependencies..."
            cargo fetch 2>/dev/null || log_warn "  ${repo}: cargo fetch had issues"
        fi

        if [[ -f "package.json" ]]; then
            if [[ -f "pnpm-lock.yaml" ]] && command -v pnpm &>/dev/null; then
                log_info "  ${repo}: installing pnpm dependencies..."
                pnpm install 2>/dev/null || log_warn "  ${repo}: pnpm install had issues"
            elif [[ -f "yarn.lock" ]] && command -v yarn &>/dev/null; then
                log_info "  ${repo}: installing yarn dependencies..."
                yarn install 2>/dev/null || log_warn "  ${repo}: yarn install had issues"
            elif [[ -f "package-lock.json" ]] && command -v npm &>/dev/null; then
                log_info "  ${repo}: installing npm dependencies..."
                npm ci 2>/dev/null || log_warn "  ${repo}: npm ci had issues"
            fi
        fi
    done
fi

log_success "Agent ${AGENT_NUM:-?} initialization complete"
