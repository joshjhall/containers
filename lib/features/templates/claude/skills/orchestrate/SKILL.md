---
description: Multi-agent orchestration for parallel worktree workflows. Check agent branch status, merge agent commits into current branch. Use when coordinating 2-5 agents working in separate worktrees, reviewing agent progress, or integrating agent work.
---

# Orchestrate

**Companion file**: See `merge-protocol.md` in this skill directory for sync
point tracking, conflict resolution decision tree, test runner detection, and
squash vs merge tradeoffs. Load it when performing a merge (Phase 2).

**Invocation patterns:**

- `/orchestrate` or `/orchestrate status` → Phase 1 (agent status)
- `/orchestrate merge <N>` or `/orchestrate merge <branch>` → Phase 2 (merge one agent)
- `/orchestrate merge all` → Phase 2 for all agents with pending commits

## Phase 1 — Agent Status

1. **Discover agent worktrees** via primary and fallback methods:

   ```bash
   # Primary: git worktree list (filter agent branches)
   git worktree list --porcelain | grep -E 'branch refs/heads/agent'

   # Secondary: directory scan
   ls -d /workspace/*-agent*/ 2>/dev/null
   ```

1. **For each agent branch**, gather:

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
   # Look for issues with status/commit-pending label assigned to this work
   gh issue list --label "status/commit-pending" --state open --json number,title,assignees
   ```

1. **Output a status table**:

   ```text
   # Agent Status

   | # | Branch   | Latest Commit        | Age   | Pending Commits | Issue |
   |---|----------|----------------------|-------|-----------------|-------|
   | 1 | agent01  | abc1234 feat: add X  | 2h    | 3               | #42   |
   | 2 | agent02  | def5678 fix: handle Y| 30m   | 1               | #55   |
   | 3 | agent03  | (no new commits)     | —     | 0               | —     |
   ```

   Agents with 0 pending commits are shown but marked as up-to-date.

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
   - For each conflict, display the conflict markers and surrounding context
   - Ask the user for resolution guidance
   - After resolving, complete the merge: `git add . && git commit`

1. **Run tests** (see `merge-protocol.md` for test runner detection):

   ```bash
   # Auto-detect and run the project's test suite
   # npm test | pytest | go test ./... | cargo test | etc.
   ```

   Report test results. If tests fail, warn the user but do not auto-revert.

1. **Report**: Show final merge result with commit hash and summary.

## When to Use

- Checking progress of parallel agents working in worktrees
- Integrating completed agent work into the main development branch
- Coordinating multi-agent workflows (2-5 agents)
- After agents signal completion (e.g., via `status/commit-pending` label)

## When NOT to Use

- Single-agent workflows (no worktrees to orchestrate)
- Cross-repository coordination (handle manually or via PRs)
- When agents are still actively working (check status first, merge when ready)
- For PR-based workflows where agents push branches for review (use standard PR flow)
