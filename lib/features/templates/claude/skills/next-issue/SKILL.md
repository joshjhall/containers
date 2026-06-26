---
description: Issue-driven development workflow that picks the next issue by severity/effort priority and creates an implementation plan. Use when working through a backlog, picking up the next issue, or resuming in-progress work. After implementation, use /next-issue-ship to deliver.
---

# Next Issue

**Companion file**: See `state-format.md` in this skill directory for the state
file schema (JSON), priority ordering commands, branch naming convention,
checkpoint structure, and reset points. Load it at the start of every
invocation.

Accepts an optional issue number argument: `/next-issue 123` skips priority
selection and targets that specific issue.

Adding the `--auto` flag — `/next-issue 123 --auto` (or setting the
`NEXT_ISSUE_AUTONOMOUS=1` environment variable) — runs the workflow
autonomously: every human gate resolves to its documented default and no
interactive tool is called. See `## Autonomous Mode` below.

Adding the `--ship` flag (alias `--now`) — `/next-issue 123 --ship` — is a
fast-path for **small work**: after plan approval and implementation it invokes
`/next-issue-ship` directly instead of suggesting a `/clear` + manual resume.
`--ship` is **not** autonomy — it keeps the interactive plan-approval gate
(`EnterPlanMode`/`ExitPlanMode`) and leaves `autonomous` false; it only removes
the context-reset ceremony between implement and ship. It is honored **only for
`effort/trivial` and `effort/small`** issues; for `effort/medium`/`large` (or
no effort label) it is ignored with a one-line note, preserving the `/clear`
boundary that keeps planning context out of the longer implement/review budget.
See `## Pipeline` and the conditional final step of Phase 2.

**IMPORTANT — Plan mode**: Use the `EnterPlanMode` tool immediately at the
start of every `/next-issue` invocation (before any other work). Phases 0-2
are planning phases that only need read-only tools and Bash. After Phase 2
plan approval, use `ExitPlanMode` to begin implementation. (In autonomous
mode, SKIP `EnterPlanMode`/`ExitPlanMode` entirely — see `## Autonomous Mode`
below.)

## Autonomous Mode

The run is **autonomous** when EITHER the literal token `--auto` appears in
the invocation arguments OR the environment variable `NEXT_ISSUE_AUTONOMOUS=1`
is set. Autonomy is strictly opt-in.

When autonomous:

- Do NOT call `EnterPlanMode`/`ExitPlanMode` or any `AskUserQuestion`. Every
  human gate in the phases below takes its documented default with no
  interactive tool call.
- The run proceeds selection → plan → implement without stopping. Then, once
  implementation and testing are complete, **invoke the `/next-issue-ship`
  skill in the same turn** (call the `Skill` tool with `next-issue-ship`) —
  do NOT end the turn after merely printing a "next step". The handoff is an
  actual in-turn skill invocation, not narrative: a single
  `claude '/next-issue <N> --auto'` prompt must reach a pushed PR on its
  own, because the model ending its turn after `/next-issue` does not start a
  second skill. `/next-issue-ship` then detects autonomy independently (via
  the same toggle and the persisted state-file signal) and continues to
  Branch + PR. See the autonomous planning path in Phase 2 for the exact
  point at which the invocation happens.
- Persist the signal to the state file as `"autonomous": true` (see Phase 1
  and Phase 2 below) so `/next-issue-ship` and any post-`/clear` resume
  inherit it.

When NOT autonomous (no `--auto`, no env var), behavior is unchanged — every
interactive prompt and plan-mode step below runs verbatim as the default.

## Agent Worktree Mode

Before starting Phase 0, check if the current branch is an agent worktree:

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

If `$CURRENT_BRANCH` matches `^agent` (e.g., `agent01`, `agent02`):

- Inform the user: "Running in agent worktree mode on branch `{branch}`.
  Commits will stay local — the orchestrator handles delivery."
- Note that `/next-issue-ship` will auto-select commit-only mode (Option 3)

**Note on state isolation**: In agent worktree mode, each worktree has its own
working directory, so per-issue state files are naturally isolated per agent.
No disambiguation is needed.

Proceed with Phase 0 as normal regardless of mode.

## Phase 0 — Resume Check

1. **Enter plan mode** (call `EnterPlanMode` tool) — in autonomous mode, SKIP
   this step (no `EnterPlanMode`/`ExitPlanMode`; see `## Autonomous Mode`)

1. **Legacy migration** — run in order:

   a. If `.claude/memory/tmp/next-issue-state.md` exists (legacy singleton),
   read its `issue:` field, rename to `.claude/memory/tmp/next-issue-{N}.md`

   b. If any `.claude/memory/tmp/next-issue-*.md` files exist (YAML format),
   migrate each to `.json`: read the YAML frontmatter fields, write a new
   `.json` file with those fields plus `"version": 2`, delete the `.md` file

1. **Discover state files**:

   ```bash
   ls .claude/memory/tmp/next-issue-*.json 2>/dev/null
   ```

1. **If multiple state files exist** (parallel agents scenario):

   - List all active issues with their number, title, phase, and branch
   - Ask: **Which issue to resume, or start fresh?**
   - If the user picks one: validate and resume that issue (see below)
   - If start fresh: proceed to Phase 1
   - **If autonomous AND a specific issue number was provided**: do not
     prompt — target that issue's state non-interactively (resume its
     recorded phase if a valid open state file exists for it, else start
     fresh for that issue)

1. **If exactly one state file exists**: validate and offer to resume (see below)

1. **If no state files exist**: proceed to Phase 1

**Validation** (for a single state file or user-selected file):

- Read the `.json` file and extract `phase`, `issue`, `branch` fields
- Check if the issue is still open (`gh issue view {N} --json state` or
  `glab issue view {N}`)
- Check if the branch still exists (`git branch --list {branch}`)
- **If issue is closed or branch is missing**: the state is stale — silently
  delete the state file and proceed to Phase 1 (no need to ask the user)
- **If issue is still open and branch exists**: offer to resume:
  - Show the issue number, title, current phase, and branch
  - **If the state file has a `checkpoint` object**: show `key_decisions` and
    `next_action` so the user has context for the decision
  - Ask: **Resume this work or start fresh?**
  - If resume: jump to the recorded phase
  - If fresh: delete the state file and proceed to Phase 1
  - **If autonomous AND a specific issue number was provided**: do not
    prompt — resume the recorded phase non-interactively (the state file is
    already validated open above); otherwise start fresh for that issue

## Phase 1 — Select

1. **Detect platform** from `git remote -v`:

   - `github.com` or `ghe.` → GitHub (`gh`)
   - `gitlab.com` or `gitlab.` → GitLab (`glab`)

1. **If a specific issue number was provided**: fetch that issue directly and
   skip the priority query

1. **Otherwise query by priority** using the nested severity x effort loop
   (see `state-format.md` for exact commands). **Important**: all queries
   MUST exclude issues with `status/in-progress`, `status/pr-pending`,
   `status/commit-pending`, or `status/on-hold` labels — see `state-format.md` for the exact
   `--search` / post-filter syntax. Pick the first open, unassigned issue
   returned

1. **If no labeled issues found**: fall back to oldest open issue (also
   excluding `status/in-progress`, `status/pr-pending`,
   `status/commit-pending`, and `status/on-hold`)

1. Show the selected issue to the user — title, labels, body excerpt

1. Ask: **Work on this issue?** (user can accept, skip to next, or pick
   a different one) — when autonomous, accept the selected issue
   automatically (no prompt)

1. Assign the issue to yourself

1. **Label the issue** `status/in-progress`:

   - GitHub: `gh issue edit {N} --add-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/in-progress"`

1. **Write state file** to `.claude/memory/tmp/next-issue-{N}.json`:

   ```json
   {
     "version": 2,
     "issue": {N},
     "title": "{title}",
     "phase": "select",
     "started": "{YYYY-MM-DD}",
     "platform": "{github|gitlab}",
     "autonomous": {true|false}
   }
   ```

   Set `"autonomous"` from the toggle (true when `--auto` or
   `NEXT_ISSUE_AUTONOMOUS=1`, false otherwise).

## Phase 2 — Plan

1. Read the full issue body

1. Explore the relevant code areas (use Grep/Glob/Read)

1. **Assess scope** from labels (note the effort tier — the final step uses it
   to decide whether `--ship` applies):

   - `effort/trivial` or `effort/small`: Write a brief inline plan (3-5
     bullets) directly in the conversation. These tiers are `--ship`-eligible.
   - `effort/medium` or `effort/large`: Load `development-workflow`
     phase-details.md and create a thorough plan following its Phase 1-3
     structure. These tiers are NOT `--ship`-eligible (the `/clear` boundary is
     preserved).

1. **MANDATORY final step** — always append this verbatim as the last step
   of the plan:

   > **After all implementation and testing is complete**, invoke `/next-issue-ship`
   > to commit, deliver, and close the issue.

   If in agent worktree mode, also append:

   > Agent worktree mode: `/next-issue-ship` will auto-select commit-only
   > (Option 3). The orchestrator handles PR creation and delivery.

1. **Update state file** — write the full JSON with `phase: "plan"`, a
   one-line `plan` summary, and the `checkpoint` object:

   ```json
   {
     "version": 2,
     "issue": {N},
     "title": "{title}",
     "phase": "plan",
     "branch": "{branch}",
     "plan": "{one-line summary}",
     "started": "{date}",
     "platform": "{platform}",
     "autonomous": {true|false},
     "plan_comment_url": "{url}",
     "checkpoint": {
       "completed_phase": "plan",
       "key_decisions": ["{non-obvious choice 1}", "{non-obvious choice 2}"],
       "files_modified": [],
       "files_planned": ["{file1}", "{file2}"],
       "warnings": ["{anything the implementation phase should know}"],
       "next_action": "Begin implementation"
     }
   }
   ```

   Set `"autonomous"` from the toggle: `true` only when `--auto` or
   `NEXT_ISSUE_AUTONOMOUS=1`; `false` otherwise — **including `--ship`/`--now`
   runs**, which are not autonomous (see the conditional final step below).
   `"plan_comment_url"` is written only in autonomous mode (see the
   autonomous planning path below); omit it otherwise.

1. **Autonomous planning path** — when autonomous, do NOT enter plan mode.
   After exploring and forming the plan: (1) write the plan to the state file
   exactly as above, AND (2) post the plan as an issue comment for
   traceability —

   ```bash
   gh issue comment {N} --body "..."      # GitHub
   glab issue note {N} --message "..."    # GitLab
   ```

   Capture the returned comment URL and record it in the state file as
   `"plan_comment_url"`. Then proceed DIRECTLY to implementation — no
   `ExitPlanMode`, no approval gate. Autonomous mode SKIPS both the "Exit plan
   mode" and "Suggest context reset" steps below.

   **Then, once implementation and testing are complete, invoke the
   `/next-issue-ship` skill in this same turn** (call the `Skill` tool with
   `next-issue-ship`). Do NOT stop after implementation to *suggest* shipping,
   and do NOT merely print a "next step: /next-issue-ship" line — actually
   invoke it. This is the whole point of `--auto`: a single
   `claude '/next-issue <N> --auto'` prompt must reach a pushed PR + labeled
   issue without a second manual command. Ending the turn after `/next-issue`
   leaves the work uncommitted with no PR. (As a belt-and-suspenders for a
   premature turn-exit, the orchestrate golem launch also chains a second
   `; claude '/next-issue-ship --auto'` prompt — see the orchestrate skill — but
   the in-turn invocation here is the primary path and must not be skipped.)

1. **Exit plan mode** (call `ExitPlanMode` tool) — this presents the plan to
   the user for approval before implementation begins. (Skipped when
   autonomous — see the autonomous planning path above.)

1. **Implement** — after plan approval, carry out the plan: make the changes
   and run the tests. The two steps below fire only **once implementation and
   testing are complete** — do NOT invoke `/next-issue-ship` or suggest a
   `/clear` before the work exists.

1. **Hand off — suggest a context reset, OR take the `--ship` fast-path.**
   Reached only after implementation and testing complete (previous step).
   (Skipped when autonomous — see the autonomous planning path above.) Choose
   by flag + effort:

   - **`--ship` (or `--now`) set AND effort is `trivial`/`small`**: do NOT
     suggest a `/clear`. Invoke `/next-issue-ship` directly to deliver in this
     same context. The plan was still approved interactively above, so the
     human remains in the loop; only the reset ceremony is skipped. The state
     file's `"autonomous"` stays `false` — the ship run will still prompt for
     shipping mode etc.

   - **`--ship`/`--now` set BUT effort is `medium`/`large` (or there is no
     `effort/*` label)**: emit a one-line note — "`--ship` skipped for
     {effort/medium,effort/large,no effort label} — preserving the `/clear`
     boundary" — then fall through to the default suggestion below.

   - **Default (no `--ship`/`--now`)** — tell the user:

     > Planning phase complete. Context can be safely cleared — state saved to
     > `.claude/memory/tmp/next-issue-{N}.json`. Run `/clear` then `/next-issue`
     > to resume from implementation.

     This is advisory — continue normally if the user declines.

## Platform Detection

Detect from the first `origin` remote URL:

| Pattern in remote URL     | Platform | CLI    |
| ------------------------- | -------- | ------ |
| `github.com` or `ghe.`    | GitHub   | `gh`   |
| `gitlab.com` or `gitlab.` | GitLab   | `glab` |

If neither matches, ask the user which platform to use.

## Pipeline

`/next-issue` and `/next-issue-ship` are two halves of one issue-driven
pipeline, deliberately kept as **separate** skills:

```text
/next-issue        →  (implement + test)  →  /next-issue-ship
  select + plan          your work             commit · PR/push · CI · review · label
       └──────────────── next-issue-{N}.json ────────────────┘
              (phase / checkpoint carry state across the gap)
```

The hand-off is the state file `.claude/memory/tmp/next-issue-{N}.json` (schema
in `state-format.md`): `/next-issue` writes `phase` + a `checkpoint` block;
`/next-issue-ship` reads them. This lets the implement step happen later, in a
fresh context, or across a `/clear` — the planning context does not have to
stay resident through implementation, review, and CI.

They are NOT merged into one command on purpose: the `/clear` boundary keeps
planning tokens out of the longer implement/review/CI budget; plan is
read-only/plan-mode while ship is all side effects (commit/push/PR), which are
easier to gate as distinct runs; and a failure stays attributable to one phase.

For genuinely small work that boundary is pure overhead — `/next-issue --ship`
(alias `--now`; see the flag docs above) collapses the hand-off in-context for
`effort/trivial`/`small` issues while still keeping the plan-approval gate.

## When to Use

- Working through a backlog of audit-created issues
- Picking up the next issue in a sprint
- Resuming work after a context window reset
- Systematic issue-by-issue cleanup

## When NOT to Use

- Exploratory work without a filed issue
- Issues requiring cross-repo coordination (handle manually)
- Emergency hotfixes (branch directly, skip priority selection)
- When you want to work on a specific PR rather than an issue
