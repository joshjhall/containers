# Orchestrate — Mode Protocol

Reference companion for `SKILL.md`. Load this when selecting an execution mode
for a task or batch of tasks. Documents the four execution modes, decision
tree, and tradeoff explanations.

______________________________________________________________________

## Four Execution Modes

| Mode | Name               | Description                                   | Concurrency |
| ---- | ------------------ | --------------------------------------------- | ----------- |
| 1a   | Current branch     | Work directly on the current branch           | 1 (serial)  |
| 1b   | New branch         | Create branch, work, merge or PR              | 1 (serial)  |
| 2    | Ephemeral worktree | `git worktree add` in current session         | 2-3 max     |
| 3    | Container agent    | Headless container with own worktree and tmux | 3-5 agents  |

### Mode 1a: Current Branch

Work directly on the current branch. Simplest path — no branch management
overhead.

**Best for**: Trivial fixes, single-file changes, `effort/trivial` issues.

**Tradeoffs**: No isolation, no clean diff. If something goes wrong, `git stash`
or `git reset` is the recovery path.

### Mode 1b: New Branch

Create a feature branch, work, then merge or PR.

**Best for**: Focused work needing a clean diff, `effort/small` issues, work
that will be reviewed via PR.

**Tradeoffs**: Branch management overhead is minimal. Conflicts possible if
other work lands on main while working.

### Mode 2: Ephemeral Worktree

Create a git worktree in `.worktrees/issue-{N}/` and work there using the
`Task` tool with `isolation: "worktree"` or a direct shell in the worktree.

**Best for**: Parallel tangent work without disrupting current session. 2-3
concurrent tasks in the same container.

**Tradeoffs**: Shares process space with main session (memory, /tmp, ports).
Limited to 2-3 concurrent due to VSCode memory ceiling (~3-4GB per Claude
instance). Worktree cleanup needed after merge.

**Lifecycle**:

```bash
# Create
git worktree add .worktrees/issue-{N} -b feature/issue-{N}

# Work (in a Task or subshell)
cd .worktrees/issue-{N}
# ... make changes, commit ...

# Merge (via /orchestrate merge)
git checkout main
git merge feature/issue-{N}

# Cleanup
git worktree remove .worktrees/issue-{N}
git branch -d feature/issue-{N}
```

### Mode 3: Container Agent

Spin up a headless container with its own worktree, environment, and Claude
Code instance running in a tmux session.

**Best for**: Deep parallelization, batch issue processing (5+ issues),
heavy work where session memory pressure matters.

**Tradeoffs**: First build can be slow (30+ min for heavy stacks like Rust).
Higher cost (API usage per agent). Requires docker access. Human reviews at
merge points add context-switching overhead.

**Container access**: The orchestrator uses `docker exec` to interact with
agents. Claude Code runs in a named tmux session — the human can attach
directly:

```bash
docker exec -it project-agent01-1 tmux attach -t claude
```

**Lifecycle**: See `/provision-agent` skill for create/teardown.

______________________________________________________________________

## Decision Tree

Inputs for mode selection:

| Signal              | How to Detect                                              |
| ------------------- | ---------------------------------------------------------- |
| Effort label        | Issue labels: `effort/trivial`, `small`, `medium`, `large` |
| Session load        | `git worktree list \| wc -l`, running containers count     |
| Container available | `docker images -q project:agent-runner` (non-empty = yes)  |
| Build cost estimate | Count INCLUDE\_\* flags in devcontainer config             |
| File overlap risk   | Compare issue's likely files with current working set      |
| Batch size          | Number of issues to process                                |

### Selection Logic

```text
IF effort/trivial AND no file overlap:
  → Mode 1a (current branch)
  "Trivial fix, working directly on current branch."

ELIF effort/small OR clean diff needed:
  → Mode 1b (new branch)
  "Small scope, creating a feature branch for clean diff."

ELIF batch_size == 1 AND session has capacity (< 3 worktrees):
  → Mode 2 (ephemeral worktree)
  "One parallel task, session has capacity. Using ephemeral worktree."

ELIF batch_size >= 2 OR session at capacity (>= 3 worktrees):
  → Mode 3 (container agent)
  IF NOT container_available:
    "Mode 3 recommended: {batch_size} issues. First build ~{estimate}min
     ({features} stack). Subsequent agents instant. Proceed?"
  ELSE:
    "Mode 3 recommended: {batch_size} issues, image ready.
     Estimated {serial_time} serial vs {parallel_time} parallel. Proceed?"

ELSE:
  → Mode 1b (new branch, safe default)
```

### Batch Processing Guidance

For batches of 5+ well-defined issues (e.g., audit cleanup):

1. Use Mode 3 with 3-5 container agents
1. Assign issues round-robin by estimated effort
1. Orchestrator reviews at merge points (human in the loop)
1. Expect: 20-30 issues/afternoon with 5 agents

**Warning**: Batch processing is exhausting for the human (heavy context
switching at merge points) and expensive (5x API cost). Best suited for
well-defined bugs and audit issues, not architectural work.

______________________________________________________________________

## Tradeoff Explanation Templates

When recommending a mode, explain the tradeoff clearly:

**Mode 1a**:

> Working directly on current branch. No overhead, but no isolation either.

**Mode 1b**:

> Creating branch `{branch}`. Clean diff for review. Merge when done.

**Mode 2**:

> Creating ephemeral worktree at `.worktrees/issue-{N}/`. Runs in this
> session — limited to {available} more concurrent tasks.

**Mode 3 (first build)**:

> Spinning up container agent. First build estimated ~{minutes}min
> ({feature_count} features: {feature_list}). Subsequent agents reuse the
> image. Agent runs Claude Code in tmux — attach with:
> `docker exec -it {container} tmux attach -t claude`

**Mode 3 (image ready)**:

> Spinning up container agent (image ready, ~30s startup). Agent runs
> Claude Code in tmux — attach with:
> `docker exec -it {container} tmux attach -t claude`
