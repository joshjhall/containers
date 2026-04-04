---
description: Multi-agent orchestration for parallel worktree workflows. Check agent status, merge agent commits, review merged work, sync agent branches, select execution modes, and manage container agents. Use when coordinating 2-5 agents working in separate worktrees, reviewing agent progress, or integrating agent work.
---

# Orchestrate

**Companion files**:

- `merge-protocol.md` — sync point tracking, conflict resolution, test runner
  detection, squash vs merge, review dispatch, sync protocol
- `mode-protocol.md` — execution mode selection, decision tree, tradeoff
  explanations

Load the relevant companion before each phase.

**Invocation patterns:**

- `/orchestrate` or `/orchestrate status` → Phase 1 (agent status)
- `/orchestrate mode` → Phase 0 (mode selection for next task)
- `/orchestrate merge <N>` or `/orchestrate merge <branch>` → Phase 2 (merge one agent)
- `/orchestrate merge all` → Phase 2 for all agents with pending commits
- `/orchestrate review` → Phase 3 (review latest merge)
- `/orchestrate sync` → Phase 4 (sync orchestrator into agent branches)
- `/orchestrate spawn <N>` → Phase 5 (provision N container agents)
- `/orchestrate teardown <agent>` → Phase 5 (stop and remove agent container)

## Phase 0 — Mode Selection

Load `mode-protocol.md` before starting.

1. **Gather inputs**:

   ```bash
   # Current worktree count
   git worktree list | /usr/bin/wc -l

   # Running agent containers
   docker ps --filter "name=agent" --format "{{.Names}}" 2>/dev/null

   # Check if agent runner image exists
   docker images -q "*:agent-runner" 2>/dev/null
   ```

1. **Assess the task** — from the issue labels or user description:

   - Effort label (`effort/trivial` through `effort/large`)
   - Batch size (single issue or multiple)
   - File overlap risk with current work

1. **Recommend mode** using the decision tree in `mode-protocol.md`

1. **Present recommendation** with tradeoff explanation to the user using
   `AskUserQuestion`:

   - Mode 1a: Current branch
   - Mode 1b: New branch
   - Mode 2: Ephemeral worktree
   - Mode 3: Container agent

1. **Execute based on selection**:

   - Mode 1a/1b: Proceed with normal `/next-issue` workflow
   - Mode 2: Create worktree via `git worktree add .worktrees/issue-{N}`
   - Mode 3: Invoke `/provision-agent` to build and start container

## Phase 1 — Agent Status

1. **Discover agent worktrees** via primary and fallback methods:

   ```bash
   # Primary: git worktree list (filter agent branches)
   git worktree list --porcelain | grep -E 'branch refs/heads/agent'

   # Secondary: directory scan
   ls -d .worktrees/agent*/ 2>/dev/null
   ```

1. **Read container agent status files** (if they exist):

   ```bash
   # Container agent status from JSON files
   ls .worktrees/.status/agent*.json 2>/dev/null
   ```

   For each status file, extract: `state`, `issue`, `phase`, `phase_detail`,
   `commits`, `last_activity`.

1. **For each agent branch**, gather git info:

   ```bash
   # Latest commit info
   git log -1 --format='%h %s (%cr)' <agent-branch>

   # Divergence point from current branch
   MERGE_BASE=$(git merge-base HEAD <agent-branch>)

   # New commits since divergence
   git log --oneline "$MERGE_BASE"..<agent-branch>
   ```

1. **Check for associated issues** (optional — skip if `gh`/`glab` unavailable):

   ```bash
   gh issue list --label "status/commit-pending" --state open --json number,title,assignees
   gh issue list --label "status/in-progress" --state open --json number,title,assignees
   ```

1. **Output a status table** — merge git info with container status:

   ```text
   # Agent Status

   | # | Branch   | State        | Latest Commit        | Age   | Commits | Issue | Phase          |
   |---|----------|--------------|----------------------|-------|---------|-------|----------------|
   | 1 | agent01  | working      | abc1234 feat: add X  | 2h    | 3       | #42   | implement      |
   | 2 | agent02  | review-ready | def5678 fix: handle Y| 30m   | 1       | #55   | ship           |
   | 3 | agent03  | idle         | (no new commits)     | —     | 0       | —     | —              |
   ```

   Container agents show `State` from their status file. Worktree-only agents
   (no status file) infer state from commit activity.

## Phase 2 — Merge

Load `merge-protocol.md` before starting.

1. **Resolve agent identifier**:

   - Numeric (`1`, `2`) → map to agent branch from Phase 1 table
   - Branch name (`agent01`) → use directly
   - `all` → iterate over all agents with pending commits

1. **Preview changes**:

   ```bash
   MERGE_BASE=$(git merge-base HEAD <agent-branch>)
   # Show commit summary
   git log --oneline "$MERGE_BASE"..<agent-branch>
   # Show diffstat
   git diff --stat "$MERGE_BASE"..<agent-branch>
   ```

   Show the preview to the user and confirm before proceeding.

1. **Merge** (default: merge commit for history preservation):

   ```bash
   # Default: merge with descriptive message
   git merge --no-ff <agent-branch> -m "merge(<agent-branch>): <summary of changes>"
   ```

   If the user requests squash:

   ```bash
   git merge --squash <agent-branch>
   git commit -m "feat(<scope>): <description summarized from agent commits>"
   ```

1. **Handle conflicts**:

   - Show conflicted files: `git diff --name-only --diff-filter=U`
   - **Trivial conflicts** (lockfiles, imports, versions, generated files):
     dispatch `rebase-agent` for automated resolution
   - **Non-trivial conflicts** (logic, architecture): display conflict markers
     and ask the user for resolution guidance
   - After resolving, complete the merge: `git add . && git commit`

1. **Run tests** (see `merge-protocol.md` for test runner detection):

   ```bash
   # Auto-detect and run the project's test suite
   # npm test | pytest | go test ./... | cargo test | etc.
   ```

   Report test results. If tests fail, warn the user but do not auto-revert.

1. **Update container status** (if merging a container agent):

   ```bash
   # Update status file to reflect merged state
   # .worktrees/.status/agent{N}.json → state: "idle"
   ```

1. **Report**: Show final merge result with commit hash and summary.

1. **Suggest context reset** — after reporting the merge result:

   > Merge complete. If context is large from the diff review, consider
   > `/clear` — the merge is committed and the next operation starts fresh.

   This is advisory — continue normally if the user declines.

## Phase 3 — Review

Load `merge-protocol.md` before starting (Review Protocol section).

1. **Identify the latest merge commit**:

   ```bash
   MERGE_COMMIT=$(git log -1 --merges --format='%H')
   ```

   If no merge commit is found, inform the user and stop.

1. **Show merge summary**:

   ```bash
   git log -1 --format='%h %s (%cr)' "$MERGE_COMMIT"
   git diff --stat "${MERGE_COMMIT}^1" "${MERGE_COMMIT}"
   ```

1. **Dispatch `code-reviewer` agent** on the merge diff:

   - Scope the review to only files changed in the merge commit
   - Pass the diff via `git diff "${MERGE_COMMIT}^1" "${MERGE_COMMIT}"`
   - Collect findings: bugs, security issues, performance, style

1. **Optionally dispatch `test-writer` agent** if:

   - code-reviewer identified missing test coverage, OR
   - New public APIs were introduced without corresponding tests

1. **Apply corrections** in a single commit:

   ```text
   fix(review): {summary of corrections}

   {bullet list of changes made}

   Reviewed-by: orchestrate Phase 3
   ```

   If no corrections are needed, skip the commit.

1. **Run tests** (see `merge-protocol.md` for test runner detection):

   Report test results. If tests fail, warn the user but do not auto-revert.

1. **Report** a summary table:

   ```text
   # Review Summary

   | Category       | Findings | Auto-Fixed | Flagged |
   |----------------|----------|------------|---------|
   | Bugs           | 1        | 1          | 0       |
   | Security       | 0        | 0          | 0       |
   | Performance    | 1        | 0          | 1       |
   | Style          | 2        | 2          | 0       |
   | Test coverage  | 1        | 1          | 0       |

   Correction commit: abc1234
   Tests: ✓ passing
   ```

## Phase 4 — Sync

Load `merge-protocol.md` before starting (Sync Protocol section).

1. **Record the current branch** (orchestrator branch):

   ```bash
   ORCH_BRANCH=$(git branch --show-current)
   ```

1. **Discover agent branches**:

   ```bash
   git branch --list 'agent*' | /usr/bin/sort
   ```

   If no agent branches found, inform the user and stop.

1. **For each agent branch** (in order: agent01, agent02, ...):

   ```bash
   git checkout <agent-branch>
   git merge "$ORCH_BRANCH" -m "sync: merge orchestrator updates"
   ```

   - **If merge succeeds**: verify merge-base advanced, continue
   - **If conflicts**: `git merge --abort`, log the skip, continue to next

1. **Return to orchestrator branch**:

   ```bash
   git checkout "$ORCH_BRANCH"
   ```

1. **Update issue labels** — for issues associated with successfully synced
   agents, remove in-flight status labels:

   - GitHub: `gh issue edit {N} --remove-label "status/commit-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --unlabel "status/commit-pending" --unlabel "status/in-progress"`

1. **Report** a sync summary table:

   ```text
   # Sync Summary

   | # | Branch   | Status    | New Merge Base |
   |---|----------|-----------|----------------|
   | 1 | agent01  | ✓ synced  | abc1234        |
   | 2 | agent02  | ✗ skipped | (conflicts)    |
   | 3 | agent03  | ✓ synced  | def5678        |
   ```

   If any branches were skipped, note they will pick up changes on the next
   sync cycle.

1. **Suggest context reset** — after reporting the sync summary:

   > Sync complete. Consider `/clear` if context is large — sync output is
   > mechanical and not needed for subsequent operations.

   This is advisory — continue normally if the user declines.

## Phase 5 — Container Management

### Spawn

Invoked via `/orchestrate spawn <N>` (where N is the number of agents).

1. **Check prerequisites**:

   - Docker available: `docker info > /dev/null 2>&1`
   - Git root accessible: `git rev-parse --show-toplevel`

1. **Invoke `/provision-agent`** to handle container setup:

   - The provision-agent skill reads the devcontainer config, generates the
     agent docker-compose, builds images, creates worktrees, and starts
     containers
   - Each agent gets a tmux session running Claude Code

1. **Assign issues** to agents:

   - Query available issues using the priority ordering from
     `next-issue/state-format.md`
   - Assign round-robin by estimated effort
   - Write initial status files to `.worktrees/.status/`

1. **Report** the spawned agents with access commands:

   ```text
   # Agents Spawned

   | # | Agent    | Container          | Issue | Access                                           |
   |---|----------|--------------------|-------|--------------------------------------------------|
   | 1 | agent01  | project-agent01-1  | #142  | docker exec -it project-agent01-1 tmux attach -t claude |
   | 2 | agent02  | project-agent02-1  | #89   | docker exec -it project-agent02-1 tmux attach -t claude |
   | 3 | agent03  | project-agent03-1  | #201  | docker exec -it project-agent03-1 tmux attach -t claude |
   ```

### Teardown

Invoked via `/orchestrate teardown <agent>` or `/orchestrate teardown all`.

1. **Stop container**: `docker compose -f .worktrees/docker-compose.agents.yml stop <agent>`

1. **Remove container**: `docker compose -f .worktrees/docker-compose.agents.yml rm -f <agent>`

1. **Remove worktree** (if branch fully merged):

   ```bash
   git worktree remove .worktrees/<agent>
   git branch -d <agent>
   ```

1. **Clean status file**: Remove `.worktrees/.status/<agent>.json`

1. **Report** teardown result

## When to Use

- Checking progress of parallel agents working in worktrees
- Selecting execution mode for new tasks (`/orchestrate mode`)
- Integrating completed agent work into the main development branch
- Reviewing merged agent work for correctness and quality
- Syncing agent branches with the latest orchestrator state
- Spawning container agents for batch processing (`/orchestrate spawn`)
- Coordinating multi-agent workflows (2-5 agents)
- After agents signal completion (e.g., via `status/commit-pending` label)

## When NOT to Use

- Single-agent workflows (no worktrees to orchestrate)
- Cross-repository coordination (handle manually or via PRs)
- When agents are still actively working (check status first, merge when ready)
- For PR-based workflows where agents push branches for review (use standard PR flow)
