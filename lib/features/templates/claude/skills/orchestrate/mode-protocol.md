# Orchestrate — Mode Protocol

Reference companion for `SKILL.md`. Load this when selecting an execution mode
for a task or batch of tasks. Documents the four execution modes, decision
tree, and tradeoff explanations.

---

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
# Create — `just worktree-new` wraps `git worktree add .worktrees/issue-{N}
# -b feature/issue-{N} origin/main` AND copies the machine-local files a push
# needs (.env, .claude/settings.local.json) which are gitignored and so absent
# from a fresh worktree. Doing the bare `git worktree add` instead leaves those
# out and the pre-push hooks fail (docker-compose-validate needs ../.env).
just worktree-new {N}

# Work (in a Task or subshell)
cd .worktrees/issue-{N}
# ... make changes, commit ...

# Merge (via /orchestrate merge)
git checkout main
git merge feature/issue-{N}

# Cleanup — removes the worktree and its feature/issue-{N} branch.
just worktree-rm {N}
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

---

## Golem Dispatch Modes

A **golem** is a per-issue sub-orchestrator: a PROCESS that owns one issue →
branch → worktree → PR and runs the autonomous pipeline (`/next-issue <N>
--auto`, which invokes `/next-issue-ship` in-turn → Branch + PR) unattended to
a green, review-clean PR. Golems are not a new isolation mechanism — they are
the **existing Mode 2 or Mode 3** with an autonomous payload and a PR exit.

The launch is **interactive** in tmux with `--permission-mode auto` passed
**explicitly** (never headless `claude -p`, never
`--dangerously-skip-permissions`; see the `golem-supervised-auto-mode` memory and
issues #570, #585). The explicit flag is required because a fresh worktree is untrusted,
so Claude Code does not load its copied `settings.local.json` `defaultMode: auto`
and would otherwise fall back to `default`. The harness `--permission-mode auto`
is distinct from the `/next-issue` `--auto` skill flag — both are needed.
Autonomous `/next-issue` invokes `/next-issue-ship` in-turn, so the single prompt
reaches a PR on its own. A `;`-chained second prompt is the resume backstop —
`claude --permission-mode auto "/next-issue <N> --auto" ; claude --permission-mode auto "/next-issue-ship --auto"`
— so that a premature turn-exit after `/next-issue` still ships: the second
prompt re-reads the state file and delivers (a near no-op if the first already
pushed a PR). Use `;`, NOT `&&`: the backstop must run even when the first prompt
exits non-zero before shipping, which is exactly the case `&&` would skip.

| Realization        | Built on | Payload (process)                         | Exit                            |
| ------------------ | -------- | ----------------------------------------- | ------------------------------- |
| **Worktree golem** | Mode 2   | `claude --permission-mode auto "/next-issue <N> --auto" ; claude --permission-mode auto "/next-issue-ship --auto"` in a worktree shell | autonomous ship → Branch + PR |
| **Container golem** | Mode 3  | same chained pipeline in the container's tmux Claude | same → PR (or auto-merge: needs `AUTOMERGE=1` + `AUTOMERGE_AUTONOMOUS=1`) |

> **Hard constraint — golems are processes, never Workflow subagents.** The
> Workflow tool permits one nesting level, and each golem's `/next-issue-ship`
> already owns it (its review harness fans out the `code-reviewer` agent).
> Dispatching a golem via the Workflow/Task tool with workflow nesting consumes
> that level and makes the golem's review harness throw. Dispatch golems as OS
> processes only — containers (`/provision-agent`) or worktree-bound shells.
> (See `next-issue-ship` SKILL.md § Golem Execution Model.)

### Supervised launch & central feed

Golems run **interactive in tmux with `--permission-mode auto` passed
explicitly** — never `--dangerously-skip-permissions`, never forced
`acceptEdits`. `auto`'s safety classifier auto-approves routine reads/edits/bash
and prompts only on the genuinely risky class, so a prompt then means something.
(The repo's `.claude/settings.local.json` also pins `git push` / `gh pr create` /
`gh pr merge` to `ask`, so outward actions still gate even under `auto` — once
the worktree is trusted; `just worktree-new` seeds that trust.) The flag must be
explicit: a fresh worktree is untrusted, so its copied `defaultMode: auto` is not
loaded on its own and the session would silently fall back to `default` (#585).

Launch a worktree golem (after `just worktree-new {N}`):

```bash
tmux new-session -d -s golem-{N} -c .worktrees/issue-{N} \
  "claude --permission-mode auto '/next-issue {N} --auto' ; claude --permission-mode auto '/next-issue-ship --auto'"
```

**Do NOT run golems headless** (`claude -p --output-format stream-json`). A
headless session has no TTY, so there is nothing to attach to and no way to
answer a permission prompt — it forces skip-all and throws away supervision to
gain a feed. Monitoring and intervention are separate channels:

- **Monitor (TTY-free):** an interactive golem's TUI paints an alternate screen
  buffer, so `tmux capture-pane` / `tail -f` are blank until exit. Derive status
  from observable state instead — git commits vs `origin/main`, PR/MR state, the
  `next-issue` state files (`phase`), and the `.worktrees/.status/*.json` cache —
  plus a `Notification` hook (`.claude/hooks/golem-notify.sh`) that appends a
  blocked-golem line to `.worktrees/.status/feed.jsonl` whenever a golem awaits a
  decision. `just golems` renders the table AND the BLOCKED list from these.
- **Intervene (on demand):** when `just golems` flags a golem BLOCKED, run
  `just golem-attach {N}` to attach its real TTY (worktree session `golem-{N}`,
  or a container golem's `claude` session via `docker exec`), answer the
  high-risk prompt, and detach.

### Dispatch Decision Sub-Tree

```text
IF batch_size >= 2 OR session at capacity (>= 3 worktrees):
  → Container golems (Mode 3) via /provision-agent — primary for parallel work
ELIF batch_size in 1..2 AND session has capacity:
  → Worktree golems (Mode 2)
ELSE (single issue):
  → Run /next-issue directly, no orchestration
```

The master orchestrator (a live interactive session) dispatches golems, then
monitors PR + issue-label state and rebases across PRs. It NEVER merges a
golem's branch into its own — humans merge PRs (or per-golem auto-merge, which
for an autonomous golem requires both `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1`).
See `SKILL.md` Phases D / M / R.

---

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

---

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
