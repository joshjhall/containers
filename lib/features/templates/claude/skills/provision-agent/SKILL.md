---
description: Provision headless agent containers from devcontainer config. Generates docker-compose, creates worktrees, starts containers with tmux-attached Claude Code sessions. Use when spinning up container agents for parallel work.
---

# Provision Agent

Creates and manages headless agent containers for parallel issue processing.
Reads the project's devcontainer configuration to generate a lean agent
container with the same language tools but without LSP servers or IDE support.

Each agent runs Claude Code in a named `tmux` session — the human can attach
directly via `docker exec -it <container> tmux attach -t claude`.

**Invocation patterns:**

- `/provision-agent` or `/provision-agent setup` → provision new agents
- `/provision-agent teardown <agent>` → stop and remove an agent
- `/provision-agent teardown all` → stop and remove all agents

## Step 1 — Discover Project Config

1. **Find devcontainer config** — check in order:

   ```bash
   # Check for devcontainer docker-compose
   ls .devcontainer/docker-compose.yml 2>/dev/null
   ls .devcontainer/docker-compose.yaml 2>/dev/null
   # Check for standalone docker-compose
   ls docker-compose.yml 2>/dev/null
   ```

1. **Extract build configuration** from the compose file:

   - Base image (`build.args.BASE_IMAGE`)
   - Build args — all `INCLUDE_*` flags that are `true`
   - Dockerfile path (`build.dockerfile` or `build.context`)
   - Volumes (especially cache volumes)
   - Environment variables
   - Supporting services (postgres, redis, etc.)
   - Capabilities (`cap_add`, `devices`)

1. **Show config summary** to the user:

   ```text
   Devcontainer config found:
     Base: mcr.microsoft.com/devcontainers/base:trixie
     Features: python-dev, node-dev, rust-dev, golang-dev, docker, dev-tools
     Services: postgres, redis
     Capabilities: SYS_ADMIN, /dev/fuse
   ```

## Step 2 — Generate Agent Docker Compose

1. **Create directories**:

   ```bash
   mkdir -p .worktrees/.status
   ```

1. **Write `.worktrees/docker-compose.agents.yml`** based on devcontainer config
   with these transforms:

   - **Same base image and Dockerfile** as devcontainer
   - **Same `INCLUDE_*` flags** — agents need the same language tools
   - **Add `SKIP_LSP_INSTALL=true`** — no IDE, no LSP servers needed
   - **Working directory**: `/workspace/{project}` (same as devcontainer)
   - **Volumes**: bind-mount `.worktrees/agent{N}/` as the project source,
     plus shared `.worktrees/.status/` for coordination
   - **Supporting services**: same services as devcontainer, with per-agent
     namespacing (e.g., separate database per agent)
   - **Resource limits**: `deploy.resources.limits` of 2 CPUs / 4GB RAM
     (configurable)
   - **Init system**: `init: true` for tini zombie reaping
   - **Capabilities**: same as devcontainer (`cap_add`, `devices`)
   - **Command**: `sleep infinity` (entrypoint handles startup, tmux starts
     Claude)

   Example generated service:

   ```yaml
   services:
     agent01:
       build:
         context: ..
         dockerfile: containers/Dockerfile
         args:
           <<: *common-build-args
           SKIP_LSP_INSTALL: "true"
       volumes:
         - ../:/workspace/project:ro
         - ./.worktrees/agent01:/workspace/project-worktree
         - ./.status:/workspace/.worktrees/.status
       working_dir: /workspace/project-worktree
       environment:
         AGENT_ID: agent01
         AGENT_MODE: headless
       init: true
       deploy:
         resources:
           limits:
             cpus: "2"
             memory: 4G
       command: ["sleep", "infinity"]
   ```

1. **Write `.worktrees/agent-entrypoint.sh`** — a wrapper script that starts
   Claude Code in a tmux session:

   ```bash
   #!/bin/bash
   # Agent entrypoint — starts Claude Code in a named tmux session
   # The human can attach via: docker exec -it <container> tmux attach -t claude

   AGENT_ID="${AGENT_ID:-agent01}"
   ISSUE="${AGENT_ISSUE:-}"

   # Start a named tmux session with Claude Code
   if [ -n "$ISSUE" ]; then
       tmux new-session -d -s claude \
           "claude --dangerously-skip-permissions '/next-issue ${ISSUE}'"
   else
       tmux new-session -d -s claude \
           "claude --dangerously-skip-permissions"
   fi

   echo "Claude Code started in tmux session 'claude'"
   echo "Attach with: tmux attach -t claude"

   # Keep container alive
   exec sleep infinity
   ```

## Step 3 — Build Agent Image

1. **Check if image already exists**:

   ```bash
   docker images -q "$(basename $(pwd)):agent-runner" 2>/dev/null
   ```

1. **If not built**, build with progress reporting:

   ```bash
   docker compose -f .worktrees/docker-compose.agents.yml build agent01
   ```

   Tell the user: "Building agent image. First build may take {estimate}
   based on {feature_count} features. Subsequent agents reuse this image."

1. **If already built**, skip and report: "Agent image ready."

## Step 4 — Create Worktrees and Start Containers

For each agent to provision (e.g., agent01 through agent{N}):

1. **Create git worktree**:

   ```bash
   git worktree add .worktrees/agent{N} -b agent{N}
   ```

1. **Start container**:

   ```bash
   docker compose -f .worktrees/docker-compose.agents.yml up -d agent{N}
   ```

1. **Write initial status file** to `.worktrees/.status/agent{N}.json`:

   ```json
   {
     "agent": "agent{N}",
     "container": "{project}-agent{N}-1",
     "state": "starting",
     "branch": "agent{N}",
     "started": "{ISO datetime}",
     "last_activity": "{ISO datetime}",
     "errors": []
   }
   ```

1. **Start Claude Code in tmux** inside the container:

   ```bash
   docker exec -d {container} bash -c \
       "tmux new-session -d -s claude 'claude --dangerously-skip-permissions'"
   ```

## Step 5 — Report

Show a summary table with access commands:

```text
# Agents Provisioned

| # | Agent    | Container          | Branch   | Access Command                                           |
|---|----------|--------------------|----------|----------------------------------------------------------|
| 1 | agent01  | project-agent01-1  | agent01  | docker exec -it project-agent01-1 tmux attach -t claude  |
| 2 | agent02  | project-agent02-1  | agent02  | docker exec -it project-agent02-1 tmux attach -t claude  |
| 3 | agent03  | project-agent03-1  | agent03  | docker exec -it project-agent03-1 tmux attach -t claude  |

To assign issues, use: /orchestrate spawn (assigns from priority queue)
To interact directly: docker exec -it <container> tmux attach -t claude
To check status: /orchestrate status
```

## Teardown

### Single Agent

`/provision-agent teardown agent01`:

1. **Stop and remove container**:

   ```bash
   docker compose -f .worktrees/docker-compose.agents.yml stop agent01
   docker compose -f .worktrees/docker-compose.agents.yml rm -f agent01
   ```

1. **Check for uncommitted work**:

   ```bash
   cd .worktrees/agent01
   git status --porcelain
   git log --oneline agent01 ^main
   ```

   If there are uncommitted changes or unmerged commits, warn the user and
   ask for confirmation before removing the worktree.

1. **Remove worktree and branch** (if confirmed):

   ```bash
   git worktree remove .worktrees/agent01
   git branch -d agent01
   ```

1. **Remove status file**: Delete `.worktrees/.status/agent01.json`

### All Agents

`/provision-agent teardown all`:

Iterate over all agent status files in `.worktrees/.status/` and tear down
each one. Warn about any agents with unmerged work.

After all agents are removed, clean up:

```bash
# Remove docker-compose if no agents remain
rm -f .worktrees/docker-compose.agents.yml
rm -f .worktrees/agent-entrypoint.sh

# Remove .status directory if empty
rmdir .worktrees/.status 2>/dev/null
```

## When to Use

- Spinning up parallel agents for batch issue processing
- `/orchestrate spawn` delegates here for container creation
- Setting up a container agent environment for the first time
- Tearing down agents after work is complete

## When NOT to Use

- Ephemeral worktrees (Mode 2) — use `git worktree add` directly
- Single-session work — no container needed
- Projects without a devcontainer or Dockerfile
