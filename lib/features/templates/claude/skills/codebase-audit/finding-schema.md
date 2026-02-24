# Finding Schema — JSON Contract

Reference companion for `SKILL.md`. All scanner agents must return findings in
this exact JSON structure inside a \`\`\`json markdown fence.

______________________________________________________________________

## Complete Schema

```json
{
  "scanner": "<scanner-name>",
  "summary": {
    "files_scanned": 0,
    "total_findings": 0,
    "by_severity": {"critical": 0, "high": 0, "medium": 0, "low": 0}
  },
  "findings": [
    {
      "id": "<scanner>-<NNN>",
      "category": "<category-slug>",
      "severity": "critical | high | medium | low",
      "title": "Short description of the finding",
      "description": "Detailed explanation with context",
      "file": "path/to/file.ext",
      "line_start": 1,
      "line_end": 50,
      "evidence": "Concrete measurement or observation",
      "suggestion": "Actionable recommendation to resolve",
      "effort": "trivial | small | medium | large",
      "tags": ["maintainability"],
      "related_files": ["path/to/related.ext"]
    }
  ]
}
```

______________________________________________________________________

## Field Reference

### Top-Level Fields

| Field      | Type   | Required | Description                        |
| ---------- | ------ | -------- | ---------------------------------- |
| `scanner`  | string | yes      | Scanner name (e.g., `code-health`) |
| `summary`  | object | yes      | Aggregate counts for the scan      |
| `findings` | array  | yes      | List of individual finding objects |

### Summary Fields

| Field            | Type   | Required | Description                          |
| ---------------- | ------ | -------- | ------------------------------------ |
| `files_scanned`  | number | yes      | Total files the scanner examined     |
| `total_findings` | number | yes      | Total findings across all severities |
| `by_severity`    | object | yes      | Count per severity level             |

### Finding Fields

| Field           | Type     | Required | Description                                                         |
| --------------- | -------- | -------- | ------------------------------------------------------------------- |
| `id`            | string   | yes      | Unique ID: `<scanner>-<NNN>` (zero-padded, e.g., `code-health-001`) |
| `category`      | string   | yes      | Category slug from the scanner's defined set                        |
| `severity`      | string   | yes      | One of: `critical`, `high`, `medium`, `low`                         |
| `title`         | string   | yes      | One-line summary (under 80 chars)                                   |
| `description`   | string   | yes      | Full explanation with context                                       |
| `file`          | string   | yes      | Relative path from project root                                     |
| `line_start`    | number   | yes      | Starting line number (1-based)                                      |
| `line_end`      | number   | yes      | Ending line number (same as start for single-line)                  |
| `evidence`      | string   | yes      | Concrete data supporting the finding                                |
| `suggestion`    | string   | yes      | Actionable fix recommendation                                       |
| `effort`        | string   | yes      | One of: `trivial`, `small`, `medium`, `large`                       |
| `tags`          | string[] | yes      | Relevant tags (e.g., `maintainability`, `security`)                 |
| `related_files` | string[] | yes      | Other files involved (empty array if none)                          |

______________________________________________________________________

## Severity Rubric

| Level      | Meaning                                        |
| ---------- | ---------------------------------------------- |
| `critical` | Actively causing harm or exploitable now       |
| `high`     | Will cause problems under normal use           |
| `medium`   | Increases maintenance burden or technical debt |
| `low`      | Best-practice improvement, no immediate impact |

## Effort Rubric

| Level     | Scope                            |
| --------- | -------------------------------- |
| `trivial` | Under 30 minutes, single file    |
| `small`   | Hours of work, few files         |
| `medium`  | Day of work, multiple files      |
| `large`   | Multi-day, cross-cutting changes |

______________________________________________________________________

## Scanner Categories

Each scanner defines its own category slugs. The orchestrator uses these for
grouping and deduplication.

### code-health

`file-length`, `function-complexity`, `code-duplication`, `naming-drift`,
`magic-numbers`, `dead-code`, `unused-import`, `tech-debt-marker`,
`deprecated-api`

### security

`injection`, `auth-bypass`, `data-exposure`, `hardcoded-secret`,
`insecure-crypto`, `missing-validation`, `dependency-cve`, `xss`

### test-gaps

`untested-public-api`, `missing-error-path-test`, `missing-edge-case`,
`low-assertion-density`, `test-quality`

### architecture

`circular-dependency`, `high-coupling`, `layer-violation`, `bus-factor`,
`inconsistent-pattern`, `god-module`, `orphaned-file`

### docs

`stale-comment`, `missing-api-docs`, `outdated-readme`, `misleading-example`

______________________________________________________________________

## Validation Rules

Scanners must ensure:

- `id` values are unique within the scanner's output
- `id` format is `<scanner>-<NNN>` with zero-padded numbers
- `category` matches one of the scanner's defined categories
- `severity` and `effort` use only the defined enum values
- `file` paths are relative to the project root (no leading `/`)
- `line_start` \<= `line_end`
- `tags` and `related_files` are arrays (empty `[]` if none)
- JSON is valid and parseable
- Output is wrapped in a \`\`\`json markdown fence
