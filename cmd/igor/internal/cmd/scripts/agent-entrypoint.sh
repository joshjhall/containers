#!/bin/bash
# Agent container entrypoint — generic version managed by igor.
#
# Handles:
# 1. Determine agent number from hostname (agent-N)
# 2. Run first-time initialization (marker-gated)
# 3. Run per-start setup
# 4. Signal readiness and exec main command
#
# Environment (set by igor agent start):
#   PROJECT_NAME   — project name for marker directory
#   AGENT_REPOS    — comma-separated repo names for init scripts

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="${PROJECT_NAME:-project}"
MARKER_DIR="/home/$(whoami)/.local/state/${PROJECT_NAME}"

log_info()    { echo "[ENTRY] $*"; }
log_success() { echo "[OK]    $*"; }
log_warn()    { echo "[WARN]  $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }

# ============================================================================
# Determine Agent Number from hostname (format: agent-N)
# ============================================================================
if [[ "$(hostname)" =~ ^agent-([0-9]+)$ ]]; then
    AGENT_NUM="${BASH_REMATCH[1]}"
else
    log_error "Cannot determine agent number from hostname: $(hostname)"
    log_error "Expected format: agent-N (e.g., agent-1)"
    exit 1
fi

export AGENT_NUM
AGENT_SUFFIX="agent$(printf '%02d' "$AGENT_NUM")"
export AGENT_SUFFIX

log_info "Agent ${AGENT_NUM} entrypoint starting (suffix: ${AGENT_SUFFIX})"

# ============================================================================
# First-time Initialization (marker-gated)
# ============================================================================
mkdir -p "${MARKER_DIR}"
INIT_MARKER="${MARKER_DIR}/agent-initialized"

if [[ ! -f "${INIT_MARKER}" ]]; then
    log_info "First-time startup detected, running initialization..."
    if [[ -x "${SCRIPTS_DIR}/agent-init.sh" ]]; then
        bash "${SCRIPTS_DIR}/agent-init.sh"
        touch "${INIT_MARKER}"
        log_success "Initialization complete"
    else
        log_warn "agent-init.sh not found, skipping initialization"
    fi
else
    log_info "Already initialized, skipping first-time setup"
fi

# ============================================================================
# Per-Start Setup
# ============================================================================
if [[ -x "${SCRIPTS_DIR}/agent-start.sh" ]]; then
    bash "${SCRIPTS_DIR}/agent-start.sh"
else
    log_warn "agent-start.sh not found, skipping per-start setup"
fi

# ============================================================================
# Signal Ready
# ============================================================================
touch "${MARKER_DIR}/agent-ready"
log_success "Agent ${AGENT_NUM} ready for connections"

# ============================================================================
# Execute Command or Keep Alive
# ============================================================================
if [[ $# -gt 0 ]]; then
    log_info "Executing command: $*"
    exec "$@"
else
    log_info "Keeping container alive..."
    exec sleep infinity
fi
