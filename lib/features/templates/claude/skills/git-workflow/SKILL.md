---
description: Git workflow conventions and best practices
---

# Git Workflow

## Commit Messages

- Use conventional commits: feat:, fix:, chore:, docs:, test:, refactor:
- Keep subject line under 72 characters
- Use imperative mood ("Add feature" not "Added feature")
- Add body for non-trivial changes explaining why, not what

## Branch Naming

- feature/<description> - New features
- fix/<description> - Bug fixes
- chore/<description> - Maintenance tasks
- docs/<description> - Documentation changes

## Pre-commit Hooks

- Run existing hooks; don't skip with --no-verify
- Fix issues rather than bypassing checks
- If a hook fails, the commit did NOT happen - create a new commit after fixing

## PR Workflow

- Keep PRs focused and reviewable
- Include tests for new functionality
- Update documentation when changing behavior
- Use descriptive PR titles under 70 characters

## Git Safety

- Never force-push to main/master without explicit instruction
- Never run destructive commands (reset --hard, clean -f) without asking
- Prefer creating new commits over amending published commits
- Stage specific files rather than using git add -A
