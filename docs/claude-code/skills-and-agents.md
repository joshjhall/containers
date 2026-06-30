# Skills & Agents

Detailed reference for the Claude Code skills and agents available in the
container. For a quick overview, see
[CLAUDE.md](../../CLAUDE.md#claude-code-integrations).

## Source of Truth: the `librarian` marketplace

The general-purpose skills and agents are **not** bundled by this repo. They
live in the sibling repository
[`joshjhall/librarian`](https://github.com/joshjhall/librarian), shipped as a
[Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins)
so the same artifacts install identically on a host Mac, a bare Linux box, and
inside this container — with `claude plugin update` semver rolling updates for
free.

These artifacts previously lived in this repo and were baked into every image
via a content-stamp re-sync pipeline (#574). They were extracted into
`librarian` so they are no longer container-build-bound; the migration is
tracked in [epic #607](https://github.com/joshjhall/containers/issues/607).
`librarian` is the source of truth for everything it ships — consult its
per-plugin READMEs for the authoritative, versioned component lists rather than
re-enumerating them here (that duplication is exactly what went stale).

### Librarian plugins

| Plugin                                                                                  | Components           | What's inside                                                                                                                       |
| --------------------------------------------------------------------------------------- | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| [`dev-core`](https://github.com/joshjhall/librarian/tree/main/plugins/dev-core)         | 20 skills · 6 agents | General development + authoring: code review, debugging, refactoring, testing, git/error/doc workflow, and the authoring guides     |
| [`review-audit`](https://github.com/joshjhall/librarian/tree/main/plugins/review-audit) | 9 skills · 8 agents  | The `codebase-audit` / `check-*` / `audit-*` suite plus the issue writer                                                            |
| [`workflow`](https://github.com/joshjhall/librarian/tree/main/plugins/workflow)         | 9 skills · 3 agents  | Issue-driven + parallel automation: `next-issue`(+`-ship`), `orchestrate`, golem, `file-issue`, `provision-agent`, bundled scripts  |

The conceptual architecture for these artifacts — the [codebase audit
system](#codebase-audit-system), the [check-\* skills](#unified-check--skill-architecture),
the [loop-\* implementation skills](#implementation-loops-loop--skills),
[contexts](#contexts-context--skills), and the [pipeline / safety
model](#pipeline-state--context-resets) — is documented in the sections below.
That behavior is identical wherever the plugins are installed.

### Component index (where each artifact moved)

A migration aid for finding where a skill or agent that used to live here now
ships. The `librarian` per-plugin READMEs carry the authoritative descriptions
and versions — this index is just the name → plugin map.

**`dev-core`** — skills: `git-workflow`, `testing-patterns`, `code-quality`,
`development-workflow`, `error-handling`, `documentation-authoring`,
`shell-scripting`, `skill-authoring`, `agent-authoring`, `workflow-authoring`,
`adversarial-review`, `memory-conventions`, `drift-detect`,
`context-security`, `context-data-storage`, `loop-make-it-work`,
`loop-make-it-right`, `loop-make-it-secure`, `loop-make-it-tested`,
`loop-make-it-documented`; agents: `code-reviewer`, `test-writer`,
`refactorer`, `debugger`, `skill-author`, `agent-author`.

**`review-audit`** — skills: `codebase-audit`, `check-docs-staleness`,
`check-docs-deadlinks`, `check-docs-organization`, `check-docs-examples`,
`check-docs-missing-api`, `check-ai-config`, `check-code-health`,
`check-security`; agents: `audit-code-health`, `audit-security`,
`audit-test-gaps`, `audit-architecture`, `audit-docs`, `audit-ai-config`,
`checker`, `issue-writer`.

**`workflow`** — skills: `next-issue`, `next-issue-ship`, `orchestrate`,
`file-issue`, `provision-agent`, `rebase-lockfile`, `rebase-generated`,
`rebase-imports`, `rebase-version`; agents: `ci-fixer`, `issue-filer`,
`rebase-agent`.

### Installing on a host (Mac / bare Linux)

```bash
claude plugin marketplace add joshjhall/librarian
claude plugin install dev-core@librarian
claude plugin install review-audit@librarian
claude plugin install workflow@librarian
```

`claude plugin update` rolls each plugin forward by semver. Note that the host
path tracks the latest semver release from the upstream marketplace without
local checksum verification — unlike the pinned-container path below. For
security-sensitive or automated environments, pin a specific tag and verify its
SHA against a known-good value before running `plugin update` unattended, since
plugin `patterns.sh` scripts run with your Claude Code tool grants.

### Installing in the container (pinned / offline)

> **Planned — tracked in
> [container consume #608](https://github.com/joshjhall/containers/issues/608),
> not yet landed.** The `LIBRARIAN_REF` build arg and the offline-install build
> step described here do not exist in the image yet. Until #608 ships, the
> container still installs the bundled artifacts; this section documents the
> target state so the host and container stories read together.

When `INCLUDE_DEV_TOOLS=true`, the image will clone `librarian` at a **pinned
tag/SHA** (the `LIBRARIAN_REF` build arg), register it as a local on-disk
marketplace, and install the `dev-core`, `review-audit`, and `workflow`
plugins **offline** — no live network install at runtime, preserving headless
build reproducibility. The pin is the version contract and will be registered
in `bin/check-versions.sh` for auto-patch bumps (per the
[Automated Version Updates](../../CLAUDE.md#automated-version-updates)
convention). See #608 for the build-step details.

Project-level `.claude/` configs still merge with the installed plugins (union
semantics, project wins on name conflicts).

### Build-bound skills (stay in this repo)

Three skills remain bundled by the container because they describe the image
itself and have no meaning outside it. They install to `~/.claude/skills/` at
startup, independent of `librarian`:

| Skill                   | Condition                      | Purpose                                                    |
| ----------------------- | ------------------------------ | ---------------------------------------------------------- |
| `container-environment` | Always (dynamically generated) | Describes installed tools, cache paths, container patterns |
| `docker-development`    | `INCLUDE_DOCKER=true`          | Dockerfile / compose patterns, build debugging             |
| `cloud-infrastructure`  | Any cloud flag\*               | Kubernetes / Terraform / cloud-CLI guidance                |

\* `INCLUDE_KUBERNETES`, `INCLUDE_TERRAFORM`, `INCLUDE_AWS`, `INCLUDE_GCLOUD`,
or `INCLUDE_CLOUDFLARE`.

### Agent model tiers

Within `librarian`, several agents are pinned to higher model tiers because
their output quality compounds downstream. The per-agent tiers below reflect the
current librarian release; the plugin READMEs carry the authoritative, versioned
list:

- `debugger` (`model: opus`) — root cause analysis requires deep reasoning; a
  shallow diagnosis wastes the user's time on wrong fixes
- `audit-architecture` (`model: opus`) — architectural findings inform
  refactoring priorities; missed patterns propagate as tech debt
- `audit-ai-config` (`model: opus`) — agent/skill quality analysis affects
  every conversation that loads the audited artifacts
- `skill-author`, `agent-author` (`model: opus`) — a poorly-written skill or
  agent degrades all downstream interactions
- `issue-writer` (`model: haiku`) — mechanical structured output (formatting
  findings into issues)

All other agents use `model: sonnet` for pattern matching and structured
generation. The plugin READMEs carry the authoritative per-agent tiers.

### Skill Metadata (metadata.yml)

Each skill directory includes a `metadata.yml` file that provides
machine-readable metadata for tooling (label sync, CI, documentation
generators). This file is informational — it does not change skill behavior at
runtime.

**Schema:**

```yaml
name: my-skill # Skill name (matches directory name)
version: "1.0" # Schema version

labels: # Labels the skill creates/requires on issues
  - name: status/in-progress
    color: "0E8A16"
    description: An agent is working on this issue

required_tools: # CLI tools the skill invokes
  - name: gh
    purpose: GitHub issue listing, labeling, PR creation
    install_hint: "Included with INCLUDE_DEV_TOOLS=true"

required_permissions: # Auth scopes needed
  - provider: github
    scopes: [repo]
    notes: "gh auth login with 'repo' scope minimum"

required_mcps: [] # MCP servers the skill uses
```

Skills without labels, tools, or permissions use empty arrays. See the
`skill-authoring` skill for authoring guidelines.

### Selecting and overriding librarian plugins

The general-purpose skills and agents are chosen at the **plugin** level, not
per-skill. The container installs the `dev-core`, `review-audit`, and
`workflow` plugins from the pinned local marketplace (see
[#608](https://github.com/joshjhall/containers/issues/608)); to install a
different subset on a host, install only the plugins you want:

```bash
# Host: install one plugin (this example installs only dev-core; add
# review-audit for the codebase-audit / check-* / audit-* suite, and
# workflow for next-issue / orchestrate)
claude plugin install dev-core@librarian

# Add or drop a plugin later, then roll forward by semver
claude plugin install workflow@librarian
claude plugin update
```

Per-skill / per-agent overrides for librarian content are managed upstream in
the `librarian` repo, not by this image. Project-level `.claude/skills/` and
`.claude/agents/` still take precedence on name conflicts (union merge).

### Overriding the build-bound artifacts (`CLAUDE_SKILLS` / `CLAUDE_AGENTS`)

The legacy `CLAUDE_SKILLS` / `CLAUDE_EXTRA_SKILLS` and `CLAUDE_AGENTS` /
`CLAUDE_EXTRA_AGENTS` build args still exist and still work. As the migrated
artifacts move to `librarian` (#608), their remaining scope is the artifacts the
container itself installs:

- `CLAUDE_SKILLS` / `CLAUDE_EXTRA_SKILLS` — govern the
  [build-bound skills](#build-bound-skills-stay-in-this-repo)
  (`container-environment`, `docker-development`, `cloud-infrastructure`). They
  no longer select the migrated general-purpose skills (those come from
  `librarian` and are chosen at the plugin level above).
- `CLAUDE_AGENTS` / `CLAUDE_EXTRA_AGENTS` — select from whatever agent set the
  image installs. Once #608 lands, that set is the librarian-installed agents;
  prefer `claude plugin install` / `uninstall` for plugin-level agent
  selection, and reserve these args for narrowing the installed set.

```bash
# Drop the conditional build-bound skills (container-environment still installs)
docker build --build-arg CLAUDE_SKILLS="" ...
```

- `container-environment` always installs (dynamically generated)
- Conditional skills (`docker-development`, `cloud-infrastructure`) require both
  the feature flag AND presence in `CLAUDE_SKILLS` (or `CLAUDE_SKILLS` unset)

To verify what is installed: `ls ~/.claude/skills/`, `ls ~/.claude/agents/`,
and `claude plugin list`.

## Codebase Audit System

The `codebase-audit` skill provides a periodic codebase sweep that identifies
tech debt, security issues, test gaps, architecture problems, and documentation
staleness. It dispatches 6 scanner agents in parallel. Each scanner automatically
fans out to batch sub-agents (model: haiku) when the manifest exceeds 2000
source lines, preventing context exhaustion on large codebases. After
cross-scanner deduplication, the orchestrator spawns `issue-writer` sub-agents
to create GitHub/GitLab issues in parallel.

**Invoke**: `/codebase-audit` (or describe "run a codebase audit")

All findings include a `certainty` object (CRITICAL/HIGH/MEDIUM/LOW) grading
detection confidence. With `--auto-fix`, CRITICAL and HIGH certainty findings
with trivial/small effort are automatically resolved by the `refactorer` agent.

### Parameters

| Parameter            | Default     | Description                               |
| -------------------- | ----------- | ----------------------------------------- |
| `scope`              | entire repo | Directory or glob to limit the scan       |
| `categories`         | all six     | Scanner names to run                      |
| `depth`              | `standard`  | `quick`, `standard`, or `deep`            |
| `severity-threshold` | `medium`    | Minimum severity to report                |
| `--auto-fix`         | off         | Auto-fix CRITICAL/HIGH certainty findings |
| `dry-run`            | `false`     | Output report without creating issues     |

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
precedence over the corresponding audit-\* agent.

**Migration status:**

| Domain       | check-\* skill(s)      | Status             |
| ------------ | ---------------------- | ------------------ |
| docs         | 5 check-docs-\* skills | Fully migrated     |
| security     | `check-security`       | Partially migrated |
| code-health  | `check-code-health`    | Partially migrated |
| ai-config    | `check-ai-config`      | Partially migrated |
| test-gaps    | none                   | Not started        |
| architecture | none                   | Not started        |

Partially migrated domains have check-\* skills covering a subset of the
categories handled by the corresponding audit-\* agent. Both systems coexist
during migration — the checker agent uses check-\* skills where available and
falls back to audit-\* agents for uncovered domains.

For detailed category-level gap analysis, completion criteria, and deprecation
timeline, see [check-migration-status.md](check-migration-status.md).

## Implementation Loops (loop-\* skills)

Implementation loop skills mirror the check-\* 5-file architecture but serve a
different purpose: while check-\* skills **report findings**, loop-\* skills
**apply fixes** and produce completion reports. Each loop corresponds to a
phase from the `development-workflow` skill and references its detailed
checklists rather than duplicating them.

### Skill Structure

Each loop-\* skill has 5 files:

| File             | Purpose                                                  |
| ---------------- | -------------------------------------------------------- |
| `SKILL.md`       | Loop instructions, exit criteria, commit conventions     |
| `patterns.sh`    | Deterministic pre-scan for blockers/issues               |
| `thresholds.yml` | Configurable thresholds and severity mappings            |
| `contract.md`    | Loop completion report format (change log, not findings) |
| `metadata.yml`   | Standard skill metadata                                  |

### Loop Execution Model

Each loop runs sequentially during the implementation phase:

1. **Pre-scan**: Run `patterns.sh` on changed files to identify blockers
1. **Implement**: Apply fixes guided by the skill's instructions
1. **Verify**: Run test suite, then re-run `patterns.sh`
1. **Commit**: Atomic commit with convention `loop({name}): {description}`

### Core Loops (always run)

| Loop                 | Phase ref | Focus                                   |
| -------------------- | --------- | --------------------------------------- |
| `loop-make-it-work`  | Phase 1   | End-to-end happy path, no stubs         |
| `loop-make-it-right` | Phase 2   | Refactoring for clarity and conventions |

### Context-Activated Loops

| Loop                      | Phase ref | Activated by contexts                      |
| ------------------------- | --------- | ------------------------------------------ |
| `loop-make-it-secure`     | Phase 4   | `context-security`, `context-data-storage` |
| `loop-make-it-tested`     | Phase 8   | Always (but context shapes focus)          |
| `loop-make-it-documented` | Phase 9   | Always (but context shapes focus)          |

### Completion Report

Unlike check-\* findings, loop reports track what was changed:

```json
{
  "loop": "loop-make-it-work",
  "status": "complete",
  "changes": [{"category": "functionality-added", "file": "src/handler.py", "description": "..."}],
  "blockers_resolved": [...],
  "blockers_remaining": [],
  "tests_passing": true,
  "commit": "loop(make-it-work): implement request handler"
}
```

### Project-Level Loops

Projects can add custom loop skills at `.claude/skills/loop-*/` following the
same 5-file structure. These are discovered and sequenced by the pipeline
orchestrator alongside container-provided loops.

## Contexts (context-\* skills)

Contexts are named bundles that map skills to pipeline phases. When a context
is active, it injects domain-specific expertise into planning, implementation,
review, testing, and documentation phases.

### Context Structure

Each context skill has 3 files:

| File           | Purpose                                            |
| -------------- | -------------------------------------------------- |
| `SKILL.md`     | Human-readable description and activation triggers |
| `context.yml`  | Machine-readable phase-to-skill mapping            |
| `metadata.yml` | Standard skill metadata with `context/*` label     |

### context.yml Schema

```yaml
name: security
description: "Authentication, authorization, secrets concerns"
phases:
  plan:
    - skill: loop-make-it-secure
      mode: guidance
      focus: "Plan must address auth model, trust boundaries"
  implement:
    - loop: loop-make-it-secure
      order: after-core
  review:
    - skill: check-sec-injection # future check-* skills
      status: planned
  test:
    - skill: loop-make-it-tested
      focus: "Include injection tests"
  docs:
    - skill: loop-make-it-documented
      focus: "Document security decisions"
```

### Discovery Locations

Contexts are discovered from two locations (project wins on conflicts):

1. **Global** (container-provided): `~/.claude/skills/context-*/`
1. **Project** (repo-specific): `.claude/skills/context-*/`

### Available Contexts

| Context                | Focus                                               |
| ---------------------- | --------------------------------------------------- |
| `context-security`     | Auth, secrets, input validation, OWASP              |
| `context-data-storage` | Databases, SQL, ORM, migrations, query optimization |

Additional contexts (gui, api-design, observability, infrastructure) will be
added in future releases.

## Pipeline State & Context Resets

The `/next-issue` pipeline uses JSON state files for cross-phase continuity.
State files persist at `.claude/memory/tmp/next-issue-{N}.json` and carry a
`checkpoint` object that captures key decisions, modified/planned files,
warnings, and the next action — enabling safe `/clear` resets between phases.

For `effort/trivial`/`small` issues, `/next-issue --ship` (alias `--now`)
collapses the hand-off: it keeps the interactive plan-approval gate but chains
straight into `/next-issue-ship` in the same context, skipping the post-plan
`/clear`. It is not autonomous (distinct from `--auto`) and is ignored for
`effort/medium`/`large`, where the reset boundary is preserved.

Autonomous `/next-issue --auto` also collapses the hand-off, but
unconditionally and without any gate: once implementation and testing complete
it **invokes `/next-issue-ship` in the same turn** (via the `Skill` tool), so a
single `claude --permission-mode auto '/next-issue <N> --auto'` prompt reaches a
pushed PR with no second command. This is an actual in-turn invocation, not a
printed suggestion — ending the turn after `/next-issue` would leave the work
uncommitted. Note the two distinct `auto` tokens: the harness
`--permission-mode auto` (so an untrusted golem worktree runs in `auto` rather
than silently falling back to `default` — #585) and the `/next-issue` `--auto`
skill flag (skip plan / run autonomously). Orchestrate golems additionally chain
a `; claude --permission-mode auto '/next-issue-ship --auto'` prompt at launch as
a resume backstop should the first prompt exit its turn early (`;`, not `&&`, so
the backstop runs even if the first prompt exited non-zero).

### State File Format

JSON with schema validation (`schemas/next-issue-state.schema.json` in the
`next-issue` skill directory). Version 2 format replaces the earlier YAML
frontmatter `.md` format. Legacy `.md` files are auto-migrated on first
encounter.

### Reset Points

The pipeline suggests context resets at natural phase boundaries:

| Phase Boundary      | Mode     | Description                                          |
| ------------------- | -------- | ---------------------------------------------------- |
| After plan approval | Suggest\* | Exploration context is stale for implementation      |
| Between impl. loops | Auto     | Each loop runs as a separate Task (natural boundary) |
| After ship          | Required | Clean slate for next issue                           |

\* For `effort/trivial`/`small` issues run with `/next-issue --ship` (or
`--now`), this reset is skipped — the run chains straight into
`/next-issue-ship` in-context. See `next-issue/SKILL.md` and `state-format.md`.

The `/orchestrate` skill also suggests resets after merge and sync operations.

### Backward Compatibility

State files from earlier versions (YAML frontmatter `.md`) are automatically
migrated to JSON `.json` format during Phase 0 discovery. No manual
intervention needed.

## Execution Mode Selection

The `/orchestrate mode` command recommends an execution mode for the next task
based on effort, session load, container availability, and batch size.

| Mode | Name               | When to Use                                        |
| ---- | ------------------ | -------------------------------------------------- |
| 1a   | Current branch     | Trivial fixes, single-file changes                 |
| 1b   | New branch         | Focused work needing clean diff, `effort/small`    |
| 2    | Ephemeral worktree | Parallel tangent, 2-3 concurrent tasks             |
| 3    | Container agent    | Deep parallelization, batch processing, 3-5 agents |

Mode recommendations are advisory — the user always chooses. See
`orchestrate/mode-protocol.md` for the full decision tree.

## Container Agent Orchestration

Container agents run Claude Code in isolated headless containers, each with
its own git worktree. This enables true parallel processing without shared
process space.

### Key Components

- **`/provision-agent`** — generates docker-compose from devcontainer config,
  creates worktrees, starts containers with tmux-attached Claude sessions
- **`/orchestrate spawn`** — provisions agents and assigns issues from the
  priority queue
- **`SKIP_LSP_INSTALL=true`** — build arg for lean agent containers (no LSP
  servers, ~200MB smaller)
- **Status files** — `.worktrees/.status/agent{N}.json` for coordination
- **`rebase-agent`** — automated conflict resolution for trivial merge conflicts

### Human Interaction

Each agent's Claude Code runs in a named tmux session. Attach directly:

```bash
docker exec -it project-agent01-1 tmux attach -t claude
```

### Rebase Agent

The `rebase-agent` handles trivial merge conflicts automatically during
cross-PR rebase (`/orchestrate rebase`, default) and legacy `/orchestrate merge`
/ `/orchestrate sync`:

- Lock files → regenerate from manifest
- Generated files → re-run generator
- Import ordering → combine, deduplicate, sort
- Version numbers → take higher version
- Non-trivial conflicts → escalate to human

## Safety Model

Three layers of safety protect agent pipelines:

### Tool Scoping

Each agent's `tools:` frontmatter restricts what actions it can take. Read-only
agents (reviewers, auditors) get Read/Grep/Glob/Bash. Write agents (refactorer,
test-writer) additionally get Edit/Write. Every tool grant has a documented
rationale.

### MUST NOT Restrictions

Every agent has a `## Restrictions` section with explicit MUST NOT rules
derived from its role:

- **Audit agents**: MUST NOT modify files, create issues directly, or auto-fix
- **Review agents**: MUST NOT edit files or create commits
- **Write agents**: MUST NOT change observable behavior (refactorer) or modify
  production code (test-writer)
- **Pipeline agents**: MUST NOT take actions outside their pipeline stage

### Workflow Gate Assertions

Pre-condition checks at key workflow boundaries prevent skipping critical steps:

| Gate                    | Location           | Mode     | What it checks                                    |
| ----------------------- | ------------------ | -------- | ------------------------------------------------- |
| Pre-ship test gate      | `/next-issue-ship` | Blocking | Test suite passes before PR creation              |
| Pre-review quality gate | `/next-issue-ship` | Advisory | Deslop patterns, debug stmts, test coverage gaps  |
| CI remediation gate     | `/next-issue-ship` | Advisory | CI checks pass after PR (max 3 auto-fix attempts) |
| Scanner completion gate | `/codebase-audit`  | Partial  | All scanners returned valid JSON                  |
| Finding schema gate     | `/codebase-audit`  | Blocking | Findings conform to schema                        |

**Blocking** gates prevent the workflow from proceeding. **Advisory** gates
warn but allow proceeding (set `PRE_REVIEW_STRICT=true` to make them blocking
for PRs). **Partial** gates allow proceeding with successful results when some
components fail.
