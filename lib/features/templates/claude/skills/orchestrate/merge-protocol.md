# Orchestrate — Merge & Rebase Protocol

Reference companion for `SKILL.md`.

> **Topology note.** The default `/orchestrate` topology is PR-per-golem
> (`SKILL.md` Phases D/M/R). The **merge** and **sync** sections below are
> **OPT-IN LEGACY local-merge** — used only for tightly-coupled no-PR worktree
> work. The **Conflict Classification** and **Test Runner Detection** sections
> are **repurposed and remain live**: they drive the cross-PR rebase (Phase R,
> via `workflow.js` + the `rebase-agent`) as well as the legacy local merge.

Each section below is tagged **[LIVE]** (used by the default PR-per-golem flow)
or **[OPT-IN LEGACY]** (local-merge only).

---

## Sync Point Tracking [OPT-IN LEGACY]

Use `git merge-base` to track where agent branches diverged from the current
branch. This is the foundation for determining what's new.

```bash
# Find divergence point
MERGE_BASE=$(git merge-base HEAD <agent-branch>)

# List new commits on agent branch
git log --oneline "$MERGE_BASE"..<agent-branch>

# Count new commits
git rev-list --count "$MERGE_BASE"..<agent-branch>

# Check if already fully merged (0 = merged)
git rev-list --count "$MERGE_BASE"..<agent-branch>
```

After a successful merge, the merge-base advances automatically — no manual
bookkeeping needed. Subsequent `/orchestrate status` calls will show 0 pending
commits for that agent.

---

## Conflict Classification for Cross-PR Rebase [LIVE]

This decision tree is the source of the `workflow.js` conflict-class taxonomy
(the `OVERLAP` gate and the `rebase-agent`'s `resolved`/`escalated` split) used
in Phase R, and it also governs legacy local-merge conflicts.

When a PR branch is behind base and a rebase onto base reports conflicts (or
when `git merge` reports conflicts in the legacy path):

1. **Identify conflict type** for each file:

   ```bash
   git diff --name-only --diff-filter=U
   ```

1. **For each conflicted file**, examine the conflict:

   ```bash
   git diff <file>
   ```

1. **Resolution strategy by conflict type**:

   Trivial conflicts can be auto-resolved by dispatching the `rebase-agent`:

   | Conflict Type                   | Action                                                      | Agent                           |
   | ------------------------------- | ----------------------------------------------------------- | ------------------------------- |
   | Lock files (package-lock, etc)  | Regenerate: accept one side, re-run package manager         | rebase-agent (rebase-lockfile)  |
   | Generated files (\*.pb.go, etc) | Accept one side, re-run generator                           | rebase-agent (rebase-generated) |
   | Both sides added imports        | Combine both import sets, deduplicate, sort                 | rebase-agent (rebase-imports)   |
   | Version number conflicts        | Take the higher version                                     | rebase-agent (rebase-version)   |
   | Whitespace / formatting only    | Accept agent's version (`git checkout --theirs <file>`)     | rebase-agent                    |
   | Same function modified          | **Escalate** — show both versions to user, ask for guidance | (human)                         |
   | New file vs new file            | **Escalate** — show both, ask user                          | (human)                         |
   | Deletion vs modification        | **Escalate** — ask user                                     | (human)                         |

   To dispatch the rebase-agent for trivial conflicts:

   ```text
   Agent tool: rebase-agent
   Prompt: "Resolve the following merge conflicts. Conflicted files: {file_list}.
   For each file, classify the conflict and apply the appropriate strategy.
   Escalate non-trivial conflicts."
   ```

1. **After resolving all conflicts**:

   ```bash
   git add <resolved-files>
   git commit  # Completes the merge
   ```

1. **If conflicts are too complex**: Abort and suggest alternative:

   ```bash
   git merge --abort
   ```

   Suggest cherry-picking specific commits instead, or ask the user to
   manually resolve.

---

## Test Runner Detection [LIVE]

Topology-neutral. Used after a cross-PR rebase (Phase R) to confirm the rebased
branch still builds, and after a legacy local merge. Detect and run the
project's test suite, checking in this order (first match wins):

| Indicator                | Test Command            | Framework   |
| ------------------------ | ----------------------- | ----------- |
| `package.json` (test)    | `npm test`              | Node/JS     |
| `pyproject.toml`         | `pytest`                | Python      |
| `setup.py` or `tox.ini`  | `pytest`                | Python      |
| `go.mod`                 | `go test ./...`         | Go          |
| `Cargo.toml`             | `cargo test`            | Rust        |
| `Gemfile`                | `bundle exec rake test` | Ruby        |
| `Makefile` (test target) | `make test`             | Generic     |
| `build.gradle`           | `./gradlew test`        | Java/Kotlin |

**Detection logic:**

```bash
# Check for package.json with test script
if [ -f package.json ] && /usr/bin/grep -q '"test"' package.json; then
    npm test
# Check for Python project
elif [ -f pyproject.toml ] || [ -f setup.py ] || [ -f tox.ini ]; then
    pytest
# Check for Go module
elif [ -f go.mod ]; then
    go test ./...
# Check for Rust project
elif [ -f Cargo.toml ]; then
    cargo test
# Check for Ruby project
elif [ -f Gemfile ]; then
    bundle exec rake test
# Check for Makefile with test target
elif [ -f Makefile ] && /usr/bin/grep -q '^test:' Makefile; then
    make test
# Check for Gradle project
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
    ./gradlew test
fi
```

If no test runner is detected, inform the user and skip testing.

---

## Squash vs Merge Commit [OPT-IN LEGACY]

| Strategy                   | Pros                                                            | Cons                                                  |
| -------------------------- | --------------------------------------------------------------- | ----------------------------------------------------- |
| **Merge commit** (default) | Preserves full agent history; easy to trace what each agent did | More commits in log; noisier `git log --oneline`      |
| **Squash**                 | Clean single commit; ideal for small/focused agent tasks        | Loses individual commit granularity; harder to bisect |

**Recommendations:**

- **Use merge commit** (default) when:

  - Agent made multiple logical changes worth preserving
  - You may need to bisect within the agent's work later
  - Traceability of agent contributions matters

- **Use squash** when:

  - Agent work is a single logical unit (one feature, one fix)
  - Agent made many WIP/fixup commits
  - You want a clean linear history

The user can request squash via `/orchestrate merge <N> --squash` or by asking
for a squash merge in natural language.

---

## Review Protocol [OPT-IN LEGACY]

In the default PR-per-golem topology, per-PR review is the **golem's** job (the
`/next-issue-ship` adversarial review loop). This section applies only after a
legacy local merge (`/orchestrate review`), reviewing the merged changes for
correctness and quality.

### Review Scope

Review **only the merge commit diff** — not the entire file:

```bash
# For the most recent merge commit
MERGE_COMMIT=$(git log -1 --merges --format='%H')

# Diff of just the merge commit (changes introduced by the merge)
git diff "${MERGE_COMMIT}^1" "${MERGE_COMMIT}"

# Files changed in the merge
git diff --name-only "${MERGE_COMMIT}^1" "${MERGE_COMMIT}"
```

### Agent Dispatch Order

1. **`code-review` harness** — always run first, via the `Workflow` tool on
   `~/.claude/agents/code-reviewer/workflow.js`. It reviews the merge diff for
   bugs, security issues, performance problems, and style violations as a
   parallel barrier under a shared budget, with a judge-panel rescore of each
   finding's certainty before merge.
1. **`test-writer` agent** — dispatched only if the code-review findings
   indicate missing test coverage or if new public APIs were introduced
   without tests.

### Correction Commit Convention

All review fixes go into a **single correction commit** per review cycle:

```text
fix(review): {summary of corrections}

{bullet list of changes made}

Reviewed-by: orchestrate Phase 3
```

- One commit per review — do not create multiple fixup commits
- The `Reviewed-by` trailer provides traceability

### What NOT to Auto-Fix

Review should flag but **not automatically change**:

- **Architectural changes** — restructuring modules, changing abstractions
- **API deletions** — removing public interfaces or exported symbols
- **Dependency changes** — adding, removing, or upgrading dependencies
- **Configuration changes** — altering build configs, CI pipelines, env vars

These require user confirmation before modification.

---

## Sync Protocol [OPT-IN LEGACY]

Superseded by PR-per-golem (golems rebase their own PR branches onto base via
Phase R). This one-way orchestrator → agent-branch sync applies only to the
legacy local-merge path, pushing the latest orchestrator state into all agent
branches so they start their next task from a consistent baseline.

### Sync Direction

**Orchestrator → agent branches** (one-way). The orchestrator branch is the
source of truth after merges and reviews.

### Merge Order

Sync agents sequentially in natural order:

```bash
# agent01, agent02, agent03, ...
for branch in $(git branch --list 'agent*' | /usr/bin/sort); do
    # sync logic per branch
done
```

### Conflict Handling

Attempt an auto-merge. If conflicts arise, **abort and skip** that branch:

```bash
git checkout <agent-branch>
git merge <orchestrator-branch> -m "sync: merge orchestrator updates"

# If conflicts:
git merge --abort
# Log the skip, continue to next agent
```

Skipped agents will pick up changes on their next `/orchestrate sync` or when
the orchestrator merges their work (Phase 2) and syncs again.

### Post-Sync Verification

After syncing each branch, verify the merge-base advanced:

```bash
# Merge-base should now equal or be ahead of the previous merge-base
NEW_BASE=$(git merge-base <orchestrator-branch> <agent-branch>)
```

### Label Cleanup

After a successful sync, remove in-flight status labels from issues
associated with synced agent branches (the work has been fully integrated):

```bash
# GitHub
gh issue edit {N} --remove-label "status/commit-pending" --remove-label "status/in-progress"

# GitLab
glab issue update {N} --unlabel "status/commit-pending" --unlabel "status/in-progress"
```

### Return to Orchestrator

Always return to the orchestrator branch after sync completes:

```bash
git checkout <orchestrator-branch>
```

---

## Agent Checkpoint Context [OPT-IN LEGACY]

Used by the legacy local-merge review path. (In PR-per-golem, the golem carries
its own checkpoint and the human reviews the PR.) When reviewing agent work
after a `/clear`, the orchestrator can read the
agent's checkpoint from their JSON state file for context. This is especially
useful when the agent's conversation history is no longer available.

### Reading Agent Checkpoints

Agent state files live in the agent's worktree at
`.claude/memory/tmp/next-issue-{N}.json`. After merging an agent's work, check
if a state file exists with checkpoint data:

```bash
# From the agent's worktree directory
cat .claude/memory/tmp/next-issue-*.json 2>/dev/null
```

The `checkpoint` object contains:

- `key_decisions` — non-obvious choices the agent made (context for review)
- `files_modified` — what the agent changed (scope for review)
- `files_planned` — what the agent intended to change (completeness check)
- `warnings` — things the agent flagged for attention
- `next_action` — what the agent expected to happen next

### Using Checkpoint in Review

When dispatching the `code-reviewer` agent in Phase 3, include relevant
checkpoint context in the review prompt:

- Pass `key_decisions` so the reviewer understands design choices
- Pass `warnings` so the reviewer checks flagged concerns
- Compare `files_planned` vs `files_modified` to verify completeness
