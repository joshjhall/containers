---
description: Master orchestrator for PR-per-golem parallel work. Dispatch golems (one issue/branch/worktree/PR each) running the autonomous pipeline, monitor PR + issue-label state, surface progress, and rebase across PRs. Use when running 2+ independent issues in parallel, watching golem PRs, or integrating agent work. Local-merge topology preserved as opt-in.
---

# Orchestrate

The default topology is **PR-per-golem**: the orchestrator is a **live
interactive session** that dispatches **golems** (each a PROCESS owning one
issue → branch → worktree → PR, running the autonomous `/next-issue --auto` →
`/next-issue-ship` pipeline), then monitors, surfaces, and rebases across their
PRs. **The orchestrator never merges golem branches into its own** — humans
merge PRs (or per-golem auto-merge, which for an autonomous golem requires BOTH
`AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` — see `next-issue-ship` §
Environment Variables).

**Hard constraints** (architecture — do not violate):

- **Golems are processes, never Workflow subagents.** Each golem's
  `/next-issue-ship` owns the single permitted Workflow nesting level (its review
  harness). Spawning a golem as a Workflow/Task subagent makes that harness
  throw. Dispatch golems as containers (`/provision-agent`) or worktree-bound
  shell processes — see `mode-protocol.md` § Golem Dispatch Modes.
- **The orchestrator session is live/interactive, not a workflow.** It surfaces
  progress and takes commands mid-flight. It uses the Workflow harness
  (`workflow.js`) ONLY for bounded fan-out: the monitor poll and the cross-PR
  rebase dispatch.
- **PR + issue-label state are authoritative**; `.worktrees/.status/*.json` is a
  fast cache consulted only to fill display gaps.

**Companion files** (load before the matching phase):

- `mode-protocol.md` — execution + golem dispatch modes, decision tree
- `merge-protocol.md` — cross-PR rebase conflict classification + test-runner
  detection (live); merge/sync sections marked opt-in legacy
- `workflow.js` — the monitor-poll + cross-PR-rebase harness (invoked via the
  Workflow tool; never edited at runtime)

**Invocation patterns:**

| Invocation | Phase |
| ---------- | ----- |
| `/orchestrate dispatch <N…>` or `dispatch <count>` | Phase D — Dispatch golems |
| `/orchestrate` or `/orchestrate status` | Phase M — Monitor (one sweep) |
| `/orchestrate monitor` / `watch` | Phase M — Monitor loop |
| `/orchestrate rebase` or `rebase <N>` | Phase R — Cross-PR rebase |
| `/orchestrate mode` | Phase 0 — Mode selection |
| `/orchestrate spawn <N>` / `teardown <agent>` | Phase 5 — Container mgmt |
| `/orchestrate merge <N>` / `merge all` / `sync` | Local-merge (OPT-IN, legacy) |
| `/orchestrate review` | Local-merge review (OPT-IN, legacy) |

## Phase D — Dispatch

Spin up N golems, each owning one issue end-to-end. Golems are **processes**;
dispatch is sequential and cheap — **not** workflow-driven.

1. **Select issues** by priority using the ordering in
   `next-issue/state-format.md` (exclude issues already labeled
   `status/in-progress`, `status/pr-pending`, `status/commit-pending`,
   `status/on-hold`). Accept explicit issue numbers if provided. **Read each
   selected issue's `effort/*` and `severity/*` labels now** — they decide
   whether the golem launches fully-autonomous or **plan-gated** (step 3).

1. **Choose the dispatch mode** per issue from `mode-protocol.md`:

   - **Container golem** (Mode 3, primary) — `batch_size ≥ 2` or session at
     capacity. Invoke `/provision-agent` (Phase 5 Spawn).
   - **Worktree golem** (Mode 2) — 1–2 issues with session capacity.
     `git worktree add .worktrees/issue-{N} -b feat/issue-{N}` and launch the
     pipeline in a worktree-bound shell process.

1. **Launch the autonomous pipeline** as a process in each golem:

   ```bash
   # Inside the golem's container tmux or worktree shell — launch INTERACTIVE
   # with `--permission-mode auto` passed EXPLICITLY (never headless `claude -p`,
   # never --dangerously-skip-permissions — see the golem-supervised-auto-mode
   # memory / #570). The explicit flag is required: a fresh worktree is untrusted,
   # so Claude Code does NOT load its copied settings.local.json `defaultMode:
   # auto` and would silently fall back to `default` and prompt-storm (#585).
   # The harness `--permission-mode auto` is distinct from the `/next-issue`
   # `--auto` skill flag (skip plan / run autonomously) — both are needed.
   # Autonomous /next-issue invokes /next-issue-ship in-turn, so the first prompt
   # reaches Branch + PR on its own. The `;`-chained second prompt is a resume
   # backstop, NOT `&&`: it must run even if the first prompt exits non-zero
   # before shipping (the very case it exists for). If the first already shipped
   # (state file deleted), the second is a near no-op ("No in-progress issue
   # found" → stop):
   claude --permission-mode auto "/next-issue {N} --auto" ; claude --permission-mode auto "/next-issue-ship --auto"
   ```

   **Plan gate (from the labels read in step 1).** `--auto` is **not** a blanket
   plan-skip — `/next-issue` decides per issue (see `next-issue/SKILL.md` §
   Autonomous Mode):

   - **`effort/trivial` or `effort/small`, and NOT `severity/critical`** →
     fully autonomous, no plan stop. The launch above runs unattended to a PR.
   - **`effort/medium`, `effort/large`, `severity/critical`, or no `effort/*`
     label** → **plan-gated**: the golem builds the plan and BLOCKS at
     `ExitPlanMode` awaiting human approval. It shows up BLOCKED in `just golems`;
     the operator runs `just golem-attach {N}`, reviews/refines the plan
     in-session, and approves — then the SAME session continues autonomously
     through implement → review → push/PR with the refined plan in-context.

   The launch command is identical either way (the policy lives in
   `/next-issue`); dispatch only needs to **expect** medium+/critical golems to
   block at the plan step rather than run straight through. To override per
   golem, append `--plan-gate` (force the checkpoint on a small issue) or
   `--force-auto` (force full autonomy on a medium+/critical one) to the
   `/next-issue {N} --auto` prompt.

   The pipeline runs unattended to a green, review-clean PR (after plan approval
   for a plan-gated golem), or, per-golem, queues GitHub auto-merge when BOTH
   `AUTOMERGE=1` and `AUTOMERGE_AUTONOMOUS=1` are set — `AUTOMERGE=1` alone is a
   no-op for an autonomous golem and falls through to human merge.

1. **Label + cache**: ensure each dispatched issue is `status/in-progress`
   (the autonomous `/next-issue` does this) and write the initial golem cache
   entry to `.worktrees/.status/{golem}.json` (schema:
   `schemas/golem-status.schema.json`).

1. **Report** the dispatch table: golem → issue → branch → mode → access
   command (for container golems, the `docker exec … tmux attach` line).

## Phase M — Monitor

Authoritative status comes from **PR + issue-label state**. The
`.worktrees/.status/*.json` cache only fills display gaps.

1. **Enumerate the open-PR set** and cross-reference linked issues:

   ```bash
   # GitHub
   gh pr list --state open --json number,headRefName,body,title
   # GitLab
   glab mr list --json   # or: glab mr list
   ```

   Map each PR to its issue via the `Closes #N` line that `/next-issue-ship`
   writes into the PR body.

1. **Invoke the Workflow tool** on `~/.claude/skills/orchestrate/workflow.js`
   with:

   ```text
   args: {
     prs:  [{ number, branch, issue, golem }, …],
     base: "<base branch, e.g. main>",
     mode: "poll"
   }
   ```

   The harness fans a read-only poll across all PRs as one parallel barrier
   under a shared budget (per-PR checkpoint → resumable mid-list) and returns
   `pr_status[]` (`ci`, `review`, `label_state`, `behind_base`, `review_cycle`,
   `blocking`, `summary`).

1. **Render the live status table** from `pr_status`:

   ```text
   # Golem Status

   | Golem   | Issue | Branch            | PR   | CI       | Review            | Cycle | Blocking |
   |---------|-------|-------------------|------|----------|-------------------|-------|----------|
   | agent01 | #142  | feat/issue-142    | #310 | passing  | approved          | 2     | —        |
   | agent02 | #89   | feat/issue-89     | #311 | failing  | changes-requested | 1     | ⚠ yes   |
   | agent03 | #201  | feat/issue-201    | —    | —        | (no PR yet)       | 0     | —        |
   ```

1. **Flag the human** when a PR is green + review-clean (`ci: passing`,
   `review: approved`/`none`, `blocking: false`) — it is awaiting merge.

1. **Loop** (for `monitor`/`watch`): re-poll on an interval, surfacing changes.
   Between sweeps, accept mid-flight commands (see Surface below).

**Supervised live golems (pre-PR).** The PR poll above covers golems that have
opened a PR. While a golem is still working it has no PR yet, so watch it
TTY-free instead — `just golems` renders the `.worktrees/.status/*.json` cache
(phase/branch/commits) and surfaces which golems are **BLOCKED** on a permission
decision, fed by the `Notification` hook (`.claude/hooks/golem-notify.sh` →
`.worktrees/.status/feed.jsonl`). When one is flagged, `just golem-attach {N}`
attaches its real TTY (worktree session `golem-{N}`, or a container golem's
`claude` session via `docker exec`) so the human answers the prompt and
detaches. Golems run interactive under `auto` mode — never headless
`claude -p` (no TTY = cannot answer prompts) and never
`--dangerously-skip-permissions`. See `mode-protocol.md` §
*Supervised launch & central feed*.

**Plan-gated golems block early, by design.** A golem dispatched on an
`effort/medium`/`large` or `severity/critical` issue (see Phase D step 3) pauses
at its plan checkpoint (`ExitPlanMode`) before writing any code, so it appears
BLOCKED in `just golems` shortly after launch — that is the human plan
checkpoint, not a stall. Attach with `just golem-attach {N}`, refine and approve
the plan, and detach; the golem then proceeds autonomously to a PR.

## Phase R — Cross-PR Rebase

When an earlier PR merges, later PRs touching the same files fall behind base.
Detect and rebase them — without merging anything into the orchestrator branch.

1. **Invoke the Workflow tool** on `~/.claude/skills/orchestrate/workflow.js`
   with `mode: "poll+rebase"` (same `prs`/`base` args as Phase M). The harness:

   - polls all PRs, then loops over the `behind_base` subset (loop-until-dry,
     resumable),
   - classifies each PR's conflict overlap (`none` / `trivial-only` /
     `has-logic`),
   - dispatches the **`rebase-agent`** (`agentType`) for trivial-only conflicts
     (lockfiles, generated files, imports, versions, whitespace — see
     `merge-protocol.md` § Conflict Classification),
   - escalates `has-logic` (same-function / add-add / delete-modify) conflicts.

1. **Report** `rebases[]` (auto-resolved, with strategy) and surface
   `escalations[]` **verbatim** to the human.

1. **Push rebased branches** (the harness never pushes): for each rebased PR
   branch, the orchestrator pushes under human supervision:

   ```bash
   git push --force-with-lease origin <branch>
   ```

1. **Never** merge a golem branch into the orchestrator branch.

## Surface — Mid-Flight Commands

Between monitor sweeps, the live session accepts:

- **`merge #N`** — the human merges PR #N (or run `gh pr merge #N` if the repo's
  merge policy allows). The orchestrator does not merge into its own branch.
- **`rebase #N`** — run Phase R scoped to PR #N.
- **`teardown <agent>`** — Phase 5 Teardown for a finished golem.
- **`status`** — re-run Phase M.

## Phase 0 — Mode Selection

Load `mode-protocol.md` before starting.

1. **Gather inputs**:

   ```bash
   git worktree list | /usr/bin/wc -l
   docker ps --filter "name=agent" --format "{{.Names}}" 2>/dev/null
   docker images -q "*:agent-runner" 2>/dev/null
   ```

1. **Assess the task** — effort label, batch size, file-overlap risk.

1. **Recommend a mode** using the decision tree in `mode-protocol.md`
   (including § Golem Dispatch Modes for parallel work), and present the
   tradeoff via `AskUserQuestion`.

1. **Execute**: Mode 1a/1b → run `/next-issue` directly; Mode 2 → worktree
   golem (Phase D); Mode 3 → container golem via `/provision-agent`.

## Phase 5 — Container Management

### Spawn

Invoked via `/orchestrate spawn <N>` (and by Phase D for container golems).

1. **Check prerequisites**: `docker info > /dev/null 2>&1`,
   `git rev-parse --show-toplevel`.

1. **Invoke `/provision-agent`** to read the devcontainer config, generate the
   agent docker-compose, build the image, create worktrees, and start containers.
   Each agent runs Claude Code in a tmux session.

1. **Assign issues** (priority order from `next-issue/state-format.md`) and
   launch the autonomous pipeline per golem (Phase D step 3). Write initial
   cache files to `.worktrees/.status/`.

1. **Report** spawned golems with access commands:

   ```text
   | # | Agent   | Container          | Issue | Access                                                   |
   |---|---------|--------------------|-------|----------------------------------------------------------|
   | 1 | agent01 | project-agent01-1  | #142  | docker exec -it project-agent01-1 tmux attach -t claude  |
   ```

### Teardown

Invoked via `/orchestrate teardown <agent>` or `teardown all`. Tear down only
after the golem's PR is merged or abandoned.

1. `docker compose -f .worktrees/docker-compose.agents.yml stop <agent>`
1. `docker compose -f .worktrees/docker-compose.agents.yml rm -f <agent>`
1. **Remove worktree** (if the PR merged): `git worktree remove .worktrees/<agent>`
   then `git branch -d <agent>`
1. **Clean cache**: remove `.worktrees/.status/<agent>.json`
1. **Report** the teardown result.

## Local-Merge (OPT-IN, Legacy)

> **OPT-IN LEGACY MODE.** The default topology is PR-per-golem (Phases D/M/R).
> Use local-merge ONLY for tightly-coupled work where golems push to no remote
> (offline / no-PR worktree workflow). The orchestrator merging golem branches
> into its own branch — and syncing back — is exactly what PR-per-golem
> replaces. Load `merge-protocol.md` (the merge/sync sections are bannered
> superseded; conflict classification + test-runner detection remain live).

Use these only when explicitly requested (`/orchestrate merge`, `review`,
`sync`).

### Merge (legacy Phase 2)

1. **Resolve agent identifier**: numeric → map from the status table; branch
   name → use directly; `all` → iterate agents with pending commits.
1. **Preview**: `MERGE_BASE=$(git merge-base HEAD <agent-branch>)`;
   `git log --oneline "$MERGE_BASE"..<agent-branch>`; diffstat. Confirm.
1. **Merge**: `git merge --no-ff <agent-branch> -m "merge(<agent-branch>): …"`
   (or `--squash` on request).
1. **Conflicts**: dispatch `rebase-agent` for trivial; escalate non-trivial
   (see `merge-protocol.md` § Conflict Classification).
1. **Run tests** (see `merge-protocol.md` § Test Runner Detection); warn on
   failure, do not auto-revert.
1. **Report** the merge commit. Suggest `/clear` if context is large.

### Review (legacy Phase 3)

Per-PR review is normally the **golem's** job (the `/next-issue-ship` review
loop). This phase applies only after a local merge.

1. `MERGE_COMMIT=$(git log -1 --merges --format='%H')`.
1. **Run the `code-review` harness** via the Workflow tool on
   `~/.claude/agents/code-reviewer/workflow.js`, passing
   `args: { diff: "<git diff \"${MERGE_COMMIT}^1\" \"${MERGE_COMMIT}\">", files: [<changed>] }`.
   It returns the `finding-schema.md` object.
1. **Apply corrections** in a single commit trailered `Reviewed-by: orchestrate`.
1. **Run tests**; report a summary table.

### Sync (legacy Phase 4)

1. `ORCH_BRANCH=$(git branch --show-current)`.
1. For each `git branch --list 'agent*' | /usr/bin/sort`:
   `git checkout <branch>; git merge "$ORCH_BRANCH" -m "sync: …"`; on conflict
   `git merge --abort` and skip.
1. Return to `$ORCH_BRANCH`; remove `status/in-progress` /
   `status/commit-pending` labels for synced issues. Report a sync table.

## When to Use

- Running 2+ independent issues in parallel as golems (`/orchestrate dispatch`)
- Watching golem PRs through CI + review to green (`/orchestrate monitor`)
- Rebasing later PRs after an earlier PR merges (`/orchestrate rebase`)
- Selecting an execution mode for a new task (`/orchestrate mode`)
- Spawning / tearing down container golems (`/orchestrate spawn`, `teardown`)
- Tightly-coupled worktree work with no PRs (opt-in local-merge)

## When NOT to Use

- Single-issue work — run `/next-issue` directly, no orchestration needed
- Cross-repository coordination (handle manually)
- When golems are still actively working — monitor first, merge when green
