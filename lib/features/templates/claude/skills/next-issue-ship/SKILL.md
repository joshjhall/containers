---
description: Ship the current next-issue work — commit, deliver (PR or push), label the issue, and optionally loop back. Use after implementation and testing are complete for an issue started with /next-issue.
---

# Next Issue — Ship

Delivers the completed work for an issue previously selected and planned by
`/next-issue`. Handles committing, pushing, PR creation, issue labeling, and
state cleanup.

**Prerequisite**: Implementation and testing must be complete before invoking
this skill. The state file written by `/next-issue` must exist.

## Environment Variables

Two env vars toggle non-default behavior; both are opt-in:

- `AUTOMERGE=1` — in Option 1 (Branch + PR), queue the PR for GitHub's
  native auto-merge via `gh pr merge --auto --squash --delete-branch`
  immediately after PR creation and exit, skipping the CI-wait loop.
  GitHub only. Skipped for `severity/critical` issues. Falls through to
  the normal CI-wait loop if `gh pr merge --auto` fails (e.g., auto-merge
  not enabled on the repo). See Option 1 "Auto-merge fast path" below.
- `PRE_REVIEW_STRICT=true` — pre-review gates (Step 3.5) block Option 1 PR
  creation on HIGH certainty findings instead of warning only.

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

## Step 3.5 — Pre-Ship Validation

Before executing the chosen shipping mode, run these safety checks:

1. **Run test suite** — auto-detect the project's test runner (see
   `orchestrate/merge-protocol.md` § Test Runner Detection for the detection
   order: `package.json` → `pyproject.toml` → `go.mod` → `Cargo.toml` →
   `Gemfile` → `Makefile` → `build.gradle`).

   - If tests **pass**: proceed to Step 4
   - If tests **fail**:
     - Show the failure summary to the user
     - Ask: **Fix failures now, or ship anyway?**
     - **Option 1 (Branch + PR)**: test failure is **blocking** — do NOT
       create a PR with failing tests. The user must fix first or switch to
       Option 3 (commit only)
     - **Option 2/3**: test failure is **advisory** — warn but allow commit
   - If **no test runner detected**: skip this check and note it in the output

1. **Verify git status** — check for untracked files that look like they
   should be staged (new source files, new test files). Warn if found.

1. **Check branch freshness** (Option 1 only) — if on a feature branch,
   check if main has advanced:

   ```bash
   git fetch origin main
   git rev-list --count HEAD..origin/main
   ```

   If count > 0, warn: "Main has {N} new commits since this branch was
   created. Consider rebasing before PR."

1. **Check for plan drift** (optional) — fetch the issue body and check for
   "Affected Files" or "Acceptance Criteria" sections. If either exists,
   run drift analysis (see `drift-detect` skill for full workflow):

   - Compare planned files from the issue against actual files from
     `git diff --name-only origin/main...HEAD`
   - Check acceptance criteria checkboxes for unaddressed items
   - **If HIGH-severity drift found**: warn and ask — "Fix drift now,
     ship anyway, or skip?"
   - **If only MEDIUM/LOW drift**: show summary, proceed automatically
   - **If no plan sections found in issue**: skip this check silently

   This check is advisory — the user can always choose to ship anyway.

1. **Pre-review gates** (advisory by default) — run deterministic quality
   scanning on changed files to catch mechanical issues before review:

   a. Generate file list from the diff:

   ```bash
   git diff --name-only origin/main...HEAD > /tmp/pre-review-files.txt
   ```

   b. Run the pre-review scanner (locate `pre-review-gates.sh` in the same
   directory as this skill file):

   ```bash
   bash pre-review-gates.sh /tmp/pre-review-files.txt
   ```

   c. Parse TSV output — each line: `file\tline\tcategory\tevidence\tcertainty`

   **Categories detected:**

   | Category              | What it catches                                  | Certainty |
   | --------------------- | ------------------------------------------------ | --------- |
   | `ai-slop`             | Hedging phrases, buzzword inflation, filler text | HIGH      |
   | `debug-statement`     | print(), console.log, debugger, breakpoint       | HIGH      |
   | `missing-test-file`   | Source files with no corresponding test file     | HIGH      |
   | `untested-public-api` | Public functions not referenced in any test file | HIGH      |

   **Handling findings:**

   - **No findings**: proceed silently to Step 4
   - **Findings exist (advisory mode — the default)**:
     - Show a summary table: category, count, top examples
     - For HIGH certainty `ai-slop` or `debug-statement` findings: offer to
       auto-fix (remove debug lines, trim AI slop phrases) before committing
     - For `missing-test-file` / `untested-public-api`: note these in the PR
       description (Option 1) so reviewers are aware
     - Proceed to Step 4 regardless of findings
   - **Strict mode** (`PRE_REVIEW_STRICT=true` in environment):
     - HIGH certainty findings **block Option 1** (PR creation) — the user
       must fix them or explicitly choose "ship anyway"
     - Options 2/3 remain advisory (warn only)

   **PR description integration** (Option 1 only): if findings remain after
   auto-fix, append a "Pre-review findings" section to the PR body:

   ```markdown
   ## Pre-review findings
   - 2x debug-statement (src/handler.py:42, src/utils.py:18)
   - 1x missing-test-file (src/new_module.py)
   ```

   **Graceful degradation**: if `pre-review-gates.sh` is not found or fails
   to execute, skip this check with a note: "Pre-review gates skipped
   (scanner not available)." Never block shipping due to scanner errors.

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

1. **Auto-merge fast path** (if `AUTOMERGE=1`):

   When `AUTOMERGE=1` is set in the environment, hand the PR off to
   GitHub's native auto-merge and skip the CI-wait loop below. This is
   intended for routine low-risk issues where "wait for checks, then merge"
   is pure overhead.

   **Skip conditions** (fall through to the CI-wait loop instead):

   - Platform is not GitHub — the toggle is GitHub-only
   - Issue carries `severity/critical` — print
     `"auto-merge skipped (severity/critical)"` and continue
   - `gh pr merge --auto` exits non-zero (e.g., auto-merge not enabled on
     the repo) — log the error output and continue

   Otherwise:

   ```bash
   gh pr merge "$PR_NUM" --auto --squash --delete-branch
   ```

   On success, do the Option 1 cleanup inline and exit the skill:

   a. Update the state file `.claude/memory/tmp/next-issue-{N}.json` so
   `"phase"` is `"auto-merge-queued"` (preserves an audit trail if any
   step after this fails before the file is deleted)
   b. Label the issue `status/pr-pending` and remove `status/in-progress`:

   ```bash
   gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"
   ```

   c. Comment on the issue:

   ```bash
   gh issue comment {N} --body "Fix submitted in PR #{pr_number}. Queued for auto-merge (squash + delete-branch)."
   ```

   d. `git checkout main`
   e. Delete the state file (`.claude/memory/tmp/next-issue-{N}.json`)
   f. Show the PR URL to the user
   g. **Exit** — do not proceed to the CI-wait loop, labeling, or any other
   subsequent step in this option

   **Squash-by-default rationale**: `/next-issue` PRs are single-issue,
   single-deliverable units; squash keeps history linear and the merged
   commit still references the issue. Users who want merge-commits can
   run Option 1 without `AUTOMERGE=1`.

1. **Monitor CI and remediate failures** (advisory, max 3 iterations):

   Before labeling the issue, optionally monitor CI checks and auto-fix
   failures. Ask the user:

   - **Wait for CI** — monitor checks and auto-fix failures if possible
   - **Skip CI monitoring** — proceed to labeling immediately

   If the user chooses to wait:

   a. **Poll for check completion**:

   - GitHub: `gh pr checks {pr_number} --json name,state,conclusion`
     (poll every 30 seconds until no checks have `state: "pending"`)
   - GitLab: `glab ci status` (check for completion)

   b. **If all checks pass**: inform the user and proceed to labeling

   c. **If checks fail** (iteration \<= 3):

   - Identify the failing check name and run ID:

     ```bash
     gh pr checks {pr_number} --json name,state,conclusion,link \
       | jq '[.[] | select(.conclusion == "failure")]'
     ```

   - Fetch failing check logs:

     ```bash
     gh run view {run_id} --log-failed 2>&1 | tail -200
     ```

   - Dispatch the `ci-fixer` agent with the failure logs, check name,
     PR number, and current iteration number

   - **If ci-fixer returns `"fixed"`**:

     - Stage the changed files
     - Commit: `fix(ci): {summary from ci-fixer}`
     - Push: `git push`
     - Increment iteration counter
     - Go back to (a) to re-check

   - **If ci-fixer returns `"unfixable"`**:

     - Inform the user: "CI failure appears to be {failure_type} —
       {summary}. Requires manual intervention."
     - Ask: **Fix manually now, or ship with failing CI?**
     - If fix manually: pause for user to fix, then go back to (a)
     - If ship anyway: proceed to labeling

   d. **After 3 failed remediation attempts**: stop auto-fixing and inform
   the user: "CI has failed 3 remediation attempts. Manual intervention
   needed." Ask whether to ship with failing CI or stop.

   **Graceful degradation**: If `gh pr checks` is unavailable or errors,
   skip CI monitoring with a note and proceed to labeling. CI monitoring
   never blocks shipping.

1. **Label the issue** `status/pr-pending` and remove `status/in-progress`:

   - GitHub: `gh issue edit {N} --add-label "status/pr-pending" --remove-label "status/in-progress"`
   - GitLab: `glab issue update {N} --label "status/pr-pending" --unlabel "status/in-progress"`

1. **Comment on the issue**:

   If CI remediation was performed, include a summary in the comment:

   - GitHub: `gh issue comment {N} --body "Fix submitted in PR #{pr_number}. CI remediation: {N} fix(es) applied automatically."`
   - GitLab: `glab issue note {N} --message "Fix submitted in MR !{mr_number}. CI remediation: {N} fix(es) applied automatically."`

   If no CI remediation was needed or CI was skipped:

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
