# check-\* Migration Status

Tracks the migration from monolithic `audit-*` agents to modular `check-*`
skills with deterministic pre-scan (`patterns.sh`). The `check-*` architecture
decomposes each audit domain into focused, reusable detection units that follow
a 3-pass execution model (deterministic → heuristic → judgment).

## Overall Progress

**19 of 41 categories migrated** (46%) across 6 domains.

| Domain       | audit-\* Agent       | check-\* Skill(s)       | Categories | Status                    |
| ------------ | -------------------- | ----------------------- | ---------- | ------------------------- |
| docs         | `audit-docs`         | 5 `check-docs-*` skills | 10/4       | Fully migrated (expanded) |
| security     | `audit-security`     | `check-security`        | 4/8        | Partial                   |
| code-health  | `audit-code-health`  | `check-code-health`     | 3/9        | Partial                   |
| ai-config    | `audit-ai-config`    | `check-ai-config`       | 5/8        | Partial                   |
| test-gaps    | `audit-test-gaps`    | —                       | 0/5        | Not started               |
| architecture | `audit-architecture` | —                       | 0/7        | Not started               |

*Format: check-* categories / audit-\* categories\*

## Per-Domain Gap Analysis

### docs — Fully Migrated

The 5 `check-docs-*` skills cover all 4 original `audit-docs` categories and
add 6 new ones. This domain is the migration reference implementation.

| audit-docs Category  | check-\* Equivalent                                                 | Skill                     |
| -------------------- | ------------------------------------------------------------------- | ------------------------- |
| `stale-comment`      | `stale-comment`, `expired-date`, `outdated-reference`               | `check-docs-staleness`    |
| `missing-api-docs`   | `undocumented-public-api`, `undocumented-complex-function`          | `check-docs-missing-api`  |
| `outdated-readme`    | `missing-root-doc`, `missing-dir-readme`                            | `check-docs-organization` |
| `misleading-example` | `broken-example`, `deprecated-example`, `incomplete-example`        | `check-docs-examples`     |
| — (new)              | `broken-relative-link`, `broken-anchor`, `suspicious-external-link` | `check-docs-deadlinks`    |

**Note**: `check-docs-deadlinks` has a known regex bug affecting
`broken-relative-link` and `broken-anchor` categories (see #341).

### security — Partial (4/8)

| audit-security Category | check-security Category | Status   |
| ----------------------- | ----------------------- | -------- |
| `hardcoded-secret`      | `hardcoded-secret`      | Migrated |
| `injection`             | `injection-risk`        | Migrated |
| `xss`                   | `xss-risk`              | Migrated |
| `insecure-crypto`       | `insecure-crypto`       | Migrated |
| `auth-bypass`           | —                       | Missing  |
| `data-exposure`         | —                       | Missing  |
| `missing-validation`    | —                       | Missing  |
| `dependency-cve`        | —                       | Missing  |

`auth-bypass` and `data-exposure` are primarily LLM-judgment categories (hard
to detect with regex). `missing-validation` has some deterministic patterns
(unvalidated function parameters at boundaries). `dependency-cve` may be
better handled by external tooling (Dependabot, Snyk) than patterns.sh.

### code-health — Partial (3/9)

| audit-code-health Category | check-code-health Category | Status                            |
| -------------------------- | -------------------------- | --------------------------------- |
| `tech-debt-marker`         | `tech-debt-marker`         | Migrated                          |
| `debug-statement`          | `debug-statement`          | Migrated                          |
| `unused-import`            | `empty-handler`            | Migrated (renamed)                |
| `file-length`              | —                          | Missing (deterministic)           |
| `function-complexity`      | —                          | Missing (deterministic)           |
| `code-duplication`         | —                          | Missing (partially deterministic) |
| `naming-drift`             | —                          | Missing (LLM-only)                |
| `magic-numbers`            | —                          | Missing (deterministic)           |
| `dead-code`                | —                          | Missing (LLM-only)                |
| `deprecated-api`           | —                          | Missing (LLM-only)                |

`file-length`, `function-complexity`, and `magic-numbers` are good candidates
for patterns.sh (line counting, nesting depth, numeric literal detection).
`naming-drift`, `dead-code`, and `deprecated-api` require LLM judgment.

**Note**: `loop-make-it-right` already has `long-function` and `deep-nesting`
categories that overlap with `file-length` and `function-complexity`. Consider
reusing or cross-referencing rather than duplicating.

### ai-config — Partial (5/8)

| audit-ai-config Category | check-ai-config Category | Status            |
| ------------------------ | ------------------------ | ----------------- |
| `agent-quality`          | `agent-frontmatter`      | Migrated (subset) |
| `skill-quality`          | `skill-frontmatter`      | Migrated (subset) |
| `ai-file-bloat`          | `ai-file-bloat`          | Migrated          |
| `mcp-misconfiguration`   | `mcp-misconfiguration`   | Migrated          |
| `hook-safety`            | `hook-safety`            | Migrated          |
| `claude-md-drift`        | —                        | Missing           |
| `config-inconsistency`   | —                        | Missing           |
| `doc-file-bloat`         | —                        | Missing           |

`claude-md-drift` (references to non-existent files) has good deterministic
potential. `config-inconsistency` (cross-reference validation) is partially
deterministic. `doc-file-bloat` is a straightforward line-count check similar
to `ai-file-bloat`.

### test-gaps — Not Started (0/5)

| audit-test-gaps Category  | Status  |
| ------------------------- | ------- |
| `untested-public-api`     | Missing |
| `missing-error-path-test` | Missing |
| `missing-edge-case`       | Missing |
| `low-assertion-density`   | Missing |
| `test-quality`            | Missing |

**Note**: `loop-make-it-tested` already covers `missing-test-file` and
`untested-public-api` categories. `pre-review-gates.sh` also has
`missing-test-file` and `untested-public-api`. A new `check-test-gaps` skill
should reuse or extend these existing patterns rather than duplicating them.

### architecture — Not Started (0/7)

| audit-architecture Category | Status  |
| --------------------------- | ------- |
| `circular-dependency`       | Missing |
| `high-coupling`             | Missing |
| `layer-violation`           | Missing |
| `bus-factor`                | Missing |
| `inconsistent-pattern`      | Missing |
| `god-module`                | Missing |
| `orphaned-file`             | Missing |

Most architecture categories require cross-file analysis (import graph,
contributor history) that is difficult to implement in a single-file
patterns.sh scanner. `god-module` (high line count + high fan-in) and
`orphaned-file` (not imported by anything) have partial deterministic
potential.

## Completion Criteria

A domain is considered fully migrated when:

1. Every deterministic-scannable category from the audit-\* agent has a
   corresponding category in the check-\* patterns.sh
1. The check-\* SKILL.md covers LLM-only categories in its heuristic pass
1. The contract.md declares all categories with examples

## Deprecation Plan

audit-\* agents are deprecated per-domain when the corresponding check-\* skill
reaches full coverage:

| Phase          | Action                                                               | Trigger                               |
| -------------- | -------------------------------------------------------------------- | ------------------------------------- |
| **Active**     | Both audit-\* and check-\* available; checker agent prefers check-\* | Current state                         |
| **Deprecated** | audit-\* agent moved to `deprecated/` directory; warning added       | Domain reaches 100% check-\* coverage |
| **Removed**    | audit-\* agent deleted                                               | One major version after deprecation   |

**No fixed timeline** — deprecation is tied to coverage milestones, not dates.
The docs domain is ready for Phase 2 (deprecation) now.

## Related Issues

### Sub-issues (remaining migrations)

- #342 — Create `check-test-gaps` skill (5 categories)
- #343 — Create `check-architecture` skill (7 categories)
- #344 — Expand `check-security` (4 missing categories)
- #345 — Expand `check-code-health` (6 missing categories)
- #346 — Expand `check-ai-config` (3 missing categories)

### Other

- Issue 341 — check-docs-deadlinks ERE regex bug (broken-relative-link,
  broken-anchor)
- Issue 340 — Multi-language/multi-runtime skill tools review
