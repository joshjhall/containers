# Issue Templates — Agent-Parseable Format

Reference companion for `SKILL.md`. Load when creating or updating issues.
Each template uses H2 headers that agents can reliably parse.

______________________________________________________________________

## Title Conventions

Titles should be concise, specific, and action-oriented:

```markdown
# Good — specific, actionable
Set core.sshCommand globally so VS Code git GUI works with provisioned SSH keys
Add pagination to /api/users endpoint
Fix race condition in session token refresh

# Bad — vague, no action
SSH key issue
API improvement
Fix bug
```

Keep under 70 characters. Use the description for details.

______________________________________________________________________

## Base Template

All issues use this structure. Type-specific sections are inserted after
"Proposed Solution."

```markdown
## Summary

{1-3 sentences: what needs to change and why}

## Problem

{Current behavior or gap. For bugs: what happens. For features: what's missing.
For refactors: what's wrong with current structure.}

## Proposed Solution

{Expected approach. Be specific enough that an agent can plan implementation
without further clarification.}

{TYPE-SPECIFIC SECTIONS — see below}

## Acceptance Criteria

- [ ] {Concrete, testable criterion}
- [ ] {Another criterion}
- [ ] {Each checkbox = one verifiable behavior or state}

## Affected Files

- `path/to/file1.ext` — {what changes}
- `path/to/file2.ext` — {what changes}
- `path/to/directory/` — {scope of changes}

## Context

{Background: what prompted this, related discussions, constraints.
Link related issues with #N format.}
```

______________________________________________________________________

## Type-Specific Sections

Insert these after "Proposed Solution" when applicable.

### Bug (`type/bug`)

```markdown
## Steps to Reproduce

1. {Step 1}
2. {Step 2}
3. {Observe: description of incorrect behavior}

## Expected Behavior

{What should happen instead}
```

### Feature (`type/feature`)

```markdown
## User Story

As a {role}, I want {capability} so that {benefit}.
```

### Refactor (`type/refactor`)

```markdown
## Current State

{What the code looks like now and why it's problematic}

## Target State

{What the code should look like after the refactor}
```

______________________________________________________________________

## Scope Indicators

Include these in the Summary or Affected Files to help effort estimation:

- **File count**: "Affects 3 files in `lib/features/`"
- **Module count**: "Touches auth and session modules"
- **Cross-cutting**: "Requires changes across API, DB, and test layers"

When an issue lists 9+ files or 4+ directories, add a scope warning:

```markdown
> **Scope note**: This issue touches {N} files across {M} directories.
> Consider splitting into smaller issues if independent sub-tasks exist.
```

______________________________________________________________________

## Agent Parsing Notes

Agents consuming these issues (e.g., `/next-issue` Phase 2) can rely on:

- **Summary** is always the first H2 — read for quick context
- **Acceptance Criteria** uses `- [ ]` checkbox format — count for done signal
- **Affected Files** uses backtick-wrapped paths — extract with regex
  `` `([^`]+)` ``
- **Context** contains `#N` issue references — extract related issues
- H2 headers are stable anchors: `## Summary`, `## Problem`,
  `## Proposed Solution`, `## Acceptance Criteria`, `## Affected Files`
