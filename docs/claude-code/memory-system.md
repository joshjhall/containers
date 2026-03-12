# Memory System

Two-tier memory convention for `.claude/memory/` that distinguishes committed
team knowledge from ephemeral session state.

## Overview

| Tier       | Path                  | Git status | Purpose                          |
| ---------- | --------------------- | ---------- | -------------------------------- |
| Long-term  | `.claude/memory/*.md` | Committed  | Team knowledge, shared decisions |
| Short-term | `.claude/memory/tmp/` | Gitignored | Ephemeral per-session state      |

## Long-term Memory (committed)

Files in `.claude/memory/` (excluding `tmp/`) are committed to the repository
and shared across all developers. Use this tier for:

- **Architecture decisions** — why a pattern was chosen, trade-offs considered
- **Project conventions** — naming rules, code style preferences beyond linters
- **Team knowledge** — domain terminology, stakeholder context, deployment notes
- **Onboarding context** — things a new contributor needs to know that aren't
  obvious from the code

### Examples

```text
.claude/memory/architecture-auth.md    # Why we use JWT + refresh tokens
.claude/memory/conventions-api.md      # REST naming and versioning rules
.claude/memory/team-deploy-process.md  # Deploy checklist and rollback steps
```

## Short-term Memory (gitignored)

The `.claude/memory/tmp/` directory is gitignored and used for ephemeral
per-session state. Use this tier for:

- **Workflow state** — current issue being worked on, phase tracking
- **Scratch notes** — temporary analysis results, debug context
- **Session continuity** — state that survives context window resets but
  doesn't need to persist across container rebuilds or team members

### Examples

```text
.claude/memory/tmp/next-issue-state.md  # Current issue workflow state
.claude/memory/tmp/debug-session.md     # Temporary debugging notes
```

## Convention for Skill Authors

When writing skills that persist state:

- **Workflow state** (current issue, progress tracking) → `tmp/`
- **Durable knowledge** (learned conventions, team decisions) → root `memory/`
- State files should use YAML frontmatter for structured data
- Always handle missing files gracefully (the directory may not exist yet)

## What NOT to Store in Memory

These are better served by other mechanisms:

- **Code patterns and conventions** — derivable from reading current code
- **Git history** — use `git log` / `git blame`
- **Debugging solutions** — the fix is in the code; context is in the commit
- **Anything in CLAUDE.md** — already loaded into every conversation

## Migration Note

Existing projects with `.claude/memory/` in their `.gitignore` can narrow the
pattern to `.claude/memory/tmp/` to enable long-term committed memories. The
container health check (`40-project-health-check.sh`) only appends entries —
it never removes existing lines — so this change requires a manual edit of
the project's `.gitignore`.

Steps:

1. Edit `.gitignore`: change `.claude/memory/` to `.claude/memory/tmp/`
1. Create `.claude/memory/tmp/` and add a `.gitkeep` if desired
1. Commit the `.gitignore` change
1. Any existing `.claude/memory/*.md` files can now be committed as long-term
   team knowledge
