---
description: Guidelines for writing high-quality Claude Code agents and subagent definitions. Use when creating new agents, reviewing existing agents, or designing multi-agent workflows.
---

# Agent Authoring

**Detailed reference**: See `patterns.md` in this skill directory for a
copy-pasteable agent template, frontmatter reference, good/bad examples,
model selection guide, and review checklist. Load it when writing or
reviewing an agent.

## Agent Structure

Agents are markdown files with YAML frontmatter (configuration) and a body
(system prompt). The body is the ONLY prompt the agent receives — agents do
not inherit the full Claude Code system prompt.

- `name` (required): lowercase with hyphens, matches directory name
- `description` (required): tells Claude when to delegate — primary trigger
- `tools`: allowlist of tools the agent can use (inherits all if omitted)
- `model`: `haiku`, `sonnet`, `opus`, or `inherit` (default: `inherit`)
- Other fields: `disallowedTools`, `permissionMode`, `maxTurns`, `skills`,
  `mcpServers`, `hooks`, `memory`

## Description Field (Critical)

Claude uses the description to decide whether to delegate a task. A vague
description causes missed delegations or false triggers.

- Must state WHAT the agent does AND WHEN to use it
- Include "use proactively" if the agent should auto-trigger
- Include key terms users would mention when the agent should activate

```yaml
# Bad — too vague
description: Helps with code

# Bad — what but not when
description: Reviews code quality

# Good — what + when + proactive trigger
description: Expert code reviewer. Use proactively after writing or modifying code.
```

## System Prompt Design

The body is the agent's entire instruction set. Write it as a direct briefing.

- **Open with role and purpose** — one sentence establishing identity
- **Define the workflow** — numbered steps the agent follows when invoked
- **Specify output format** — how results should be structured
- **Include red flags / checklists** — concrete items to check, not vague goals
- Assume competence — skip fundamentals the model already knows
- Be specific: real commands, real file patterns, real examples

## Tool Scoping

Start restrictive, expand as needed. Every unnecessary tool is a risk.

- **Read-only agents** (reviewers, researchers): `Read, Grep, Glob, Bash`
- **Editing agents** (fixers, refactorers): add `Edit` or `Write`
- **Full-capability agents**: omit `tools` to inherit all
- Use `disallowedTools` to block specific tools from inherited set
- Use `hooks` for conditional restrictions (e.g., read-only SQL queries)

## Model Selection

Match the model to the task's complexity and frequency:

| Model     | Use when                                        | Trade-off             |
| --------- | ----------------------------------------------- | --------------------- |
| `haiku`   | Fast lookups, simple checks, high-frequency ops | Fastest, cheapest     |
| `sonnet`  | Balanced analysis, code review, most agents     | Good quality + speed  |
| `opus`    | Complex reasoning, architecture, orchestration  | Most capable, slowest |
| `inherit` | Same model as the conversation (default)        | Context-dependent     |

## Core Principles

- **One task per agent** — don't mix reviewing with fixing with testing
- **Minimal viable tools** — grant only what the task requires
- **Isolation preserves context** — agent output stays in its own window;
  only the summary returns to the main conversation
- **Description drives delegation** — invest more time in description than
  in the system prompt itself
- **No nesting** — subagents cannot spawn other subagents; chain from the
  main conversation instead

## Anti-Patterns

- Overlapping agents with similar descriptions (confuses delegation)
- System prompts that restate what the model already knows
- Granting all tools when the agent only needs read access
- Missing output format (agent returns unstructured walls of text)
- Prompts full of if-then logic instead of clear heuristics
- No workflow steps (agent doesn't know where to start)

## When to Use

- Creating a new specialized agent for a repeatable task
- Reviewing an existing agent's prompt, tools, or model choice
- Designing multi-agent workflows with delegation chains

## When NOT to Use

- Writing skills (use `skill-authoring` skill instead)
- One-off tasks that don't warrant a reusable agent
- Tasks that need the main conversation's full context
