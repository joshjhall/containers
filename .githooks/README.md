# Git Hooks

This directory contains optional git hooks for code quality checks.

## Setup

To enable these hooks for your local development:

```bash
# Enable the hooks
git config core.hooksPath .githooks

# Or disable them
git config --unset core.hooksPath
```

## Available Hooks

### pre-commit

Runs shellcheck on staged shell scripts to catch issues before commit.

**Configuration:**

- `SHELLCHECK_SEVERITY` - Set severity level (error, warning, info, style).
  Default: error
- `SHELLCHECK_ENABLED` - Enable/disable shellcheck. Default: true

**Examples:**

```bash
# Only block on errors (default)
export SHELLCHECK_SEVERITY=error
git commit -m "your message"

# Block on warnings too
export SHELLCHECK_SEVERITY=warning
git commit -m "your message"

# Disable shellcheck temporarily
export SHELLCHECK_ENABLED=false
git commit -m "your message"

# Skip hooks for one commit
git commit --no-verify -m "your message"
```

## Philosophy

These hooks are designed to be:

1. **Non-intrusive** - Only check changed files
1. **Configurable** - Easy to adjust strictness
1. **Skippable** - Can bypass when needed
1. **Informative** - Show issues without always blocking

## Troubleshooting

If the hooks are too strict for your workflow:

1. Adjust `SHELLCHECK_SEVERITY` to only block on errors
1. Use `--no-verify` when you need to commit work-in-progress
1. Disable hooks entirely with `git config --unset core.hooksPath`

The goal is to improve code quality without disrupting development flow.
