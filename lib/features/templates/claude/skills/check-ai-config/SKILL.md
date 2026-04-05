---
description: Validates Claude Code configuration files (agents, skills, CLAUDE.md, MCP configs, hooks) for structural issues, bloat, and misconfigurations. Combines deterministic pre-scan with LLM heuristic analysis.
---

# check-ai-config

Validates Claude Code AI configuration artifacts for structural correctness,
bloat, misconfigurations, and quality issues. The deterministic pre-scan
(`patterns.sh`) handles structural checks; this skill handles nuanced analysis.

## Categories

### agent-frontmatter (deterministic + heuristic)

Pre-scan detects: missing frontmatter fields, invalid model values, wildcard
tools, naming convention violations.

LLM adds: wrong model selection for the task complexity (e.g., opus for
simple scanning), tool list that includes write tools on read-only agents,
description that doesn't match the agent's actual behavior.

### skill-frontmatter (deterministic + heuristic)

Pre-scan detects: missing description, missing workflow section, missing
metadata.yml.

LLM adds: vague descriptions that don't help routing, scope overlap with
other skills, missing output format specification.

### ai-file-bloat (deterministic)

Pre-scan detects all instances via line counting against configurable
thresholds. LLM confirms whether large files contain decomposable sections.

### config-inconsistency (heuristic)

LLM checks: skills referencing non-existent agents, CLAUDE.md claims that
don't match the codebase, contradictions between skill and agent instructions.

### mcp-misconfiguration (deterministic + heuristic)

Pre-scan detects: insecure HTTP URLs. LLM adds: missing env var documentation,
incorrect server arguments.

### hook-safety (deterministic + heuristic)

Pre-scan detects: destructive commands, secret leaks. LLM adds: context
assessment (e.g., a pre-commit hook running a formatter is acceptable).

## Workflow

1. Review pre-scan findings from `patterns.sh` — confirm, dismiss, or adjust
   severity based on context
1. For each file in the manifest, analyze against the heuristic aspects of
   each category listed above
1. Emit findings with certainty MEDIUM (heuristic) or LOW (subjective quality)
1. For pre-scan findings that are confirmed, keep certainty HIGH (deterministic)

## Output

Findings per finding-schema.md with `skill: "check-ai-config"`.
