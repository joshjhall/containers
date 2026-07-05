# Filing Issues

This guide explains how to file well-structured issues for the container
build system — what labels to apply, how the body should be organized, and
how `/next-issue` decides what to work on next. Following it lets both human
contributors and agentic workflows pick up your issue without further
clarification.

You do **not** need the `/file-issue` skill to file a good issue. This doc
covers the conventions that skill automates, so you can apply them by hand
from the GitHub web UI or the `gh` CLI. If you _do_ have the skill available,
see [Agent-assisted filing](#agent-assisted-filing) below.

## Why conventions matter

Issues in this repo feed an automated pipeline. The `/next-issue` workflow
queries open issues by label to decide what to work on, and `/next-issue-ship`
derives the branch name from the `type/*` label. An unlabeled or vaguely
worded issue cannot be prioritized automatically and will sit in the backlog
until someone triages it by hand. A correctly labeled issue with a parseable
body can be selected, planned, implemented, and shipped without a human ever
re-reading it.

## Required labels

Every issue should carry at least three labels: one `type/*`, one
`severity/*`, and one `effort/*`. A `component/*` label is strongly
recommended. The sections below describe each namespace; this taxonomy is the
same one the `/file-issue` skill applies, so issues filed by hand and by agent
stay consistent.

### Type (`type/`) — required, exactly one

The type determines the branch prefix when the issue is shipped, so pick
exactly one.

| Label             | Branch prefix | When to apply                         |
| ----------------- | ------------- | ------------------------------------- |
| `type/bug`        | `fix/`        | Something broken that worked before   |
| `type/feature`    | `feature/`    | New capability or enhancement         |
| `type/refactor`   | `refactor/`   | Restructuring without behavior change |
| `type/docs`       | `docs/`       | Documentation-only change             |
| `type/test`       | `test/`       | Test addition or fix                  |
| `type/chore`      | `chore/`      | Dependency updates, CI, maintenance   |
| `type/operations` | `chore/`      | Infrastructure, CI/CD, deployment     |
| `type/compliance` | `chore/`      | Regulatory or compliance requirement  |

If you are unsure, default to `type/chore`.

### Severity (`severity/`) — required, exactly one

Severity expresses impact, not urgency or effort. A one-line typo fix in a
security-critical path can be `severity/critical`.

| Label               | Meaning                                        |
| ------------------- | ---------------------------------------------- |
| `severity/critical` | Actively causing harm, data loss, or downtime  |
| `severity/high`     | Will cause problems under normal use           |
| `severity/medium`   | Increases maintenance burden or tech debt      |
| `severity/low`      | Best-practice improvement, no immediate impact |

If you are unsure, default to `severity/medium`.

### Effort (`effort/`) — required, exactly one

Effort estimates the size of the change. The heuristics below are based on the
file and directory count in your Affected Files section.

| Label            | Scope heuristic                              |
| ---------------- | -------------------------------------------- |
| `effort/trivial` | 1 file, under 30 minutes                     |
| `effort/small`   | 2-3 files in same directory, hours of work   |
| `effort/medium`  | 4-8 files or 2-3 directories, day of work    |
| `effort/large`   | 9+ files or 4+ directories, multi-day effort |

### Component (`component/`) — recommended

Component labels group issues by the area of the codebase they touch. Derive
the name from the top-level (or most meaningful) directory of the affected
files:

- `lib/features/python.sh` → `component/features`
- `docs/architecture/caching.md` → `component/docs`
- `tests/integration/builds/` → `component/tests`
- `crates/stibbons/src/...` → `component/stibbons`

Use lowercase with hyphens. Component labels are created on demand; the
canonical color is `1D76DB` (blue). To create one from the CLI:

```bash
# GitHub
gh label create "component/<name>" --color 1D76DB --force

# GitLab
glab label create "component/<name>" --color '#1D76DB'
```

### Labels you should not apply by hand

Some namespaces are owned by automation. Do not add them when filing:

- `status/*` (`in-progress`, `pr-pending`, `commit-pending`) — managed by
  `/next-issue` and `/next-issue-ship` to track in-flight work. The one
  exception is `status/on-hold`, which you may apply manually to defer an
  issue so the automated workflows skip it.
- `audit/*` and `certainty/*` — applied by `/codebase-audit` scanner agents.

## How `/next-issue` prioritizes

The `/next-issue` workflow selects the next issue with a nested loop:
**severity descending, then effort ascending**. It walks severity from
`critical` down to `low`, and within each severity level it prefers the
smallest effort first. The first open, unassigned issue it finds wins.

Concretely, the selection order is:

1. `severity/critical` + `effort/trivial`
2. `severity/critical` + `effort/small`
3. `severity/critical` + `effort/medium`
4. `severity/critical` + `effort/large`
5. `severity/high` + `effort/trivial`
6. … and so on through `severity/low` + `effort/large`

This means a critical bug is always picked before a high-severity one, but
among issues of equal severity the quick wins go first. Issues carrying any
`status/in-progress`, `status/pr-pending`, `status/commit-pending`, or
`status/on-hold` label are excluded from every query so the same issue is
never picked up twice. If no labeled issue matches, the workflow falls back to
the oldest open issue.

The practical takeaway: **label severity and effort honestly**. Inflating
severity to jump the queue distorts prioritization for everyone, and
under-labeling effort on a large change leads the workflow to under-plan it.

## Issue body format

Use H2 headers as section anchors. Agents parse these headers directly, so
keep the names exact. The base structure is:

```markdown
## Summary

{1-3 sentences: what needs to change and why}

## Problem

{Current behavior or gap. For bugs: what happens. For features: what's
missing. For refactors: what's wrong with the current structure.}

## Proposed Solution

{Expected approach. Be specific enough that an implementer can plan the work
without further clarification.}

## Acceptance Criteria

- [ ] {Concrete, testable criterion}
- [ ] {Each checkbox = one verifiable behavior or state}

## Affected Files

- `path/to/file1.ext` — {what changes}
- `path/to/directory/` — {scope of changes}

## Context

{Background: what prompted this, related discussions, constraints. Link
related issues with #N.}
```

A few sections are worth special care:

- **Summary** is always the first H2 — keep it tight; it is read for quick
  triage.
- **Acceptance Criteria** uses `- [ ]` checkboxes. Each box should be one
  verifiable outcome, because the implementer treats the full set as the
  definition of done.
- **Affected Files** uses backtick-wrapped paths. These drive the effort
  estimate and the `component/*` label, so list real paths.

### Type-specific sections

Insert one of these after **Proposed Solution** when it applies:

- **Bug** — add `## Steps to Reproduce` (numbered) and `## Expected Behavior`.
- **Feature** — add a `## User Story` in the form _As a {role}, I want
  {capability} so that {benefit}._
- **Refactor** — add `## Current State` and `## Target State`.

### Titles

Titles should be concise, specific, and action-oriented. Keep them under 70
characters and put the detail in the body.

| Good                                        | Bad              |
| ------------------------------------------- | ---------------- |
| Add pagination to `/api/users` endpoint     | API improvement  |
| Fix race condition in session token refresh | Fix bug          |
| Document issue filing conventions           | docs issue       |

## Worked examples

### Well-filed issue

> **Title:** Add `--json` flag to `check-versions.sh` for automation
>
> **Labels:** `type/feature`, `severity/low`, `effort/small`,
> `component/scripts`
>
> ```markdown
> ## Summary
>
> The weekly auto-patch workflow parses `check-versions.sh` text output with
> fragile regexes. A `--json` flag would let it consume structured data.
>
> ## Problem
>
> `check-versions.sh` prints a human-readable table only. Automation has to
> scrape columns, which breaks whenever the format changes.
>
> ## Proposed Solution
>
> Add a `--json` flag that emits one object per tool with `name`, `current`,
> and `latest` fields. Keep the table as the default output.
>
> ## Acceptance Criteria
>
> - [ ] `check-versions.sh --json` emits valid JSON to stdout
> - [ ] Default (no flag) output is unchanged
> - [ ] The auto-patch workflow consumes the JSON output
>
> ## Affected Files
>
> - `bin/check-versions.sh` — add `--json` flag and JSON emitter
>
> ## Context
>
> Supports the automated release pipeline (see
> `docs/operations/automated-releases.md`).
> ```

Why it works: exactly one label per required namespace, a component label, a
parseable body, and acceptance criteria that are each independently testable.

### Poorly-filed issue

> **Title:** versions broken
>
> **Labels:** _(none)_
>
> ```markdown
> the version script is annoying for automation, can we make it output
> json or something
> ```

Why it fails: no labels, so `/next-issue` can never select it; a vague title;
no Summary/Problem/Proposed Solution structure; and no acceptance criteria, so
nobody can tell when it is done.

## Filing from the GitLab web UI

On GitLab-hosted mirrors, the same conventions are wired into description
templates so a human filer gets them for free. When you open a new issue, pick a
template from the **Description** dropdown:

- **Bug Report** — applies `type/bug`
- **Feature Request** — applies `type/feature`
- **Refactor** — applies `type/refactor`

Each template pre-fills the H2 anchors above (plus the type-specific sections)
and ends with a `/label` quick action that sets the `type/*` label on submit. It
also carries a machine-readable **Triage** block:

```markdown
- Severity: medium   <!-- critical | high | medium | low -->
- Effort: small      <!-- trivial | small | medium | large -->
```

Edit those two values before submitting. A scheduled `gitlab-triage` job
(`.gitlab/triage/triage-policies.yml`, run by `.gitlab/ci/triage.yml`) parses the
block and applies the matching `severity/*` and `effort/*` labels. An issue that
leaves both unset instead gets a `needs-triage` label and a note asking for
them; once labeled, the flag clears automatically on the next run.

The automation depends on the labels already existing in the project. The
`severity/*`, `effort/*`, and `type/*` taxonomy is created by `stibbons labels
sync` (or by hand). The `needs-triage` label is GitLab-specific and not owned by
any skill, so create it by hand — matching the colour used by the GitHub
counterpart in `.github/workflows/issue-labeler.yml`:

```bash
glab label create "needs-triage" --color '#D4C5F9' \
  --description "Missing severity/effort labels"
```

See the header comment in `.gitlab/ci/triage.yml` for the full setup (the
`GITLAB_API_TOKEN` CI variable and the pipeline schedule). The templates live in
`.gitlab/issue_templates/`; this is the GitLab counterpart to the GitHub filing
path, and both apply the identical taxonomy described above.

## Agent-assisted filing

If you have the `/file-issue` skill available, you can describe the issue in
natural language and let it apply the conventions above automatically. The
skill:

- Auto-detects `effort/*` from the file count in Affected Files.
- Derives `component/*` from the affected paths and creates the label if it
  does not exist.
- Asks you to confirm `type/*` and `severity/*`.
- Formats the body with the H2 anchors that `/next-issue` expects.

Invoke it with `/file-issue` and follow the prompts. The skill is the
recommended path for agent-driven workflows because it guarantees the output
is consistent with everything described here. Filing by hand is perfectly
fine too — this doc is the manual version of the same rules.

## Related documentation

- [Development & Contribution Guide](README.md) — overview of contributor docs
- [Changelog Conventions](changelog.md) — commit message format that closes
  issues (`Closes #N`)
- [Git Workflow](../../CLAUDE.md) — branch naming and Conventional Commits
