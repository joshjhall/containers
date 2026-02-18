# Agent Authoring — Patterns & Examples

Reference companion for `SKILL.md`. Load this when writing a new agent,
reviewing an existing agent, or designing agent workflows for cross-tool
compatibility.

______________________________________________________________________

## Agent Template

Copy-pasteable skeleton for a new agent:

```markdown
---
name: <agent-name>
description: <What it does and when to delegate — include key trigger terms>
tools: Read, Grep, Glob, Bash
model: sonnet
---

You are a <role> specializing in <domain>.

When invoked:
1. <First step — gather context>
2. <Second step — analyze or act>
3. <Third step — produce output>

## Checklist

- <Concrete item to check or do>
- <Another concrete item>

## Output Format

<How to structure the response — severity levels, sections, etc.>
```

______________________________________________________________________

## Frontmatter Reference

| Field             | Required | Default   | Purpose                                           |
| ----------------- | -------- | --------- | ------------------------------------------------- |
| `name`            | Yes      | —         | Unique ID (lowercase, hyphens), matches directory |
| `description`     | Yes      | —         | When Claude should delegate to this agent         |
| `tools`           | No       | All       | Allowlist of available tools                      |
| `disallowedTools` | No       | None      | Tools to deny from inherited set                  |
| `model`           | No       | `inherit` | `haiku`, `sonnet`, `opus`, or `inherit`           |
| `permissionMode`  | No       | `default` | Permission handling mode                          |
| `maxTurns`        | No       | —         | Max agentic turns before stopping                 |
| `skills`          | No       | None      | Skills to preload into the agent's context        |
| `mcpServers`      | No       | None      | MCP servers available to the agent                |
| `hooks`           | No       | None      | Lifecycle hooks scoped to this agent              |
| `memory`          | No       | None      | Persistent memory: `user`, `project`, or `local`  |

______________________________________________________________________

## Description Field — Good vs Bad

| Quality | Description                                                                            | Problem / Strength                        |
| ------- | -------------------------------------------------------------------------------------- | ----------------------------------------- |
| Bad     | `Helps with code`                                                                      | Too vague, no task or trigger             |
| Bad     | `Code quality agent`                                                                   | No "when", just a label                   |
| OK      | `Reviews code for quality`                                                             | Has task but no trigger                   |
| Good    | `Expert code reviewer. Use proactively after writing or modifying code.`               | Task + proactive trigger                  |
| Good    | `Debugging specialist for errors and test failures. Use when encountering any issues.` | Task + clear trigger condition            |
| Good    | `Generates comprehensive tests for existing code`                                      | Task implies trigger (after code written) |

______________________________________________________________________

## System Prompt — Good vs Bad

### Opening

```markdown
# Bad — too vague, no structure
Review code and find issues. Make it better.

# Good — role, workflow, specifics
You are a senior code reviewer ensuring high standards of quality and security.

When invoked:
1. Run git diff to see recent changes
2. Focus on modified files
3. Begin review immediately
```

### Checklists

```markdown
# Bad — generic, Claude already knows these
- Write clean code
- Follow best practices
- Handle errors properly

# Good — specific red flags to check
- Generic base exceptions instead of specific error types
- Exceptions with no structured context (just a message string)
- Async operations without timeout limits
- Batch operations that stop entirely on first failure
```

### Output Format

```markdown
# Bad — no structure specified
Tell me what you found.

# Good — clear format with severity
Provide feedback organized by priority:
- Critical issues (must fix)
- Warnings (should fix)
- Suggestions (consider improving)

For each finding, include the file and line, issue description, and fix.
Skip purely stylistic preferences with no impact on correctness.
```

______________________________________________________________________

## Tool Scoping Patterns

| Agent Type  | Recommended Tools               | Rationale                      |
| ----------- | ------------------------------- | ------------------------------ |
| Reviewer    | `Read, Grep, Glob, Bash`        | Read-only, no accidental edits |
| Researcher  | `Read, Grep, Glob, WebFetch`    | Exploration only               |
| Debugger    | `Read, Edit, Bash, Grep, Glob`  | Needs to fix code              |
| Test writer | `Read, Write, Bash, Grep, Glob` | Creates new test files         |
| Refactorer  | `Read, Edit, Bash, Grep, Glob`  | Modifies existing code         |
| Coordinator | `Task(worker, researcher)`      | Only spawns specific agents    |

For conditional restrictions, use hooks:

```yaml
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "./scripts/validate-command.sh"
```

______________________________________________________________________

## Advanced Features

### Persistent Memory

Use `memory` when the agent should learn across sessions:

```yaml
---
name: code-reviewer
memory: user  # Recommended default scope
---

As you review code, update your agent memory with patterns,
conventions, and recurring issues you discover.
```

| Scope     | Location                             | Use when                                 |
| --------- | ------------------------------------ | ---------------------------------------- |
| `user`    | `~/.claude/agent-memory/<name>/`     | Learnings apply across all projects      |
| `project` | `.claude/agent-memory/<name>/`       | Knowledge is project-specific, shareable |
| `local`   | `.claude/agent-memory-local/<name>/` | Project-specific, not version-controlled |

The agent auto-reads the first 200 lines of `MEMORY.md` in its memory
directory. Prompt the agent to consult and update its memory explicitly.

### Skill Preloading

Use `skills` to inject domain knowledge into the agent's context:

```yaml
---
name: api-developer
skills:
  - error-handling
  - testing-patterns
---

Implement API endpoints. Follow the patterns from the preloaded skills.
```

Skills are injected as full content, not just made available. Subagents
do not inherit skills from the parent conversation — list them explicitly.

______________________________________________________________________

## Review Checklist

Before shipping an agent, verify each item:

- [ ] `name:` is lowercase with hyphens, matches the directory name
- [ ] `description:` includes what + when (trigger terms present)
- [ ] System prompt opens with role and purpose (one sentence)
- [ ] Workflow steps are numbered and concrete
- [ ] Output format is specified
- [ ] Tools are scoped to minimum necessary (not all tools)
- [ ] Model matches the task (haiku for fast, sonnet for balanced, opus for complex)
- [ ] No fundamentals the model already knows
- [ ] Red flags / checklists use specific items, not vague goals
- [ ] Agent tested with a real task to verify delegation triggers

______________________________________________________________________

## Cross-Tool Compatibility

Agent definitions follow conventions that map across tools:

| Concept       | Claude Code                   | Cursor                      | AGENTS.md (Codex)               |
| ------------- | ----------------------------- | --------------------------- | ------------------------------- |
| Location      | `~/.claude/agents/`           | `.cursor/agents/`           | `AGENTS.md` per directory       |
| Format        | YAML frontmatter + markdown   | YAML frontmatter + markdown | Plain markdown                  |
| Trigger       | `description:` field          | `description:` field        | Always loaded (directory scope) |
| Tool control  | `tools:` / `disallowedTools:` | Tool restrictions in config | Sandbox-based                   |
| Model control | `model:` field                | Model selection in config   | Model selection in config       |
| Scope         | User or project level         | Project level               | Directory hierarchy             |

### Portable Patterns

- Role + workflow + checklist structure
- Numbered steps for the agent to follow
- Concrete red flags and items to check
- Severity-based output format
- Tool restrictions documented alongside the prompt

### Converting Between Formats

1. Keep the system prompt (body) unchanged — it works everywhere
1. Adapt frontmatter to the target tool's metadata format
1. For AGENTS.md (always loaded), move trigger context into prose
   since there's no description field for selective loading
