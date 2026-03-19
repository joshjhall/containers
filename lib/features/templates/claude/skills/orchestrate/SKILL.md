---
description: Multi-agent orchestration for parallel worktree workflows. Check agent status, merge agent commits, review merged work, and sync agent branches. Use when coordinating 2-5 agents working in separate worktrees, reviewing agent progress, or integrating agent work.
---

# Orchestrate

**Companion file**: See `merge-protocol.md` in this skill directory for sync
point tracking, conflict resolution decision tree, test runner detection,
squash vs merge tradeoffs, review dispatch protocol, and sync protocol. Load it
when performing a merge (Phase 2), review (Phase 3), or sync (Phase 4).

**Invocation patterns:**

- `/orchestrate` or `/orchestrate status` → Phase 1 (agent status)
- `/orchestrate merge <N>` or `/orchestrate merge <branch>` → Phase 2 (merge one agent)
- `/orchestrate merge all` → Phase 2 for all agents with pending commits
- `/orchestrate review` → Phase 3 (review latest merge)
- `/orchestrate sync` → Phase 4 (sync orchestrator into agent branches)

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
   agents, remove `status/commit-pending`:

   - GitHub: `gh issue edit {N} --remove-label "status/commit-pending"`
   - GitLab: `glab issue update {N} --unlabel "status/commit-pending"`

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

## When to Use

- Checking progress of parallel agents working in worktrees
- Integrating completed agent work into the main development branch
- Reviewing merged agent work for correctness and quality
- Syncing agent branches with the latest orchestrator state
- Coordinating multi-agent workflows (2-5 agents)
- After agents signal completion (e.g., via `status/commit-pending` label)

## When NOT to Use

- Single-agent workflows (no worktrees to orchestrate)
- Cross-repository coordination (handle manually or via PRs)
- When agents are still actively working (check status first, merge when ready)
- For PR-based workflows where agents push branches for review (use standard PR flow)
