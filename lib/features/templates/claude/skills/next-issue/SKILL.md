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

**IMPORTANT — Plan mode**: Use the `EnterPlanMode` tool immediately at the
start of every `/next-issue` invocation (before any other work). Phases 0-2
are planning phases that only need read-only tools and Bash. After Phase 2
plan approval, use `ExitPlanMode` to begin implementation.

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

1. **Enter plan mode** (call `EnterPlanMode` tool)

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
   a different one)

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
     "platform": "{github|gitlab}"
   }
   ```

## Phase 2 — Plan

1. Read the full issue body

1. Explore the relevant code areas (use Grep/Glob/Read)

1. **Assess scope** from labels:

   - `effort/trivial` or `effort/small`: Write a brief inline plan (3-5
     bullets) directly in the conversation
   - `effort/medium` or `effort/large`: Load `development-workflow`
     phase-details.md and create a thorough plan following its Phase 1-3
     structure

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

1. **Exit plan mode** (call `ExitPlanMode` tool) — this presents the plan to
   the user for approval before implementation begins

1. **Suggest context reset** — after plan approval, tell the user:

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
