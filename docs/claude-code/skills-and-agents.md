# Skills & Agents

Detailed reference for pre-installed Claude Code skills and agents. For a quick
overview, see [CLAUDE.md](../../CLAUDE.md#claude-code-integrations).

## Pre-installed Skills & Agents

When `INCLUDE_DEV_TOOLS=true`, Claude Code skills and agents are automatically
installed to `~/.claude/skills/` and `~/.claude/agents/` on first container
startup via `claude-setup`. Project-level `.claude/` configs merge with these
(union semantics, project wins on name conflicts).

### Skills (always installed — 20 static + 1 dynamic)

| Skill                     | Purpose                                                                             |
| ------------------------- | ----------------------------------------------------------------------------------- |
| `container-environment`   | Dynamic - describes installed tools, cache paths, container patterns                |
| `git-workflow`            | Git commit conventions, branch naming, PR workflow                                  |
| `testing-patterns`        | Test-first development, test framework patterns                                     |
| `code-quality`            | Linting, formatting, code review checklist                                          |
| `development-workflow`    | Phased feature development, task decomposition, scope control                       |
| `error-handling`          | Error hierarchy, validation, retry strategies, resilience patterns                  |
| `documentation-authoring` | Progressive documentation, writing standards, organization patterns                 |
| `shell-scripting`         | Shell naming conventions, namespace safety, testing, error handling                 |
| `skill-authoring`         | Skill/instruction writing, quality criteria, cross-tool patterns                    |
| `agent-authoring`         | Agent/subagent design, tool scoping, model selection, prompt design                 |
| `file-issue`              | Structured issue creation with auto-labeling, scope enforcement, update mode        |
| `next-issue`              | Issue-driven dev: select by priority, plan; delegates shipping to `next-issue-ship` |
| `codebase-audit`          | Periodic codebase sweep: tech debt, security, test gaps, architecture, docs         |
| `next-issue-ship`         | Ship completed issue work: commit, PR/push, label issue, loop back                  |
| `memory-conventions`      | Two-tier memory conventions: long-term (committed) vs short-term (gitignored)       |
| `orchestrate`             | Multi-agent orchestration: status, merge, review, and sync agent commits            |
| `check-docs-staleness`    | Detects stale comments, outdated references, expired dates in docs                  |
| `check-docs-deadlinks`    | Validates internal and external links in documentation                              |
| `check-docs-organization` | Checks doc structure, missing READMEs, file consistency                             |
| `check-docs-examples`     | Validates code examples against actual source code                                  |
| `check-docs-missing-api`  | Detects undocumented public APIs and functions across languages                     |

### Conditional Skills

| Skill                  | Condition                                                                                                         |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `docker-development`   | `INCLUDE_DOCKER=true`                                                                                             |
| `cloud-infrastructure` | Any cloud flag (`INCLUDE_KUBERNETES`, `INCLUDE_TERRAFORM`, `INCLUDE_AWS`, `INCLUDE_GCLOUD`, `INCLUDE_CLOUDFLARE`) |

### Agents (always installed)

| Agent                | Purpose                                                                     |
| -------------------- | --------------------------------------------------------------------------- |
| `code-reviewer`      | Reviews code for bugs, security, performance, style                         |
| `test-writer`        | Generates tests for existing code, detects framework                        |
| `refactorer`         | Refactors code while preserving behavior                                    |
| `debugger`           | Systematic debugging for errors, test failures, runtime issues              |
| `audit-code-health`  | Scans for file length, complexity, duplication, dead code                   |
| `audit-security`     | Scans for OWASP patterns, secrets, crypto, validation issues                |
| `audit-test-gaps`    | Identifies untested APIs, missing error/edge tests                          |
| `audit-architecture` | Detects circular deps, coupling, bus-factor, layer violations               |
| `audit-docs`         | Finds stale comments, missing API docs, outdated READMEs                    |
| `audit-ai-config`    | Checks skills, agents, CLAUDE.md, MCP configs, hooks quality                |
| `issue-writer`       | Creates GitHub/GitLab issues from grouped audit findings                    |
| `issue-filer`        | Creates structured issues with auto-labeling from user requests             |
| `skill-author`       | Writes and reviews skills following quality patterns (opus)                 |
| `agent-author`       | Writes and reviews agents following quality patterns (opus)                 |
| `checker`            | Unified checker for audit/review: discovers check-\* skills, pre-scan + LLM |

The `skill-author` and `agent-author` agents use `model: opus` because
authoring quality compounds — a poorly-written skill or agent degrades all
downstream interactions across every conversation that loads it.

Templates are staged at build time to `/etc/container/config/claude-templates/`
and installed at runtime by `claude-setup`. All installations are idempotent.

### Skill Metadata (metadata.yml)

Each skill directory includes a `metadata.yml` file that provides
machine-readable metadata for tooling (label sync, CI, documentation
generators). This file is informational — it does not change skill behavior at
runtime.

**Schema:**

```yaml
name: my-skill          # Skill name (matches directory name)
version: "1.0"          # Schema version

labels:                 # Labels the skill creates/requires on issues
  - name: status/in-progress
    color: "0E8A16"
    description: An agent is working on this issue

required_tools:         # CLI tools the skill invokes
  - name: gh
    purpose: GitHub issue listing, labeling, PR creation
    install_hint: "Included with INCLUDE_DEV_TOOLS=true"

required_permissions:   # Auth scopes needed
  - provider: github
    scopes: [repo]
    notes: "gh auth login with 'repo' scope minimum"

required_mcps: []       # MCP servers the skill uses
```

Skills without labels, tools, or permissions use empty arrays. See the
`skill-authoring` skill for authoring guidelines.

### Overriding Skills

Use `CLAUDE_SKILLS` to replace the default skill set:

```bash
# Install only specific skills
docker build --build-arg CLAUDE_SKILLS="git-workflow,code-quality" ...

# No static skills (container-environment is always installed)
docker build --build-arg CLAUDE_SKILLS="" ...

# At runtime (overrides build-time value)
docker run -e CLAUDE_SKILLS="git-workflow,testing-patterns" ...
```

| `CLAUDE_SKILLS` | Behavior                                        |
| --------------- | ----------------------------------------------- |
| Unset (default) | All 20 static skills installed                  |
| Set to list     | Only listed skills installed                    |
| Set to `""`     | No static skills (only `container-environment`) |

- `container-environment` always installs (dynamically generated)
- Conditional skills (`docker-development`, `cloud-infrastructure`) require
  both the feature flag AND presence in `CLAUDE_SKILLS` (or `CLAUDE_SKILLS` unset)

### Extra Skills

Use `CLAUDE_EXTRA_SKILLS` to add skills on top of the default or overridden set:

```bash
# In your personal .env file
CLAUDE_EXTRA_SKILLS=my-custom-skill

# Or at build time
docker build --build-arg CLAUDE_EXTRA_SKILLS="my-custom-skill" ...
```

Skills must exist in the templates directory (`/etc/container/config/claude-templates/skills/`).

### Overriding Agents

Use `CLAUDE_AGENTS` to replace the default agent set:

```bash
# Install only specific agents
docker build --build-arg CLAUDE_AGENTS="debugger,code-reviewer" ...

# No agents
docker build --build-arg CLAUDE_AGENTS="" ...

# At runtime (overrides build-time value)
docker run -e CLAUDE_AGENTS="debugger,test-writer" ...
```

| `CLAUDE_AGENTS` | Behavior                     |
| --------------- | ---------------------------- |
| Unset (default) | All 15 agents installed      |
| Set to list     | Only listed agents installed |
| Set to `""`     | No agents installed          |

### Extra Agents

Use `CLAUDE_EXTRA_AGENTS` to add agents on top of the default or overridden set:

```bash
# In your personal .env file
CLAUDE_EXTRA_AGENTS=my-custom-agent

# Or at build time
docker build --build-arg CLAUDE_EXTRA_AGENTS="my-custom-agent" ...
```

Agents must exist in the templates directory (`/etc/container/config/claude-templates/agents/`).

To verify: `ls ~/.claude/skills/` and `ls ~/.claude/agents/`

## Codebase Audit System

The `codebase-audit` skill provides a periodic codebase sweep that identifies
tech debt, security issues, test gaps, architecture problems, and documentation
staleness. It dispatches 6 scanner agents in parallel. Each scanner automatically
fans out to batch sub-agents (model: haiku) when the manifest exceeds 2000
source lines, preventing context exhaustion on large codebases. After
cross-scanner deduplication, the orchestrator spawns `issue-writer` sub-agents
to create GitHub/GitLab issues in parallel.

**Invoke**: `/codebase-audit` (or describe "run a codebase audit")

### Parameters

| Parameter            | Default     | Description                           |
| -------------------- | ----------- | ------------------------------------- |
| `scope`              | entire repo | Directory or glob to limit the scan   |
| `categories`         | all six     | Scanner names to run                  |
| `depth`              | `standard`  | `quick`, `standard`, or `deep`        |
| `severity-threshold` | `medium`    | Minimum severity to report            |
| `dry-run`            | `false`     | Output report without creating issues |

### Scanners (dispatched in parallel via Task tool)

| Scanner              | Categories                                                                       |
| -------------------- | -------------------------------------------------------------------------------- |
| `audit-code-health`  | File length, complexity, duplication, dead code, naming                          |
| `audit-security`     | OWASP patterns, secrets, crypto, validation, CVEs (skips untracked `.env` files) |
| `audit-test-gaps`    | Untested APIs, error path tests, edge cases, assertions                          |
| `audit-architecture` | Circular deps, coupling, bus factor, layer violations                            |
| `audit-docs`         | Stale comments, missing API docs, outdated READMEs                               |
| `audit-ai-config`    | Skill/agent quality, CLAUDE.md drift, MCP misconfig, hook safety, file bloat     |

### Depth Modes

- `quick` — scans files changed in the last 50 commits
- `standard` — scans all source files
- `deep` — adds full git history analysis for contributor stats and churn data

### Output

In dry-run mode, produces a summary table, prioritized findings list, and
acknowledged findings table. Otherwise, creates grouped GitHub/GitLab issues
with labels (`audit/{category}`, `severity/{level}`, `effort/{size}`).

### Inline Suppression

Add `audit:acknowledge category=<slug>` comments in source files to suppress
known findings from being re-raised. Supports optional `date=YYYY-MM-DD`,
`baseline=<number>` (for numeric thresholds), and `reason="..."` fields.
Acknowledgments older than 12 months auto-expire.

### Skill Files

- `skills/codebase-audit/SKILL.md` — orchestration protocol
- `skills/codebase-audit/finding-schema.md` — JSON contract for scanner output
- `skills/codebase-audit/issue-templates.md` — issue grouping and creation rules

## Unified check-\* Skill Architecture

The check-\* skills are a new architecture that decomposes monolithic audit
agents into focused, reusable detection units. Each skill combines deterministic
pre-scan (regex/scripts) with LLM judgment, and works in both audit
(scope=codebase) and review (scope=diff) modes via the unified `checker` agent.

### Skill Structure

Each check-\* skill has 5 files:

| File             | Purpose                                               |
| ---------------- | ----------------------------------------------------- |
| `SKILL.md`       | LLM instructions for judgment calls                   |
| `patterns.sh`    | Deterministic pre-scan (regex/scripts, runs first)    |
| `thresholds.yml` | Configurable thresholds and severity mappings         |
| `contract.md`    | Versioned output format (subset of finding-schema.md) |
| `metadata.yml`   | Standard skill metadata                               |

### 3-Pass Execution Model

The `checker` agent runs analysis in three composable passes:

1. **Pass 1 (Deterministic)**: Run each skill's `patterns.sh` — produces
   findings with certainty `HIGH` and method `deterministic`
1. **Pass 2 (Heuristic)**: Pass pre-scan results + file context to skill's
   `SKILL.md` — LLM confirms/dismisses/adds findings with certainty `MEDIUM`
1. **Pass 3 (Judgment)**: Deeper LLM analysis for ambiguous cases — produces
   findings with certainty `LOW`

Each pass feeds the next. Deterministic hits are validated by heuristic
analysis, and ambiguous cases get deeper judgment.

### Multi-Signal Certainty

Findings carry a `certainty` object:

```json
{
  "level": "HIGH",
  "support": 2,
  "confidence": 0.95,
  "method": "deterministic"
}
```

- `level`: HIGH (regex match), MEDIUM (heuristic + LLM), LOW (LLM only)
- `support`: number of evidence signals corroborating the finding
- `confidence`: 0.0-1.0 reliability score
- `method`: detection method used

### Audit Trail

Every checker run records execution metadata:

```json
{
  "check_run": {
    "scope": "codebase",
    "skills_executed": ["check-docs-staleness", "check-docs-deadlinks"],
    "pass_stats": {
      "deterministic_hits": 42,
      "deterministic_confirmed": 15,
      "heuristic_findings": 8,
      "judgment_findings": 2
    }
  }
}
```

### Versioned Skill Interfaces

Each skill's `contract.md` includes a version field with backward-compatibility
guarantees, enabling skills to evolve independently without breaking the
checker agent.

### Project-Level Extensibility

Projects can add custom check-\* skills at `.claude/skills/check-*/`:

```text
.claude/skills/check-api-design/
    SKILL.md
    patterns.sh
    thresholds.yml
    contract.md
    metadata.yml
```

Both the auditor and reviewer discover project-level skills automatically.

### Current check-docs-\* Skills

| Skill                     | Categories                                                                            |
| ------------------------- | ------------------------------------------------------------------------------------- |
| `check-docs-staleness`    | `stale-comment`, `outdated-reference`, `expired-date`                                 |
| `check-docs-deadlinks`    | `broken-relative-link`, `broken-anchor`, `suspicious-external-link`                   |
| `check-docs-organization` | `missing-root-doc`, `missing-dir-readme`, `inconsistent-structure`, `doc-duplication` |
| `check-docs-examples`     | `broken-example`, `deprecated-example`, `incomplete-example`                          |
| `check-docs-missing-api`  | `undocumented-public-api`, `undocumented-complex-function`                            |

### Migration from audit-\* Agents

The check-\* architecture incrementally replaces audit-\* agents. During
migration, the checker agent discovers both old `audit-*` agents and new
`check-*` skills. When a check-\* skill exists for a domain, it takes
precedence over the corresponding audit-\* agent. Currently only the docs
domain has been migrated; remaining domains (security, code-health, test-gaps,
architecture, ai-config) will follow.
