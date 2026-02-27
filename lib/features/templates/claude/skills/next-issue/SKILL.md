---
description: Issue-driven development workflow that picks the next issue by severity/effort priority, plans, implements, and ships a PR. Use when working through a backlog, picking up the next issue, or resuming in-progress work.
---

# Next Issue

**Companion file**: See `state-format.md` in this skill directory for the state
file schema, priority ordering commands, and branch naming convention. Load it
at the start of every invocation.

Accepts an optional issue number argument: `/next-issue 123` skips priority
selection and targets that specific issue.

## Phase 0 — Resume Check

1. Read `.claude/memory/next-issue-state.md` (if it exists)
1. If the file contains `phase:` and `issue:` fields, offer to resume:
   - Show the issue number, title, current phase, and branch
   - Ask: **Resume this work or start fresh?**
   - If resume: jump to the recorded phase
   - If fresh: clear the state file and proceed to Phase 1
1. If no state file or it's empty: proceed to Phase 1

## Phase 1 — Select

1. **Detect platform** from `git remote -v`:
   - `github.com` or `ghe.` → GitHub (`gh`)
   - `gitlab.com` or `gitlab.` → GitLab (`glab`)
1. **If a specific issue number was provided**: fetch that issue directly and
   skip the priority query
1. **Otherwise query by priority** using the nested severity x effort loop
   (see `state-format.md` for exact commands). Pick the first open, unassigned
   issue returned
1. **If no labeled issues found**: fall back to oldest open issue
1. Show the selected issue to the user — title, labels, body excerpt
1. Ask: **Work on this issue?** (user can accept, skip to next, or pick
   a different one)
1. Assign the issue to yourself
1. **Write state file** with `phase: select`, issue number, title, platform

## Phase 2 — Plan

1. Read the full issue body
1. Explore the relevant code areas (use Grep/Glob/Read)
1. **Assess scope** from labels:
   - `effort/trivial` or `effort/small`: Write a brief inline plan (3-5
     bullets) directly in the conversation
   - `effort/medium` or `effort/large`: Load `development-workflow`
     phase-details.md and create a thorough plan following its Phase 1-3
     structure
1. Present the plan to the user for approval
1. **Update state file** with `phase: plan` and a one-line plan summary

## Phase 3 — Implement

1. Create a fresh branch from latest main:

   ```bash
   git fetch origin main
   git checkout -b {prefix}/issue-{N}-{slug} origin/main
   ```

   (See `state-format.md` for prefix and slug derivation)

1. Implement the changes following the approved plan

1. Run tests — fix failures before proceeding

1. **Update state file** with `phase: implement` and the branch name

## Phase 4 — Ship

1. Stage and commit with a message that closes the issue:

   ```text
   {type}(scope): description

   Closes #{N}
   ```

   Follow `git-workflow` conventions for commit message format

1. Push the branch and create a PR:

   - GitHub: `gh pr create --title "..." --body "..."`
   - GitLab: `glab mr create --title "..." --description "..."`

1. Include in the PR body: what changed, why, test plan, `Closes #{N}`

1. Checkout main: `git checkout main`

1. **Clear state file** (write empty content)

1. Show the PR URL to the user

## Phase 5 — Next

Ask the user:

- **Continue** — loop back to Phase 1 to pick the next issue
- **Stop** — end the session

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
