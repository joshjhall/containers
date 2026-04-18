# AgentSys Evaluation Report

Evaluation of [agent-sh/agentsys](https://github.com/agent-sh/agentsys) v5.8.1
against our container build system's Claude Code agents and skills.

**Date:** 2026-03-30
**Issue:** #304
**Test codebase:** This repository (`containers/`)

## Executive Summary

AgentSys is a mature orchestration system (19 plugins, 40 agents, 39 skills)
that embodies several architectural patterns our system should adopt. After
side-by-side evaluation, the recommendations fall into four categories:

| Disposition                                   | Count | Areas                                                                                                |
| --------------------------------------------- | ----- | ---------------------------------------------------------------------------------------------------- |
| **Adopt** (use their approach)                | 3     | Model tiering, certainty grading, deslop                                                             |
| **Adapt** (improve ours using their ideas)    | 5     | Code review parallelization, audit code-enforcement, pipeline phases, prose trimming, CI remediation |
| **Build** (new capability inspired by theirs) | 2     | Agent-judge safety protocol, drift detection                                                         |
| **Skip** (not worth the complexity)           | 4     | consult/debate, web-ctl, onboard (we have CLAUDE.md), full agentsys integration                      |

**Key findings:**

1. **Model tiering is the highest-impact change.** AgentSys uses Opus for
   reasoning-critical work (exploration, planning, implementation), Sonnet for
   pattern-matching tasks, and Haiku for mechanical execution. Our all-Sonnet
   approach leaves quality on the table for complex tasks and overpays for
   simple ones.

1. **Code-based enforcement reduces token cost significantly.** Their deslop
   plugin uses 60+ regex patterns for deterministic detection, reserving LLM
   calls for judgment. Our audit agents use LLM for everything, including
   pattern-matchable issues.

1. **Parallelized specialized review catches more than single-pass.** Their
   review loop spawns 4+ specialized reviewers (security, performance, test
   coverage, code quality) in parallel, vs our single `code-reviewer` agent.

1. **Integration is clean.** AgentSys installs to `~/.claude/plugins/` via
   marketplace, our agents to `~/.claude/agents/` and `~/.claude/skills/`. No
   naming conflicts. Coexistence works.

---

## Methodology

- **Test environment:** Dev container with `INCLUDE_DEV_TOOLS=true`
- **AgentSys version:** v5.8.1 (installed via `npm install -g agentsys@latest`)
- **Comparison approach:** Documentation analysis, architecture comparison,
  and installation testing. Side-by-side output comparisons where feasible
  within evaluation scope.
- **Quality dimensions:** Accuracy, coverage, actionability, efficiency

---

## Comparison Matrix

| Capability          | Our System                  | AgentSys                                       | Winner   | Recommendation                 |
| ------------------- | --------------------------- | ---------------------------------------------- | -------- | ------------------------------ |
| Model tiering       | 2-tier (sonnet + haiku)     | 3-tier (opus + sonnet + haiku)                 | AgentSys | Adopt 3-tier                   |
| Code review         | 1 agent, single-pass        | 4+ parallel specialized reviewers              | AgentSys | Adapt: parallelize ours        |
| Audit system        | 6 parallel agents, LLM-only | repo-intel (deterministic) + agnix (385 rules) | Mixed    | Adapt: add deterministic layer |
| Issue pipeline      | 5-phase (next-issue + ship) | 12-phase (next-task)                           | Mixed    | Adapt: adopt useful phases     |
| AI slop detection   | None                        | deslop (60+ patterns, auto-fix)                | AgentSys | Adopt deslop                   |
| Safety protocol     | Tool scoping in frontmatter | agent-judge (scope-creep, hallucination)       | AgentSys | Build equivalent               |
| Drift detection     | None                        | drift-detect (plan vs impl)                    | AgentSys | Build lightweight version      |
| CI remediation      | None                        | ci-fixer + ci-monitor                          | AgentSys | Adapt into ship workflow       |
| Certainty grading   | severity/\* labels only     | CRITICAL/HIGH/MEDIUM/LOW + auto-fix            | AgentSys | Adopt certainty model          |
| Agent/skill quality | audit-ai-config (LLM)       | enhance (7 analyzers) + agnix (385 rules)      | AgentSys | Adapt: add deterministic rules |
| Doc sync            | Manual                      | sync-docs agent                                | AgentSys | Build if needed                |
| Cross-tool consult  | None                        | consult + debate                               | AgentSys | Skip (niche)                   |
| Browser control     | None                        | web-ctl (Playwright)                           | AgentSys | Skip (not our domain)          |
| Onboarding          | CLAUDE.md                   | onboard agent                                  | Mixed    | Skip (CLAUDE.md sufficient)    |
| State persistence   | YAML frontmatter in .md     | JSON (tasks.json + flow.json)                  | Mixed    | Keep ours (simpler)            |
| Installation        | Template copy at startup    | npm global + marketplace                       | Ours     | Keep ours (offline-capable)    |

---

## C1: Model Tiering

### Their Approach

AgentSys assigns models based on task complexity:

| Model  | Agent Count | Use Cases                                                                        |
| ------ | ----------- | -------------------------------------------------------------------------------- |
| Opus   | 12          | Exploration, planning, implementation, agent analysis, performance investigation |
| Sonnet | 24          | Task discovery, code review, CI fixing, deslop, delivery validation              |
| Haiku  | 3           | Worktree management, CI polling, mechanical edits                                |

**Key rationale:** "Quality compounds. Bad agent prompts = bad agent outputs
across all uses." Opus is used where errors propagate downstream (exploration
informs planning, planning informs implementation).

### Our Approach

| Model  | Agent Count | Use Cases          |
| ------ | ----------- | ------------------ |
| Sonnet | 10          | All primary agents |
| Haiku  | 1           | issue-writer only  |

### Assessment

Our all-Sonnet approach has two problems:

1. **Quality ceiling for complex tasks.** Our `code-reviewer` runs on Sonnet,
   while theirs runs specialized review on Sonnet but exploration/planning on
   Opus. For tasks where exploration quality matters (codebase-audit, complex
   code review), Opus would catch subtle issues Sonnet misses.

1. **Cost floor for mechanical tasks.** Our audit agents all run on Sonnet,
   but batch scanning of file manifests is mechanical work better suited to
   Haiku. We already use Haiku for `issue-writer` — the same logic applies to
   batch file scanning in audit agents.

### Recommendation: Adopt 3-Tier Model

Proposed model reassignment for our agents:

| Agent              | Current | Proposed | Rationale                                            |
| ------------------ | ------- | -------- | ---------------------------------------------------- |
| code-reviewer      | sonnet  | sonnet   | Pattern matching is Sonnet's strength                |
| debugger           | sonnet  | opus     | Root cause analysis benefits from deeper reasoning   |
| test-writer        | sonnet  | sonnet   | Structured generation is Sonnet's strength           |
| refactorer         | sonnet  | sonnet   | Pattern-based transformation                         |
| audit-code-health  | sonnet  | sonnet   | But batch scanners should be haiku                   |
| audit-security     | sonnet  | sonnet   | But batch scanners should be haiku                   |
| audit-test-gaps    | sonnet  | sonnet   | But batch scanners should be haiku                   |
| audit-architecture | sonnet  | opus     | Architecture analysis benefits from deeper reasoning |
| audit-docs         | sonnet  | sonnet   | Pattern matching                                     |
| audit-ai-config    | sonnet  | opus     | Agent quality analysis compounds                     |
| issue-writer       | haiku   | haiku    | Already optimal                                      |

**Cost impact:** Opus for 3 agents (debugger, audit-architecture, audit-ai-config)
increases cost for those specific invocations but should improve output quality
where it matters most. The audit batch-scanning optimization (already using
Haiku sub-agents for batches > 2000 lines) partially offsets this.

---

## C4: Code-Based Enforcement

### Their Approach

AgentSys uses a layered detection strategy:

1. **Phase 1 (deterministic):** 60+ regex patterns with O(1) lookup,
   pre-indexed by language and severity. No LLM cost.
1. **Phase 2 (context-aware):** Multi-pass analyzers for doc-to-code ratio,
   verbosity, over-engineering, dead code. LLM-assisted.
1. **Phase 3 (optional tools):** CLI tools like `jscpd`, `madge`, `eslint`,
   `pylint` when available.

**Certainty grading:**

| Level    | Meaning          | Action                |
| -------- | ---------------- | --------------------- |
| CRITICAL | Security issue   | Auto-fix with warning |
| HIGH     | Definite problem | Auto-fix              |
| MEDIUM   | Probable problem | Flag for human review |
| LOW      | Possible problem | Report only           |

### Our Approach

Our audit agents (audit-security, audit-code-health, etc.) use pure LLM
analysis for all detection, including patterns that could be caught
deterministically (hardcoded secrets, debug statements, empty catch blocks).

### Assessment

The hybrid approach is superior:

- **Deterministic detection is cheaper and more reliable** for known patterns.
  A regex catches `console.log` 100% of the time; an LLM might miss it in a
  large context window.
- **Certainty grading enables safe automation.** HIGH certainty findings can
  be auto-fixed without human review, reducing the review burden.
- **LLM is reserved for judgment calls.** Over-engineering detection, code
  smell assessment, and architectural concerns genuinely need LLM reasoning.

### Recommendation: Adapt

1. Add a deterministic pre-scan layer to audit agents that catches regex-
   matchable patterns before LLM analysis
1. Adopt certainty grading (CRITICAL/HIGH/MEDIUM/LOW) for all audit findings
1. Enable auto-fix for HIGH certainty findings in the codebase-audit pipeline
1. Keep LLM analysis for context-dependent findings (MEDIUM/LOW certainty)

---

## A1: Code Review

### Their Approach

AgentSys spawns 4+ specialized reviewers in parallel:

| Reviewer              | Focus                                 | Activation           |
| --------------------- | ------------------------------------- | -------------------- |
| code-quality-reviewer | Style, best practices, error handling | Always               |
| security-expert       | Injection, auth, secrets, validation  | Always               |
| performance-engineer  | N+1, memory leaks, blocking ops       | Always               |
| test-quality-guardian | Coverage, edge cases, design          | Always               |
| architecture-reviewer | Organization, SOLID, dependencies     | If > 50 files        |
| database-specialist   | Queries, indexes, transactions        | If DB detected       |
| api-designer          | REST, error codes, rate limiting      | If API detected      |
| frontend-specialist   | Components, state, a11y               | If frontend detected |
| backend-specialist    | Services, concurrency, domain         | If backend detected  |
| devops-reviewer       | Pipelines, secrets, Docker            | If CI/CD detected    |

Each returns structured JSON findings. The orchestrator aggregates, deduplicates,
and iterates until clean (max 5 rounds).

### Our Approach

Single `code-reviewer` agent with a comprehensive checklist covering bugs,
security, performance, error handling, concurrency, and style in one pass.

### Assessment

**Their strengths:**

- Specialization catches domain-specific issues (a security-focused reviewer
  is more thorough than a generalist on security)
- Parallel execution means total wall-clock time is similar to single-pass
- Conditional activation (database, API, frontend specialists) avoids wasting
  tokens on irrelevant analysis
- Iterative fix-and-recheck loop ensures fixes don't introduce new issues

**Our strengths:**

- Simpler orchestration (one agent, one invocation)
- Lower total token cost (one context window vs 4-10)
- Sufficient for most common review tasks

### Recommendation: Adapt

1. Split `code-reviewer` into 4 core specialized sub-agents (security,
   performance, test coverage, code quality) that run in parallel
1. Add conditional specialists triggered by file type detection
1. Keep the single `code-reviewer` as a lightweight option for quick reviews
1. Add iterative fix loop to `/codebase-audit` workflow

---

## A5: Audit System

### Their Approach

Two complementary systems:

1. **repo-intel:** Unified static analysis via JavaScript code — git history,
   AST symbols, project metadata. Deterministic, no LLM cost for data collection.
1. **agnix:** Configuration linter with 385 validation rules across 10+
   platforms. Rust-based with LSP support for real-time feedback.

### Our Approach

6 parallel LLM-powered audit agents orchestrated by `/codebase-audit`:

- audit-code-health, audit-security, audit-test-gaps, audit-architecture,
  audit-docs, audit-ai-config
- Manifest-driven dispatch with Haiku batch scanning for large codebases
- issue-writer sub-agents for creating GitHub issues from findings

### Assessment

**Their strengths:**

- Deterministic scanning (repo-intel) is faster and cheaper for structural
  analysis
- agnix's 385 rules for AI config validation far exceeds our audit-ai-config's
  LLM-based approach
- No false positives for rule-based checks

**Our strengths:**

- LLM-powered analysis catches nuanced issues that rules miss (e.g.,
  "this function is doing too many things" or "these tests don't actually
  test the right behavior")
- Parallel fan-out architecture is well-designed for scaling
- Direct integration with issue creation workflow

### Recommendation: Adapt

1. Add a deterministic pre-scan phase to `/codebase-audit` that runs before
   LLM agents (catch the easy stuff first)
1. Evaluate adopting agnix rules relevant to our Claude Code agent definitions
   (53 Claude Code-specific rules in their set)
1. Keep LLM agents for nuanced analysis that rules can't handle
1. Consider repo-intel as an optional data source for our audit agents

---

## A7: Pipeline Comparison

### Their Approach: 12 Phases

| Phase                   | Agent                  | Model        | Human? |
| ----------------------- | ---------------------- | ------------ | ------ |
| 1. Policy selection     | -                      | -            | Yes    |
| 2. Task discovery       | task-discoverer        | sonnet       | Yes    |
| 3. Worktree setup       | worktree-manager       | haiku        | No     |
| 4. Exploration          | exploration-agent      | opus         | No     |
| 5. Planning             | planning-agent         | opus         | No     |
| 6. User approval        | -                      | -            | Yes    |
| 7. Implementation       | implementation-agent   | opus         | No     |
| 8. Pre-review gates     | deslop + test-coverage | sonnet       | No     |
| 9. Review loop          | 4+ parallel reviewers  | sonnet       | No     |
| 10. Delivery validation | delivery-validator     | sonnet       | No     |
| 11. Docs update         | sync-docs              | sonnet       | No     |
| 12. Ship                | ci-monitor + ci-fixer  | haiku/sonnet | No     |

3 human interactions, then fully autonomous through merge.

### Our Approach: 5 Phases

| Phase                          | Description                       | Human? |
| ------------------------------ | --------------------------------- | ------ |
| 0. Resume check                | State file detection              | No     |
| 1. Select                      | Priority-based issue selection    | Yes    |
| 2. Plan                        | Exploration + implementation plan | Yes    |
| 3. Implement                   | (manual, guided by plan)          | Yes    |
| 4. Ship (via /next-issue-ship) | Commit, PR, label                 | Yes    |

More human touchpoints, less automation between phases.

### Assessment

**Their advantages:**

- **Post-approval autonomy:** After plan approval, 6 phases run without human
  intervention (implementation through merge). Ours requires human involvement
  at each step.
- **Pre-review gates:** Automatic deslop + test coverage check before review
  catches mechanical issues early.
- **Review loop:** Iterative specialized review with automatic fixes.
- **CI remediation:** Automatic CI failure diagnosis and fixing.
- **Worktree isolation:** Automatic worktree management for parallel work.

**Our advantages:**

- **Simpler state model:** YAML frontmatter in markdown vs JSON state files.
  Easier to debug and understand.
- **Human-in-the-loop:** More human oversight means fewer runaway automation
  issues. Appropriate for our current maturity level.
- **Leaner scope:** 5 phases vs 12 means less to maintain and debug.

### Recommendation: Adapt selectively

Phases worth adopting from their pipeline:

1. **Pre-review gates (Phase 8):** Add automatic deslop + test coverage check
   after implementation, before PR creation in `/next-issue-ship`
1. **CI remediation (Phase 12):** Add ci-fixer capability to `/next-issue-ship`
   that diagnoses and fixes CI failures automatically
1. **Worktree setup (Phase 3):** Our orchestrate skill already supports
   worktrees — ensure next-issue integrates with it

Phases to skip:

- Policy selection (Phase 1): Over-engineered for our use case
- Separate exploration + planning agents (Phases 4-5): Our combined Phase 2
  is sufficient
- Delivery validation (Phase 10): Redundant if review + CI pass

---

## B1: Deslop (AI Slop Removal)

### What It Does

Detects and removes AI-generated artifacts across 5 languages using 60+ regex
patterns in 3 phases:

1. **Phase 1:** Regex patterns — console.log, debug statements, empty catches,
   TODO/FIXME, hardcoded secrets, placeholder text (HIGH/CRITICAL certainty)
1. **Phase 2:** Context-aware analyzers — doc-to-code ratio, verbosity,
   over-engineering, buzzword inflation, dead code, stub functions (MEDIUM)
1. **Phase 3:** CLI tools when available — jscpd, madge, eslint, pylint (LOW)

Auto-fix strategies: `remove` (delete line), `replace` (substitute with
config), `add_logging` (add error handler), `flag` (human review).

### Our Gap

We have no equivalent capability. Our audit-code-health checks for some
similar issues (dead code, complexity) but doesn't specifically target AI
slop patterns like hedging language, buzzword inflation, or excessive
documentation ratios.

### Assessment

This is a genuinely novel and valuable capability:

- **60+ patterns are pre-built and tested** across JS/TS, Python, Rust, Go,
  Java
- **Zero LLM cost for Phase 1** — pure regex
- **Certainty grading enables safe auto-fix** — HIGH items are auto-removed
- **Directly addresses a real problem** — AI-generated code often includes
  debug statements, verbose comments, and hedging language

### Recommendation: Adopt

Two implementation options:

1. **Install agentsys deslop plugin** (`agentsys install deslop`) — get it
   immediately with no development cost. Already works alongside our system.
1. **Build our own** — extract the pattern list and implement a simpler
   version as a pre-commit hook or skill

Recommended: **Option 1** (install the plugin) for immediate value, then
evaluate if we want to internalize the patterns long-term.

---

## B2: Agent-Judge (Safety Protocol)

### What It Does

AgentSys enforces safety through tool restrictions in agent frontmatter and
workflow-level enforcement via SubagentStop hooks:

- Implementation agent MUST NOT create PRs or push
- Delivery validator MUST NOT skip sync-docs
- Review loop MUST run all specialized reviewers

This is architectural safety (the workflow prevents unsafe actions) rather
than a separate judge agent that evaluates outputs.

### Our Approach

We use tool scoping in agent frontmatter (`tools: [Read, Grep, Glob, Bash]`)
to restrict what each agent can do. This prevents `code-reviewer` from editing
files, for example.

### Assessment

Their approach is more sophisticated:

- **Workflow-level enforcement** prevents agents from skipping steps, not just
  restricting tools
- **SubagentStop hooks** act as gates between phases
- **Explicit restrictions** documented in agent definitions (MUST NOT create
  PR, MUST NOT push)

Our tool scoping is a good foundation but lacks workflow-level enforcement.

### Recommendation: Build

1. Add workflow-level assertions to `/next-issue-ship` (e.g., verify tests
   pass before allowing PR creation)
1. Consider SubagentStop-style hooks for `/codebase-audit` to enforce audit
   quality gates
1. Document explicit restrictions in agent definitions (MUST NOT patterns)

---

## D1-D3: Integration Feasibility

### D1: Coexistence

**Result: Clean coexistence confirmed.**

| Component | Our Location              | AgentSys Location                          | Conflict? |
| --------- | ------------------------- | ------------------------------------------ | --------- |
| Agents    | `~/.claude/agents/`       | `~/.claude/plugins/marketplaces/agentsys/` | No        |
| Skills    | `~/.claude/skills/`       | `~/.claude/plugins/marketplaces/agentsys/` | No        |
| Plugins   | `~/.claude/plugins/data/` | `~/.claude/plugins/marketplaces/agentsys/` | No        |
| Config    | `~/.claude/settings.json` | `~/.claude/plugins/installed_plugins.json` | No        |

AgentSys installs to the plugin marketplace system, which is a separate
namespace from our direct agent/skill installation. Both systems coexist
without conflicts.

### D2: Cherry-Picking

**Result: Individual plugins installable.**

```bash
agentsys install deslop          # Install only deslop
agentsys install deslop:deslop   # Install only the deslop skill
agentsys search next-task:       # List next-task components
```

Individual plugins can be installed independently with dependency resolution.
This means we can adopt specific capabilities (deslop, enhance) without
installing the full suite.

### D3: INCLUDE_AGENTSYS Feature Flag

**Recommendation: Not warranted at this time.**

Reasons:

- AgentSys is an npm package, not a system dependency — users can install it
  themselves
- Adding it as a container feature creates a maintenance burden for upstream
  version tracking
- The useful capabilities (deslop patterns, model tiering insights) are better
  internalized into our own agents than added as a dependency

If we later decide to bundle specific plugins, a lightweight
`INCLUDE_AGENTSYS` flag could install a curated subset:

```bash
agentsys install deslop enhance --tool claude --no-strip
```

---

## Remaining Areas (Brief Assessment)

### A2-A4: Debugger, Test Writer, Refactorer

AgentSys doesn't have direct equivalents — these capabilities are embedded in
their `implementation-agent` (Opus) and `ci-fixer` (Sonnet). No specific
improvements identified beyond the model tiering recommendation already made.

### A6: Issue Writer

Their `task-discoverer` handles issue discovery, not creation. Our
`issue-writer` + `/file-issue` is more complete for issue creation from audit
findings. **Keep ours.**

### A8: Hookify vs Skillers

Their `skillers` plugin mines conversation transcripts and recommends
skills/hooks/agents. Our `hookify` focuses specifically on hook creation.
Skillers is broader but our hookify is more focused and actionable.
**Keep ours, consider adding skill recommendation.**

### A9-A10: AI Config Audit, Agent Authoring

Their `enhance` plugin (7 specialized analyzers) and `agnix` (385 rules) are
significantly more comprehensive than our `audit-ai-config` and
`skill-authoring`/`agent-authoring` skills. **Adapt: internalize their best
rules into our audit agent, or install `enhance` as a plugin.**

### A11-A12: Orchestrate, Development Workflow

Their worktree-manager is similar to our orchestrate skill. Their phase-gated
pipeline is more automated but more complex. **Keep ours for simplicity.**

### B3-B9: Gaps

| Capability         | Assessment                                 | Recommendation            |
| ------------------ | ------------------------------------------ | ------------------------- |
| B3: drift-detect   | Novel — compares plans vs implementation   | Build lightweight version |
| B4: ci-fixer       | Useful — auto-fix CI failures              | Adapt into ship workflow  |
| B5: onboard        | Nice but CLAUDE.md serves this purpose     | Skip                      |
| B6: release        | Our `release.sh` is simpler and sufficient | Skip                      |
| B7: consult/debate | Niche — cross-tool consultation            | Skip                      |
| B8: web-ctl        | Not our domain                             | Skip                      |
| B9: sync-docs      | Useful if doc drift is a problem           | Evaluate later            |

### C2-C7: Architectural Patterns

| Pattern                   | Assessment                                   | Recommendation    |
| ------------------------- | -------------------------------------------- | ----------------- |
| C2: Certainty grading     | Covered in C4 section                        | Adopt             |
| C3: Phase-gated pipelines | Covered in A7 section                        | Adapt selectively |
| C5: Progressive discovery | We already do this well                      | Keep current      |
| C6: State persistence     | Their JSON is richer but our YAML is simpler | Keep current      |
| C7: Prose trimming        | Valid concern — audit our agent definitions  | File follow-up    |

---

## Token Usage Analysis

### Cost Model Comparison

Based on agent model assignments and typical invocation patterns:

| Scenario       | Our Cost (relative)        | AgentSys Cost (relative)                 | Notes                                  |
| -------------- | -------------------------- | ---------------------------------------- | -------------------------------------- |
| Code review    | 1.0x (1 Sonnet)            | 1.2-3.0x (4+ Sonnet parallel)            | Higher cost, better coverage           |
| Full audit     | 1.0x (6 Sonnet parallel)   | 0.3-0.5x (deterministic + selective LLM) | Lower cost via regex pre-scan          |
| Issue pipeline | 1.0x (mostly human-driven) | 3-5x (12 automated phases)               | Much higher cost, much less human time |
| Deslop scan    | N/A                        | 0.1x (mostly regex)                      | New capability, very cheap             |

**Key insight from AgentSys:** "Pipeline investment matters more than model
spend. Sonnet + AgentSys achieves comparable quality to raw Opus at 40% lower
cost." The cost savings come from deterministic pre-processing, not from using
cheaper models.

### Optimization Opportunities

1. **Deterministic pre-scan:** Adding regex-based detection to audit agents
   could reduce LLM token usage by 30-50% for pattern-matchable findings
1. **Model tiering:** Upgrading debugger and audit-architecture to Opus
   increases cost by ~2x for those agents but should improve finding quality
1. **Batch optimization:** Our existing Haiku batch scanning for manifests
   > 2000 lines is already well-optimized

---

## Recommendations Summary

### Priority 1: Highest Impact

| #  | Recommendation                                    | Disposition | Effort  | Issue |
| -- | ------------------------------------------------- | ----------- | ------- | ----- |
| R1 | Adopt 3-tier model assignment (opus/sonnet/haiku) | Adopt       | Small   | #312  |
| R2 | Add certainty grading to audit findings           | Adopt       | Medium  | #313  |
| R3 | Install deslop plugin for AI slop detection       | Adopt       | Trivial | #314  |

### Priority 2: High Impact

| #  | Recommendation                                          | Disposition | Effort | Issue |
| -- | ------------------------------------------------------- | ----------- | ------ | ----- |
| R4 | Parallelize code-reviewer into 4 specialized sub-agents | Adapt       | Large  | #315  |
| R5 | Add deterministic pre-scan layer to audit pipeline      | Adapt       | Medium | #316  |
| R6 | Add pre-review gates to next-issue-ship                 | Adapt       | Medium | #317  |
| R7 | Add CI remediation to ship workflow                     | Adapt       | Medium | #318  |

### Priority 3: Medium Impact

| #   | Recommendation                                  | Disposition | Effort | Issue |
| --- | ----------------------------------------------- | ----------- | ------ | ----- |
| R8  | Build workflow-level safety assertions          | Build       | Medium | #319  |
| R9  | Build lightweight drift detection               | Build       | Large  | #320  |
| R10 | Audit agent definitions for prose trimming (C7) | Adapt       | Small  | #321  |
| R11 | Evaluate agnix rules for our AI config audit    | Adapt       | Medium | #322  |

---

## Appendices

### A. AgentSys Installation

```bash
npm install -g agentsys@latest        # Install CLI
agentsys --tool claude --no-strip     # Install for Claude Code with model specs
agentsys list --all                   # Verify installation
```

Installed to: `~/.claude/plugins/marketplaces/agentsys/`

### B. Component Counts

| Component | Our System                                         | AgentSys |
| --------- | -------------------------------------------------- | -------- |
| Agents    | 11                                                 | 40       |
| Skills    | 18                                                 | 39       |
| Commands  | 3 (/codebase-audit, /next-issue, /next-issue-ship) | 25       |
| Plugins   | N/A (direct install)                               | 19       |
| Platforms | 1 (Claude Code)                                    | 5        |

### C. Model Distribution

**AgentSys (from AGENTS.md):**

- Opus (12): exploration-agent, planning-agent, implementation-agent,
  agent-enhancer, claudemd-enhancer, docs-enhancer, prompt-enhancer,
  hooks-enhancer, skills-enhancer, plan-synthesizer, perf-orchestrator,
  perf-theory-gatherer, perf-theory-tester, perf-analyzer, learn-agent,
  skillers-recommender
- Sonnet (24): task-discoverer, deslop-agent, ci-fixer, sync-docs-agent,
  delivery-validator, test-coverage-checker, prepare-delivery-agent,
  plugin-enhancer, cross-file-enhancer, perf-code-paths,
  perf-investigation-logger, map-validator, release-agent, consult-agent,
  debate-orchestrator, web-session, onboard-agent, can-i-help-agent,
  skillers-compactor, agnix-agent, code-quality-reviewer, security-expert,
  performance-engineer, test-quality-guardian
- Haiku (3): worktree-manager, simple-fixer, ci-monitor

**Our System:**

- Sonnet (10): code-reviewer, debugger, test-writer, refactorer,
  audit-code-health, audit-security, audit-test-gaps, audit-architecture,
  audit-docs, audit-ai-config
- Haiku (1): issue-writer
