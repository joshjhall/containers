# Orchestrate — Merge Protocol

Reference companion for `SKILL.md`. Load this when performing a merge (Phase 2),
review (Phase 3), or sync (Phase 4) for sync point tracking, conflict
resolution, test runner detection, review dispatch, and branch synchronization.

______________________________________________________________________

## Sync Point Tracking

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

______________________________________________________________________

## Conflict Resolution Decision Tree

When `git merge` reports conflicts:

1. **Identify conflict type** for each file:

   ```bash
   git diff --name-only --diff-filter=U
   ```

1. **For each conflicted file**, examine the conflict:

   ```bash
   git diff <file>
   ```

1. **Resolution strategy by conflict type**:

   | Conflict Type                  | Action                                                           |
   | ------------------------------ | ---------------------------------------------------------------- |
   | Both sides added imports       | Combine both import sets, deduplicate, sort                      |
   | Whitespace / formatting only   | Accept agent's version (`git checkout --theirs <file>`)          |
   | Same function modified         | Show both versions to user, ask which to keep or how to merge    |
   | New file vs new file           | Show both, ask user — usually keep both with renamed paths       |
   | Deletion vs modification       | Ask user — deletion usually wins unless modification is critical |
   | Lock files (package-lock, etc) | Regenerate: accept one side, then re-run the package manager     |

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

______________________________________________________________________

## Test Runner Detection

After merging, detect and run the project's test suite. Check in this order
(first match wins):

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

______________________________________________________________________

## Squash vs Merge Commit

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

______________________________________________________________________

## Review Protocol

After merging agent work (Phase 2), Phase 3 reviews the merged changes for
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

1. **`code-reviewer` agent** — always dispatched first. Reviews the merge diff
   for bugs, security issues, performance problems, and style violations.
1. **`test-writer` agent** — dispatched only if code-reviewer findings indicate
   missing test coverage or if new public APIs were introduced without tests.

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

______________________________________________________________________

## Sync Protocol

Phase 4 pushes the latest orchestrator state into all agent branches so they
start their next task from a consistent baseline.

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
