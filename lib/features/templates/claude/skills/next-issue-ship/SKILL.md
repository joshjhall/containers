---
description: Ship the current next-issue work — commit, deliver (PR or push), label the issue, and optionally loop back. Use after implementation and testing are complete for an issue started with /next-issue.
---

# Next Issue — Ship

Delivers the completed work for an issue previously selected and planned by
`/next-issue`. Handles committing, pushing, PR creation, issue labeling, and
state cleanup.

**Prerequisite**: Implementation and testing must be complete before invoking
this skill. The state file written by `/next-issue` must exist.

## Step 1 — Read State

1. **Discover the current state file**:

   - List JSON state files: `ls .claude/memory/tmp/next-issue-*.json 2>/dev/null`
   - **If multiple files exist**: list them and ask which issue to ship
   - **If exactly one file**: use it
   - **If none exist**: check for legacy `.md` files:
     - `ls .claude/memory/tmp/next-issue-*.md 2>/dev/null`
     - If found, migrate to `.json`: read YAML frontmatter fields, write `.json`
       with those fields plus `"version": 2`, delete the `.md` file
     - Also check for `.claude/memory/tmp/next-issue-state.md` (legacy singleton)
       — read its `issue:` field, migrate to `.claude/memory/tmp/next-issue-{N}.json`

1. Extract: `issue` (number), `title`, `platform` (`github` or `gitlab`),
   `branch` (if set)

1. If no state file is found, tell the user:

   > No in-progress issue found. Run `/next-issue` first to select and plan
   > an issue.

   Then stop.

## Step 2 — Detect Platform

Use the `platform` field from the state file. If missing, detect from
`git remote -v`:

| Pattern in remote URL     | Platform | CLI    |
| ------------------------- | -------- | ------ |
| `github.com` or `ghe.`    | GitHub   | `gh`   |
| `gitlab.com` or `gitlab.` | GitLab   | `glab` |

## Step 2.5 — Agent Worktree Detection

Check if the current branch is an agent worktree:

```bash
CURRENT_BRANCH=$(git branch --show-current)
```

If `$CURRENT_BRANCH` matches `^agent` (e.g., `agent01`, `agent02`):

- **Skip Step 3** (do not ask the user for shipping mode)
- **Go directly to Option 3** (commit only, no push)
- Agents never create PRs or push — the orchestrator owns delivery

If the branch does not match `^agent`, proceed to Step 3 as normal.

## Step 3 — Choose Shipping Mode

Use `AskUserQuestion` to present three options:

**Option 1 — Branch + PR** (recommended for feature work):

> Create a feature branch (if not already on one), commit, push, and open a
> pull request. Adds `status/pr-pending` label to the issue.

**Option 2 — Commit to main + push**:

> Commit directly to main and push. The `Closes #{N}` keyword auto-closes
> the issue on push.

**Option 3 — Commit only (no push)**:

> Commit on the current branch but do not push. Adds `status/commit-pending`
> label so the issue is not re-selected.

## Step 4 — Execute

### Option 1 — Branch + PR

1. **Ensure on a feature branch**:

   - If currently on `main` (or the default branch), create and switch to a
     new branch using the naming convention from `next-issue/state-format.md`:

     ```bash
     git fetch origin main
     git checkout -b {prefix}/issue-{N}-{slug} origin/main
     ```

   - If already on a feature branch, stay on it

1. **Stage and commit**. The commit message MUST include `Closes #{N}` in
   the body:

   ```text
   {type}({scope}): {description}

   {optional body explaining the change}

   Closes #{N}
   ```

   Where `{type}` matches the branch prefix: `fix/` → `fix:`,
   `feature/` → `feat:`, `docs/` → `docs:`, `test/` → `test:`,
   `refactor/` → `refactor:`, `chore/` → `chore:`.

1. **Verify** the commit message: run `git log -1 --format=%B` and confirm
   `Closes #{N}` is present. If missing, amend to add it.

1. **Push** the branch:

   ```bash
   git push -u origin HEAD
   ```

1. **Create a PR**:

   - GitHub:

     ```bash
     gh pr create --title "{type}({scope}): {description}" --body "$(cat <<'EOF'
     ## Summary
     - {what changed and why}

     ## Test plan
     - {how this was tested}

     Closes #{N}
     EOF
     )"
     ```

   - GitLab:

     ```bash
     glab mr create --title "{type}({scope}): {description}" \
       --description "## Summary\n- {what changed and why}\n\n## Test plan\n- {how this was tested}\n\nCloses #{N}"
     ```

1. **Label the issue** `status/pr-pending` and remove `status/in-progress`:

   - GitHub: `gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/pr-pending" --unlabel "status/in-progress"`

1. **Comment on the issue**:

   - GitHub: `gh issue comment {N} --body "Fix submitted in PR #{pr_number}"`
   - GitLab: `glab issue note {N} --message "Fix submitted in MR !{mr_number}"`

1. **Checkout main**: `git checkout main`

1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`)

1. **Show the PR/MR URL** to the user

### Option 2 — Commit to main + push

1. Ensure on `main` (or warn if on a different branch and confirm)

1. **Stage and commit** with `Closes #{N}` in the body (same format as above)

1. **Verify** the commit message includes `Closes #{N}`

1. **Push**:

   ```bash
   git push origin main
   ```

1. **Remove `status/in-progress` label**:

   - GitHub: `gh issue edit {N} --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --unlabel "status/in-progress"`

1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`;
   the `Closes` keyword auto-closes the issue on push)

1. Tell the user the issue will auto-close when the push is processed

### Option 3 — Commit only (no push)

1. **Stage and commit** with `Closes #{N}` in the body (same format as above)
1. **Verify** the commit message includes `Closes #{N}`
1. **Do NOT push**
1. **Label the issue** `status/commit-pending` and remove `status/in-progress`:
   - GitHub: `gh issue edit {N} --add-label "status/commit-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/commit-pending" --unlabel "status/in-progress"`
1. **Comment on the issue** with the commit SHA:
   - **Agent mode** (branch matches `^agent`):
     - GitHub: `gh issue comment {N} --body "Agent {branch} committed fix. Ready for orchestrator review. Commit: {sha}"`
     - GitLab: `glab issue note {N} --message "Agent {branch} committed fix. Ready for orchestrator review. Commit: {sha}"`
   - **Normal mode**:
     - GitHub: `gh issue comment {N} --body "Fix committed locally (not yet pushed). Commit: {sha}"`
     - GitLab: `glab issue note {N} --message "Fix committed locally (not yet pushed). Commit: {sha}"`
1. **Delete state file** (remove `.claude/memory/tmp/next-issue-{N}.json`)
1. Tell the user the commit is local and needs to be pushed later

## Step 5 — Context Reset & Continue

After shipping, tell the user:

> Issue #{N} shipped. Run `/clear` to start fresh, then `/next-issue` to
> pick up the next issue.

Then ask with `AskUserQuestion`:

- **Pick next issue** — invoke `/next-issue` to select and plan the next one
- **Stop** — end the session

**Agent worktree mode**: When running on an agent branch (`^agent`), this
behavior persists across invocations — `/next-issue-ship` will always
auto-select commit-only mode (Option 3) without prompting.
