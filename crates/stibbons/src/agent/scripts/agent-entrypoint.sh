#!/bin/bash
# Agent container entrypoint — generic version managed by stibbons.
#
# Runs the container lifecycle, then launches the autonomous golem pipeline for
# one issue (per the provision-agent skill), NOT a bare login shell. Attach to
# watch:  docker exec -it <container> tmux attach -t claude
#
# Lifecycle:
#   1. Derive agent number/suffix from the hostname (agent-N).
#   2. First-time init (marker-gated) + per-start setup.
#   3. Signal readiness (agent-ready marker that `stibbons agent connect` polls).
#   4. Launch the golem pipeline (or a plain interactive session with no issue).
#
# Environment (set by `stibbons agent start`):
#   PROJECT_NAME   — project name for the marker directory
#   AGENT_REPOS    — comma-separated repo names for the init scripts
#   AGENT_ISSUE    — numeric issue id → autonomous pipeline; empty → interactive
#   REVIEW_MAX_CYCLES, PRE_REVIEW_STRICT, REVIEW_STRICT, AUTOMERGE,
#   AUTOMERGE_AUTONOMOUS — optional pipeline tuning (passed through if set)

set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="${PROJECT_NAME:-project}"
MARKER_DIR="/home/$(whoami)/.local/state/${PROJECT_NAME}"
STATUS_DIR="/workspace/.worktrees/.status"

# Ambient autonomy opt-in (see next-issue / next-issue-ship contract).
export NEXT_ISSUE_AUTONOMOUS=1
export REVIEW_MAX_CYCLES="${REVIEW_MAX_CYCLES:-3}"

log_info() { echo "[ENTRY] $*"; }
log_success() { echo "[OK]    $*"; }
log_warn() { echo "[WARN]  $*" >&2; }

now() { command date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ""; }

# Determine agent number from the hostname (agent-N).
AGENT_NUM=""
if [[ "$(command hostname 2>/dev/null)" =~ ^agent-([0-9]+)$ ]]; then
    AGENT_NUM="${BASH_REMATCH[1]}"
fi
AGENT_NUM="${AGENT_NUM:-1}"
AGENT_SUFFIX="$(printf 'agent%02d' "${AGENT_NUM}")"
AGENT_ID="${AGENT_ID:-${AGENT_SUFFIX}}"
export AGENT_NUM AGENT_SUFFIX AGENT_ID

STATUS_FILE="${STATUS_DIR}/${AGENT_ID}.json"
ISSUE="${AGENT_ISSUE:-}"

# Minimal golem-status writer (cache shape only — the orchestrator's PR/label
# poll is authoritative). The full background PR poller + typed reader are a
# follow-up; this records the coarse state transitions the auth gate needs.
write_status() {
    local state="$1" err="${2:-}"
    command mkdir -p "${STATUS_DIR}" 2>/dev/null || return 0
    {
        printf '{\n'
        printf '  "golem": "%s",\n' "${AGENT_ID}"
        printf '  "kind": "container",\n'
        if [[ "${ISSUE}" =~ ^[0-9]+$ ]]; then
            printf '  "issue": %s,\n' "${ISSUE}"
        fi
        printf '  "state": "%s",\n' "${state}"
        if [[ -n "${err}" ]]; then
            printf '  "errors": ["%s"],\n' "${err//\"/\'}"
        fi
        printf '  "last_activity": "%s"\n' "$(now)"
        printf '}\n'
    } >"${STATUS_FILE}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Container lifecycle: first-time init + per-start setup + readiness marker.
# ---------------------------------------------------------------------------
command mkdir -p "${MARKER_DIR}"
write_status starting

if [[ ! -f "${MARKER_DIR}/agent-initialized" ]]; then
    log_info "First-time initialization for agent ${AGENT_NUM}..."
    if bash "${SCRIPTS_DIR}/agent-init.sh"; then
        touch "${MARKER_DIR}/agent-initialized"
    else
        log_warn "agent-init.sh reported issues (continuing)"
    fi
fi

bash "${SCRIPTS_DIR}/agent-start.sh" || log_warn "agent-start.sh reported issues (continuing)"

# Signal readiness — `stibbons agent connect` polls for this file.
touch "${MARKER_DIR}/agent-ready"
log_success "Agent ${AGENT_NUM} ready"

# ---------------------------------------------------------------------------
# Golem pipeline launch.
# ---------------------------------------------------------------------------
# No (or non-numeric) issue → plain interactive session. ISSUE is interpolated
# into a single-quoted `claude '/next-issue ${ISSUE} …'` below, so it MUST be a
# bare integer — reject anything else to avoid breaking out of the quoting.
if ! printf '%s' "${ISSUE}" | command grep -qE '^[0-9]+$'; then
    if [[ -n "${ISSUE}" ]]; then
        log_warn "AGENT_ISSUE='${ISSUE}' is not a numeric issue id — starting interactive session"
    fi
    if command -v tmux >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
        tmux new-session -d -s claude "claude"
        log_info "Claude Code started in tmux session 'claude' (interactive)"
        log_info "Attach with: tmux attach -t claude"
    fi
    exec sleep infinity
fi

# Auth precondition — a golem opens PRs and re-requests review, so a working
# gh/GITHUB_TOKEN is required. Fail fast (stay alive for inspection) instead of
# hanging with no human attached.
if command -v setup-gh >/dev/null 2>&1; then
    setup-gh >/dev/null 2>&1 || true
fi
if command -v gh >/dev/null 2>&1 && ! command gh auth status >/dev/null 2>&1; then
    msg="golem auth missing: gh is not authenticated. Set GITHUB_TOKEN (e.g. OP_GITHUB_TOKEN_REF) or run setup-gh before launch."
    log_warn "${msg}"
    write_status error "${msg}"
    exec sleep infinity
fi

write_status working

# Launch the autonomous pipeline in a named tmux session. The prompts are
# chained with `;` (not `&&`): autonomous `/next-issue` invokes ship in-turn, so
# the second prompt is a resume backstop for a premature turn-exit — needed most
# when the first exits non-zero, exactly the case `&&` would skip.
if command -v tmux >/dev/null 2>&1 && command -v claude >/dev/null 2>&1; then
    tmux new-session -d -s claude \
        "claude --permission-mode auto '/next-issue ${ISSUE} --auto' ; claude --permission-mode auto '/next-issue-ship --auto'"
    log_info "Golem pipeline started for issue #${ISSUE} (tmux session 'claude')"
    log_info "Attach with: tmux attach -t claude"
else
    log_warn "tmux or claude not found — cannot launch pipeline; staying alive for inspection"
fi

exec sleep infinity
