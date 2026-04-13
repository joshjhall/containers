# Container Agent Operations

Guide for running parallel container agents that process issues independently.

## Architecture

```text
┌─────────────────────────────────────────────────┐
│  VSCode Devcontainer (orchestrator)             │
│    - Human interaction (review, merge, plan)    │
│    - /orchestrate (status, merge, sync, spawn)  │
│    - Reads .worktrees/.status/ for agent state  │
└──────────┬──────────┬──────────┬────────────────┘
           │          │          │
     ┌─────┴──┐ ┌─────┴──┐ ┌────┴───┐
     │agent01 │ │agent02 �� │agent03 │  Headless containers
     │ tmux   │ │ tmux   │ │ tmux   │  (SKIP_LSP_INSTALL=true)
     │ claude │ │ claude │ │ claude │
     └────────┘ └────────┘ └─���──────┘
```

Each agent runs in its own container with:

- Its own git worktree (isolated file changes)
- Claude Code in a named tmux session (human-resumable)
- Same language tools as the devcontainer (minus LSP servers)
- Status coordination via `.worktrees/.status/` JSON files

## Quick Start

```bash
# 1. Provision 3 agents
/orchestrate spawn 3

# 2. Check status
/orchestrate status

# 3. Merge completed agent work
/orchestrate merge agent01

# 4. Review the merge
/orchestrate review

# 5. Sync other agents with merged changes
/orchestrate sync

# 6. Tear down when done
/orchestrate teardown all
```

## Provisioning

The `/provision-agent` skill (invoked by `/orchestrate spawn`) handles:

1. Reading your devcontainer config to determine required features
1. Generating `.worktrees/docker-compose.agents.yml` with `SKIP_LSP_INSTALL=true`
1. Building the agent image (first build may be slow; reused afterward)
1. Creating git worktrees for each agent
1. Starting containers with Claude Code in tmux sessions

### First Build Time Estimates

| Stack             | Approximate Build Time |
| ----------------- | ---------------------- |
| Python only       | ~5 min                 |
| Python + Node     | ~8 min                 |
| Full stack (Rust) | ~30 min                |
| Subsequent builds | ~30 sec (cached)       |

## Human Interaction

### Attaching to an Agent

Each agent runs Claude Code in a tmux session named `claude`:

```bash
docker exec -it project-agent01-1 tmux attach -t claude
```

You'll see Claude Code's terminal interface. You can:

- Review what the agent is doing
- Provide input or corrections
- Run `/next-issue-ship` manually if needed

Detach with `Ctrl-b d` (standard tmux detach).

### Monitoring

Check all agent status:

```bash
/orchestrate status
```

This reads `.worktrees/.status/agent{N}.json` files and shows a table with
each agent's state, current issue, phase, and commit count.

## Agent Lifecycle

```text
ASSIGN → WORK → SIGNAL → REVIEW → SYNC → NEXT (or TEARDOWN)
```

1. **ASSIGN**: Orchestrator creates worktree + container, assigns issue
1. **WORK**: Agent runs `/next-issue` pipeline inside container
1. **SIGNAL**: Agent completes, status file shows `review-ready`
1. **REVIEW**: Orchestrator runs `/orchestrate merge` + `/orchestrate review`
1. **SYNC**: Orchestrator runs `/orchestrate sync` to update all agents
1. **NEXT**: Orchestrator assigns next issue, or tears down idle agents

## Conflict Resolution

The `rebase-agent` handles trivial conflicts automatically during merge/sync:

- **Lock files**: Regenerate from manifest (npm install, cargo generate-lockfile)
- **Generated files**: Re-run the generator
- **Import ordering**: Combine, deduplicate, sort by language convention
- **Version numbers**: Take the higher version

Non-trivial conflicts (logic changes, API modifications) are escalated to the
human orchestrator.

## Resource Management

Default resource limits per agent:

| Resource | Limit   | Reservation |
| -------- | ------- | ----------- |
| CPU      | 2 cores | 0.5 cores   |
| Memory   | 4 GB    | 1 GB        |

Adjust in `.worktrees/docker-compose.agents.yml` under `deploy.resources`.

### Capacity Planning

| Agents | Recommended Host RAM | Recommended Host CPU |
| ------ | -------------------- | -------------------- |
| 1-2    | 16 GB                | 4 cores              |
| 3-5    | 32 GB                | 8 cores              |
| 5+     | 64 GB                | 16 cores             |

## Teardown

```bash
# Single agent
/provision-agent teardown agent01

# All agents
/provision-agent teardown all
```

Teardown stops containers, removes worktrees (after confirming no unmerged
work), and cleans up status files.

## Troubleshooting

### Agent container won't start

Check the docker-compose file exists and is valid:

```bash
docker compose -f .worktrees/docker-compose.agents.yml config
```

### Agent tmux session not found

The tmux session may not have started. Check container logs:

```bash
docker logs project-agent01-1
```

Manually start Claude in tmux:

```bash
docker exec -it project-agent01-1 bash -c \
    "tmux new-session -d -s claude 'claude --dangerously-skip-permissions'"
```

### Status files out of date

Agent status files are written by the agent's Claude instance. If an agent
crashes, the status file may show `working` when the agent is actually stopped.
Check container state:

```bash
docker ps --filter "name=agent"
```

### Merge conflicts during sync

If `/orchestrate sync` skips an agent due to conflicts, the agent will pick
up changes on the next sync cycle. Alternatively, merge the agent's work first
(`/orchestrate merge`), then sync.
