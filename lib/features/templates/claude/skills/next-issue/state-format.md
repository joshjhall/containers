# Next Issue — State & Reference

Reference companion for `SKILL.md`. Load this at the start of every
`/next-issue` invocation for the state file schema, priority query commands,
and branch naming rules.

______________________________________________________________________

## State File

Path: `.claude/memory/next-issue-state.md`

### Schema

Write as YAML frontmatter only (no body content):

```yaml
---
issue: 101
title: "Fix critical auth bypass in session handler"
phase: implement
branch: fix/issue-101-auth-bypass
plan: "Validate session token expiry before granting access"
started: "2026-02-27"
platform: github
---
```

### Fields

| Field      | Required | Description                                          |
| ---------- | -------- | ---------------------------------------------------- |
| `issue`    | yes      | Issue number (integer)                               |
| `title`    | yes      | Issue title (string)                                 |
| `phase`    | yes      | Current phase: `select`, `plan`, `implement`, `ship` |
| `branch`   | no       | Branch name (set in Phase 3)                         |
| `plan`     | no       | One-line plan summary (set in Phase 2)               |
| `started`  | yes      | ISO date when work began                             |
| `platform` | yes      | `github` or `gitlab`                                 |

### State Lifecycle

**Write state** — use Write tool with the YAML frontmatter above.

**Clear state** — after successful ship, write empty content.

**Stale state detection** — before offering to resume, validate:

1. Check if the issue is still open:
   - GitHub: `gh issue view {N} --json state --jq .state`
   - GitLab: `glab issue view {N}`
1. Check if the branch exists: `git branch --list {branch}`
1. If issue is closed or branch is gone → silently clear the file and
   proceed to Phase 1 (don't ask the user about stale work)

______________________________________________________________________

## Priority Ordering

Query issues in this order — first match wins. This is a nested loop:
severity (descending) x effort (ascending), so critical+trivial issues are
picked first and low+large issues last.

### GitHub (`gh`)

```bash
# Loop through severity levels (most critical first)
for severity in critical high medium low; do
  # Within each severity, prefer smaller effort
  for effort in trivial small medium large; do
    gh issue list \
      --label "severity/${severity}" \
      --label "effort/${effort}" \
      --state open \
      --assignee "" \
      --limit 1 \
      --json number,title,labels,body
  done
done
```

### GitLab (`glab`)

```bash
for severity in critical high medium low; do
  for effort in trivial small medium large; do
    glab issue list \
      --label "severity/${severity}" \
      --label "effort/${effort}" \
      --not-assignee \
      --per-page 1
  done
done
```

### Fallback

If no labeled issues match, fall back to the oldest open issue:

```bash
# GitHub
gh issue list --state open --limit 1 --json number,title,labels,body

# GitLab
glab issue list --per-page 1
```

______________________________________________________________________

## Branch Naming Convention

Format: `{prefix}/issue-{N}-{slug}`

### Prefix Derivation

Derive from issue labels. First match wins:

| Label pattern       | Prefix      | Example                         |
| ------------------- | ----------- | ------------------------------- |
| `type/bug` or `fix` | `fix/`      | `fix/issue-101-auth-bypass`     |
| `type/feature`      | `feature/`  | `feature/issue-42-user-search`  |
| `type/docs`         | `docs/`     | `docs/issue-55-api-reference`   |
| `type/test`         | `test/`     | `test/issue-60-add-unit-tests`  |
| `type/refactor`     | `refactor/` | `refactor/issue-70-split-utils` |
| (no type label)     | `chore/`    | `chore/issue-99-update-deps`    |

### Slug Derivation

From the issue title:

1. Lowercase the title
1. Replace non-alphanumeric characters with hyphens
1. Collapse consecutive hyphens
1. Trim to 40 characters max
1. Remove trailing hyphens

Example: `"Fix Critical Auth Bypass in Session Handler"` → `fix-critical-auth-bypass-in-session-handler` → trimmed to `fix-critical-auth-bypass-in-session`

### Branch Creation

Always branch from the latest remote main:

```bash
git fetch origin main
git checkout -b {prefix}/issue-{N}-{slug} origin/main
```

______________________________________________________________________

## Integration Notes

### git-workflow

Follow commit conventions from the `git-workflow` skill:

- Conventional commit prefix: `feat:`, `fix:`, `chore:`, `docs:`, `test:`,
  `refactor:`
- Include `Closes #{N}` in the commit body
- Keep subject under 72 characters, imperative mood

### development-workflow

For `effort/medium` and `effort/large` issues, load
`development-workflow/phase-details.md` and follow its phased approach:

- Phase 1 (Make it Work) — get the core change working
- Phase 2 (Make it Right) — clean up, add proper error handling
- Phase 3 (Make it Tested) — add/update tests

For `effort/trivial` and `effort/small` issues, a brief inline plan suffices.

### codebase-audit

The priority labels (`severity/*`, `effort/*`) are created by the
`/codebase-audit` command's issue-writer agents. This skill is designed to
consume those labels directly — no label mapping needed.

### Commit Message for Issue Closure

**CRITICAL**: Every commit MUST include `Closes #{N}` in the body. Without
this, the issue will not auto-close when the PR is merged.

```text
{type}({scope}): {description}

{optional body explaining the change}

Closes #{N}
```

Where `{type}` matches the branch prefix (`fix` → `fix:`, `feature` → `feat:`,
`refactor` → `refactor:`, etc.).

**Verification**: After committing, run `git log -1 --format=%B` to confirm
the `Closes #{N}` line is present. If missing, amend to add it.
