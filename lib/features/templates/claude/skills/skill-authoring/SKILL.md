---
description: Guidelines for writing high-quality Claude Code skills and AI agent instructions. Use when creating new skills, reviewing existing skills, or writing CLAUDE.md / rules files for any AI coding tool.
---

# Skill Authoring

**Detailed reference**: See `patterns.md` in this skill directory for a
copy-pasteable skill template, good/bad examples, a review checklist, and
cross-tool compatibility notes. Load it when writing or reviewing a skill.

## Skill Structure

- YAML frontmatter with `description:` — this is the trigger mechanism
- H1 title, H2 sections, bullet-point dominant format
- Companion files for detailed reference (one level deep only — no chains)
- Reference companions with: "See `file.md` — load it when \<specific situation>"

## Core Principles

- **Conciseness is survival** — every token competes with conversation context;
  shorter skills get retained longer in the context window
- **Assume competence** — only document what Claude doesn't already know;
  skip language fundamentals, standard library usage, common patterns
- **Specificity over generality** — concrete commands, real paths, real examples;
  "run `pytest tests/ -x`" not "run the test suite"
- **Progressive disclosure** — essential rules in SKILL.md, details in companions
- **Match freedom to fragility** — prescriptive for error-prone operations
  (git, deployment), flexible for creative work (naming, architecture)

## Writing Effective Content

- Lead with actionable instructions, not explanations
- Use bullet points over prose paragraphs
- Show good/bad examples with concrete code, not descriptions
- Include "When to Use" and "When NOT to Use" sections
- Every command must be copy-pasteable and work exactly as written
- Replace vague pronouns ("it", "this", "that") with specific terms

## Description Field (Critical)

The `description:` in frontmatter is the primary trigger for skill selection.
Claude uses it to decide which skills to load from potentially hundreds.

- Must include both WHAT the skill does AND WHEN to use it
- Write in third person ("Processes Excel files" not "I help with Excel")
- Include key terms users would mention when the skill should activate
- Keep under ~200 characters — long descriptions get truncated in selection

```yaml
# Bad — too vague, missing "when"
description: Helps with testing

# Bad — first person, no trigger context
description: I know how to write good tests for Python projects

# Good — what + when + key terms
description: Test-first development patterns and framework conventions. Use when writing tests, adding coverage, or setting up test infrastructure.
```

## Scoping

- One clear domain per skill — don't mix testing with deployment
- **Too broad**: covers everything, nothing is actionable (rarely triggers well)
- **Too narrow**: only applies to rare edge cases (rarely triggers at all)
- **Good scope**: a topic where Claude consistently needs project-specific guidance

## Anti-Patterns

- Explaining fundamentals Claude already knows (wastes context tokens)
- Vague instructions ("write clean code") instead of specific ones
  ("use Zod for request body validation in API handlers")
- Over-length skills that bury important information in noise
- Duplicating what linters, formatters, or the codebase already enforce
- Too many "don't" statements without positive alternatives
- Missing verification steps (how to confirm the skill worked)
- Deeply nested companion files referencing other companion files

## Companion Files

- Use when SKILL.md would exceed ~120 lines
- No YAML frontmatter — plain markdown only
- Open with a one-line purpose statement referencing SKILL.md
- Include checklists, decision tables, and worked examples
- SKILL.md must say when to load the companion (not just that it exists)

## Validation

Before shipping a skill, verify:

- **Cold-start test**: fresh session + only this skill + a task — does it work?
- **Trigger test**: does the skill activate for the right user requests?
- **Negative test**: does the skill stay silent for unrelated requests?
- **Iteration**: observe agent behavior, identify gaps, refine, retest
