---
description: Periodic codebase sweep that identifies tech debt, security issues, test gaps, architecture problems, and documentation staleness. Creates actionable GitHub/GitLab issues grouped by category. Invoke with /codebase-audit.
---

# Codebase Audit

**Companion files**: See `finding-schema.md` for the JSON contract all scanners
follow. See `issue-templates.md` for issue grouping rules and platform commands.
Load both when running an audit.

## Parameters

Accept these from the user's invocation (all optional):

| Parameter            | Default     | Description                                                       |
| -------------------- | ----------- | ----------------------------------------------------------------- |
| `scope`              | entire repo | Directory or glob pattern to limit the scan                       |
| `categories`         | all five    | Scanner names to run (comma-separated)                            |
| `depth`              | `standard`  | `quick`: last 50 commits; `standard`: full; `deep`: + git history |
| `severity-threshold` | `medium`    | Minimum severity to report                                        |
| `dry-run`            | `false`     | Output findings report without creating issues                    |

## Orchestration Protocol

Follow these steps in order. Do not skip steps.

### Step 1: Map the Codebase

1. Run `Glob("**/*")` to get the full file tree within `scope`
1. Run `wc -l` via Bash on source files to get line counts
1. Classify files into categories by extension and path:

| Classification | Extensions / Patterns                                                               |
| -------------- | ----------------------------------------------------------------------------------- |
| Source         | `.py`, `.js`, `.ts`, `.go`, `.rs`, `.rb`, `.java`, `.kt`, `.sh`, `.c`, `.cpp`, `.h` |
| Test           | `test_*`, `*_test.*`, `*.test.*`, `*.spec.*`, `tests/`, `spec/`, `__tests__/`       |
| Config         | `.json`, `.yaml`, `.yml`, `.toml`, `.ini`, `.env*`, `Makefile`, `Dockerfile`        |
| Doc            | `.md`, `.rst`, `.txt`, `README*`, `CHANGELOG*`, `docs/`                             |

4. Filter untracked `.env*` files out of scanner manifests. Run
   `git ls-files --error-unmatch <file>` for each `.env*` match — if the file
   is not tracked by git, exclude it from all scanner file lists (untracked
   env files are local-only and not a repository risk)
1. Detect language(s) from config files (`package.json`, `pyproject.toml`,
   `Cargo.toml`, `go.mod`, `Gemfile`, `build.gradle`, etc.)
1. Detect platform (GitHub or GitLab) from `git remote -v`
1. For `quick` depth: run `git log --oneline -50 --name-only` to limit to
   recently changed files. For `deep` depth: run `git log --format='%aN' --name-only` for contributor stats per file

### Step 2: Build Work Manifest

Batch files by line count targeting ~2000 lines per batch. Route files to
scanners based on classification:

| File Type               | Routed To                           |
| ----------------------- | ----------------------------------- |
| Source files            | code-health, security, architecture |
| Test files              | test-gaps only                      |
| Config files            | security only                       |
| Doc files               | docs only                           |
| Source + paired test    | test-gaps (paired)                  |
| High-churn files (deep) | all scanners                        |

Build a manifest object for each scanner:

```json
{
  "scanner": "<name>",
  "files": ["path/to/file1.py", "path/to/file2.py"],
  "thresholds": {
    "file_length_warning": 300,
    "file_length_high": 500,
    "complexity_warning": 10,
    "complexity_high": 20,
    "duplication_warning": 10,
    "duplication_high": 20
  },
  "context": {
    "languages": ["python"],
    "framework": "django",
    "project_name": "myproject"
  }
}
```

For `test-gaps`, include `source_files`, `test_files`, and `test_patterns`
fields instead of a flat `files` list.

For `architecture`, include `file_tree` and `git_stats` (if available from
deep mode) in addition to `files`.

### Step 3: Dispatch Scanners in Parallel

Send **a single message** with up to 5 `Task` tool calls (one per scanner).
Each task prompt must include:

1. The scanner's manifest (from Step 2)
1. The full finding schema (from `finding-schema.md`)
1. The severity threshold

Use these agent names:

- `audit-code-health` — code health scanner
- `audit-security` — security scanner
- `audit-test-gaps` — test gaps scanner
- `audit-architecture` — architecture scanner
- `audit-docs` — documentation scanner

All scanners use `model: sonnet` and `tools: Read, Grep, Glob, Bash`.

Skip scanners not in the `categories` parameter.

### Step 4: Aggregate and Deduplicate

After all scanners return:

1. **Parse JSON** from each scanner's response (extract from \`\`\`json fences)
1. **Within-scanner dedup**: Same file + category + overlapping line ranges →
   merge into one finding (keep broader range, combine evidence)
1. **Cross-scanner correlation** (see `issue-templates.md` for rules):
   - Dead code (code-health) + orphaned file (architecture) → merge
   - Security issue + test gap on same file → bump severity of the group
   - Stale comment (docs) + deprecated API (code-health) → merge
1. **Filter**: Remove findings below `severity-threshold`
1. **Sort**: By severity (critical first), then by effort (trivial first —
   quick wins surface to the top)
1. **Assign sequential IDs** across the merged set for the final report

### Step 5: Create Issues (or Dry-Run Report)

**If `dry-run` is true**: Output the summary table and findings list as
described in `issue-templates.md` (Dry-Run Output Format section). Stop here.

**If `dry-run` is false**:

1. **Group findings** into issues following the rules in `issue-templates.md`:
   - Same file + same category → one issue
   - Same pattern across files → one issue (max 10 findings per issue)
   - Cross-scanner correlations → single merged issue
1. **Search for existing issues** to avoid duplicates:
   - GitHub: `gh issue list --state open --label "audit/{category}"`
   - GitLab: `glab issue list --opened --label "audit/{category}"`
1. **Create issues** using platform commands from `issue-templates.md`
1. **Output summary**: List of created issues with URLs

## When to Use

- Quarterly codebase health reviews
- Before major refactoring efforts (understand what needs attention)
- After onboarding to an unfamiliar codebase
- When preparing for a security audit
- When tech debt feels high but isn't quantified

## When NOT to Use

- For real-time CI/CD checks (too slow, use linters instead)
- On generated or vendored code
- On codebases under active rewrite (findings will be obsolete)

## Depth Modes

| Mode       | Files Scanned                        | Git History    | Best For            |
| ---------- | ------------------------------------ | -------------- | ------------------- |
| `quick`    | Changed in last 50 commits           | Recent commits | Regular check-ins   |
| `standard` | All source files in scope            | None           | Quarterly reviews   |
| `deep`     | All source files + contributor stats | Full history   | Comprehensive audit |

## Error Handling

- If a scanner returns invalid JSON: log the error, skip that scanner's
  findings, note in the final report
- If a scanner returns zero findings: include it in the summary with zero
  counts (this is normal, not an error)
- If `gh`/`glab` is not available and `dry-run` is false: fall back to
  dry-run mode and inform the user
- If no source files match the scope: report early with a clear message
