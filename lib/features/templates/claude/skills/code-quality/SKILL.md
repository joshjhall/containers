---
description: Code quality standards and review checklist
---

# Code Quality

## Principles

- Prefer simple, readable code over clever code
- Follow existing codebase conventions
- Don't add unnecessary abstractions or over-engineer
- Only make changes that are directly requested or clearly necessary

## Review Checklist

- No security vulnerabilities (injection, XSS, credential exposure)
- Error handling at system boundaries (user input, external APIs)
- No hardcoded secrets or credentials
- Consistent naming conventions matching the project
- No dead code or unused imports
- No backwards-compatibility hacks for removed code

## Avoid

- Adding features, refactoring, or "improvements" beyond what was asked
- Adding docstrings, comments, or type annotations to unchanged code
- Adding error handling for scenarios that can't happen
- Creating helpers or abstractions for one-time operations
- Designing for hypothetical future requirements
