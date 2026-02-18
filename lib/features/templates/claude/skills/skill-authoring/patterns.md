# Skill Authoring — Patterns & Examples

Reference companion for `SKILL.md`. Load this when writing a new skill,
reviewing an existing skill, or adapting instructions for cross-tool
compatibility (Cursor rules, AGENTS.md, Windsurf rules).

______________________________________________________________________

## Skill Template

Copy-pasteable skeleton for a new skill:

```markdown
---
description: <What it does and when to use it — include key trigger terms>
---

# <Skill Name>

## <Primary Section>

- Actionable instruction with specific commands or patterns
- Another instruction with a concrete example

## When to Use

- Specific scenario where this skill applies
- Another scenario

## When NOT to Use

- Scenario where a different approach is better
- Edge case that looks relevant but isn't
```

______________________________________________________________________

## Description Field — Good vs Bad

| Quality | Description                                                                                                                     | Problem / Strength                   |
| ------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| Bad     | `Helps with Python`                                                                                                             | Too vague, no trigger context        |
| Bad     | `I help write better code`                                                                                                      | First person, no domain              |
| Bad     | `Everything about testing, CI, coverage, mocking, assertions, fixtures, parametrize, snapshots, and more`                       | Too long, unfocused                  |
| OK      | `Python testing patterns`                                                                                                       | Has domain but missing "when to use" |
| Good    | `Python testing patterns and pytest conventions. Use when writing tests, debugging test failures, or setting up test fixtures.` | What + when + key terms              |
| Good    | `Git commit conventions and branch naming. Use when committing, creating branches, or preparing pull requests.`                 | Clear scope, actionable triggers     |
| Good    | `Error handling patterns, retry strategies, and resilience guidance`                                                            | Specific domains, implies when       |

______________________________________________________________________

## Content — Good vs Bad Examples

### Instructions

```markdown
# Bad — vague, Claude already knows this
- Write clean, maintainable code
- Use meaningful variable names
- Follow best practices

# Good — specific, project-relevant
- Use Zod schemas for all API request validation
- Run `biome check --write .` before committing
- Place integration tests in `tests/integration/`, unit tests in `tests/unit/`
```

### Examples in Skills

```markdown
# Bad — describes what good code looks like without showing it
Use descriptive error messages that explain the problem.

# Good — shows concrete before/after
Error messages must include what failed and how to fix it:
  Bad:  "Invalid input"
  Good: "API key must be 32 hex characters, got 28: 'abc...xyz'"
```

### Commands

```markdown
# Bad — ambiguous, may not work
Run the linter to check your code.

# Good — copy-pasteable, exact
Run `eslint --fix src/` to auto-fix lint issues.
```

______________________________________________________________________

## Review Checklist

Before shipping a skill, verify each item:

- [ ] `description:` includes what AND when (trigger terms present)
- [ ] SKILL.md is under 120 lines
- [ ] Bullet points dominate over prose paragraphs
- [ ] Every command is copy-pasteable and tested
- [ ] No fundamentals Claude already knows (language basics, stdlib)
- [ ] "When to Use" section has concrete scenarios
- [ ] "When NOT to Use" section prevents false triggers
- [ ] Specific terms replace vague pronouns ("it", "this")
- [ ] Companion files (if any) are referenced with "load when" guidance
- [ ] No nested companion chains (one level max from SKILL.md)
- [ ] Anti-patterns include positive alternatives, not just negatives
- [ ] At least one good/bad example pair for the primary use case

______________________________________________________________________

## Cross-Tool Compatibility

Skills follow conventions that work across multiple AI coding tools.
Adapting between them requires minimal changes:

| Concept  | Claude Code                 | Cursor                    | Windsurf         | AGENTS.md               |
| -------- | --------------------------- | ------------------------- | ---------------- | ----------------------- |
| Location | `~/.claude/skills/`         | `.cursor/rules/`          | `.windsurfrules` | `AGENTS.md`             |
| Format   | YAML frontmatter + markdown | Markdown (with metadata)  | Markdown         | Plain markdown          |
| Trigger  | `description:` field        | `globs:` / `description:` | Manual or auto   | Always loaded           |
| Scope    | Per-user or per-project     | Per-project               | Per-project      | Per-directory           |
| Nesting  | Companion files (1 level)   | Separate rule files       | Single file      | Per-directory hierarchy |

### Portable Patterns (work everywhere)

- Bullet-point instructions with specific commands
- Good/bad example pairs
- "When to Use" / "When NOT to Use" sections
- Tables for decision criteria
- Concrete file paths and real code examples

### Tool-Specific Patterns

- **Claude Code**: YAML frontmatter `description:` is critical for triggering
- **Cursor**: `globs:` patterns control which files activate the rule
- **Windsurf**: Single file, so brevity and prioritization are essential
- **AGENTS.md**: Always loaded in its directory scope — keep tightly scoped

### Converting Between Formats

When adapting a Claude skill to another tool:

1. Keep the core instructions and examples unchanged
1. Remove YAML frontmatter (replace with tool-specific metadata)
1. Adjust file paths if the tool uses different conventions
1. For single-file formats (Windsurf), merge companion content inline
   and cut aggressively for length
