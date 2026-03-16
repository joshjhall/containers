# Orchestrate — Merge Protocol

Reference companion for `SKILL.md`. Load this when performing a merge (Phase 2)
for sync point tracking, conflict resolution, and test runner detection.

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
