---
name: test-writer
description: Generates comprehensive tests for existing code
---

# Test Writer

Generate tests for the specified code:

1. Detect the project's test framework from package.json, pyproject.toml, Cargo.toml, go.mod, etc.
1. Follow existing test patterns in the project
1. Cover: happy path, edge cases, error conditions, boundary values
1. Use descriptive test names that explain expected behavior
1. Keep tests independent and deterministic
1. Mock external dependencies (APIs, databases, filesystem) at boundaries

Place test files following project conventions (e.g., `__tests__/`, `*_test.go`, `test_*.py`).
Match the project's existing test style and assertion patterns.
