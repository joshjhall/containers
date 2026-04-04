# Next Issue — State & Reference

Reference companion for `SKILL.md`. Load this at the start of every
`/next-issue` invocation for the state file schema, priority query commands,
and branch naming rules.

______________________________________________________________________

## State File

Path: `.claude/memory/tmp/next-issue-{N}.json`

Where `{N}` is the issue number (e.g., `next-issue-101.json` for issue #101).

### JSON Schema

State files are JSON validated against
`schemas/next-issue-state.schema.json` (co-located in this skill directory).
Write using the Write tool:

```json
{
  "version": 2,
  "issue": 101,
  "title": "Fix critical auth bypass in session handler",
  "phase": "implement",
  "branch": "fix/issue-101-auth-bypass",
  "plan": "Validate session token expiry before granting access",
  "started": "2026-02-27",
  "platform": "github",
  "contexts": ["security", "auth"],
  "active_loops": ["make-it-work", "make-it-secure", "make-it-tested"],
  "checkpoint": {
    "completed_phase": "plan",
    "key_decisions": [
      "Using environment variable for timeout, not config file",
      "Session.ts needs backward compat with existing JWT tokens"
    ],
    "files_modified": [],
    "files_planned": [
      "src/config/timeouts.ts",
      "src/auth/session.ts",
      "tests/auth/session.test.ts"
    ],
    "warnings": [
      "Tests currently mock the timeout value — must update mocks"
    ],
    "next_action": "Begin implementation loop: make-it-work"
  }
}
```

### Fields

| Field          | Required | Description                                          |
| -------------- | -------- | ---------------------------------------------------- |
| `version`      | yes      | Always `2` (JSON format)                             |
| `issue`        | yes      | Issue number (integer)                               |
| `title`        | yes      | Issue title (string)                                 |
| `phase`        | yes      | Current phase: `select`, `plan`, `implement`, `ship` |
| `branch`       | no       | Branch name (set after select)                       |
| `plan`         | no       | One-line plan summary (set after plan)               |
| `started`      | yes      | ISO date when work began                             |
| `platform`     | yes      | `github` or `gitlab`                                 |
| `contexts`     | no       | Domain contexts for this issue                       |
| `active_loops` | no       | Implementation loops to execute                      |
| `checkpoint`   | no       | Phase transition checkpoint (see below)              |

### State Lifecycle

**Write state** — use Write tool with the JSON above.

**Clear state** — after successful ship, delete the per-issue state file
(`.claude/memory/tmp/next-issue-{N}.json`).

**Discovery** — to find all active state files:

```bash
ls .claude/memory/tmp/next-issue-*.json 2>/dev/null
```

If no `.json` files found, check for legacy `.md` files:

```bash
ls .claude/memory/tmp/next-issue-*.md 2>/dev/null
```

This returns all in-progress issue state files. Used by Phase 0 for resume
disambiguation when multiple agents are working in parallel.

**Stale state detection** — before offering to resume, validate:

1. Check if the issue is still open:
   - GitHub: `gh issue view {N} --json state --jq .state`
   - GitLab: `glab issue view {N}`
1. Check if the branch exists: `git branch --list {branch}`
1. If issue is closed or branch is gone → silently delete the state file and
   proceed to Phase 1 (don't ask the user about stale work)

______________________________________________________________________

## Backward Compatibility

### Stage 1: Legacy Singleton Migration (existing)

If `.claude/memory/tmp/next-issue-state.md` exists, read its `issue:` field,
rename to `.claude/memory/tmp/next-issue-{N}.md`, then proceed to Stage 2.

### Stage 2: YAML Frontmatter → JSON Migration (new)

If `.claude/memory/tmp/next-issue-{N}.md` files exist (YAML frontmatter
format), migrate each to `.json`:

1. Read the `.md` file and extract YAML frontmatter fields
1. Write a new `.json` file with the same fields plus `"version": 2`
1. Delete the `.md` file

**Edge case**: If both `.md` and `.json` exist for the same issue number,
prefer the `.json` file and delete the `.md` duplicate.

The migration is automatic and happens once during Phase 0 discovery.

______________________________________________________________________

## Checkpoint

The `checkpoint` object captures context that survives a `/clear` reset. It is
written to the state file before each reset point so the next phase can pick
up with full context.

### What to Capture

| Field             | Content                                                     |
| ----------------- | ----------------------------------------------------------- |
| `completed_phase` | Phase that just finished                                    |
| `key_decisions`   | Non-obvious choices that affect downstream work             |
| `files_modified`  | What changed so far (avoids re-scanning)                    |
| `files_planned`   | What still needs to change                                  |
| `warnings`        | Discoveries the next phase should know about                |
| `next_action`     | Explicit directive for post-reset pickup                    |
| `loop_state`      | Implementation loop progress (completed/remaining/criteria) |

### Good vs Bad key_decisions

**Good** (non-obvious, affects downstream):

- "Using environment variable for timeout, not config file"
- "Session.ts needs backward compat with existing JWT tokens"
- "Chose merge commit over squash — agent made 3 distinct logical changes"

**Bad** (derivable from code or too vague):

- "Modified session.ts" (that's what `files_modified` is for)
- "Fixed the bug" (no useful context)
- "Used TypeScript" (obvious from the codebase)

### When to Write Checkpoints

Write or update the checkpoint before every reset point (see Reset Points
below). Each checkpoint overwrites the previous one — only the most recent
phase transition matters.

______________________________________________________________________

## Reset Points

Reset points are natural boundaries where the conversation context can be
safely cleared. The state file (with checkpoint) preserves continuity.

| Pipeline Phase      | Reset Mode | Why                                                              |
| ------------------- | ---------- | ---------------------------------------------------------------- |
| After plan approval | Suggest    | Exploration context is stale; implementation needs only the plan |
| Between impl. loops | Automatic  | Each loop runs as separate Task invocation (natural boundary)    |
| After review        | Suggest    | Implementation context is stale; shipping needs only the result  |
| After ship          | Required   | Everything is stale; clean slate for next issue                  |

| Orchestrator Action | Reset Mode | Why                                                        |
| ------------------- | ---------- | ---------------------------------------------------------- |
| After each merge    | Suggest    | Agent diff context is stale; next merge is different files |
| After sync          | Suggest    | Mechanical rebase output is noise                          |

### Reset Modes

| Mode          | Behavior                                                              |
| ------------- | --------------------------------------------------------------------- |
| **Suggest**   | Suggest `/clear` with reason; continue if user declines               |
| **Automatic** | Sub-agent/Task boundary = natural context boundary (no action needed) |
| **Required**  | Write checkpoint, stop, require `/clear` + `/next-issue` to resume    |

### Reset Suggestion Template

When suggesting a reset, use this format:

> Exploration/planning phase complete. Context can be safely cleared — state
> saved to `.claude/memory/tmp/next-issue-{N}.json`. Run `/clear` then
> `/next-issue` to resume from {next_phase}.

If the user declines, continue normally — the suggestion is advisory.

______________________________________________________________________

## Status Labels

Four labels track in-flight work and prevent the same issue from being
picked up twice:

| Label                   | Set by                        | Meaning                                               |
| ----------------------- | ----------------------------- | ----------------------------------------------------- |
| `status/in-progress`    | `/next-issue` (Phase 1)       | An agent has selected this issue and is working on it |
| `status/pr-pending`     | `/next-issue-ship` (Option 1) | A PR has been created; awaiting review/merge          |
| `status/commit-pending` | `/next-issue-ship` (Option 3) | Fix committed locally but not yet pushed              |
| `status/on-hold`        | Manual                        | Issue intentionally deferred; not ready to work on    |

All four labels are **excluded** from all priority queries (see below) so
that in-progress issues are never re-selected.

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
      --search "-label:status/in-progress -label:status/pr-pending -label:status/commit-pending -label:status/on-hold" \
      --limit 1 \
      --json number,title,labels,body
  done
done
```

### GitLab (`glab`)

GitLab's `glab issue list` does not support negative label filters natively.
Fetch slightly more results and post-filter:

```bash
for severity in critical high medium low; do
  for effort in trivial small medium large; do
    # Fetch up to 5 and filter out status labels
    glab issue list \
      --label "severity/${severity}" \
      --label "effort/${effort}" \
      --not-assignee \
      --per-page 5 \
    | while read -r line; do
        # Skip issues with status/in-progress, status/pr-pending, status/commit-pending, or status/on-hold labels
        issue_num=$(echo "$line" | /usr/bin/awk '{print $1}')
        labels=$(glab issue view "$issue_num" --output json | /usr/bin/grep -o '"status/[^"]*"')
        if ! echo "$labels" | /usr/bin/grep -qE 'status/in-progress|status/pr-pending|status/commit-pending|status/on-hold'; then
          echo "$line"
          break
        fi
      done
  done
done
```

### Fallback

If no labeled issues match, fall back to the oldest open issue (still
excluding status labels):

```bash
# GitHub
gh issue list \
  --state open \
  --search "-label:status/in-progress -label:status/pr-pending -label:status/commit-pending -label:status/on-hold" \
  --limit 1 \
  --json number,title,labels,body

# GitLab — fetch more and post-filter as above
glab issue list --per-page 5
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
