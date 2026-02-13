---
description: Testing patterns and test-first development guidance
---

# Testing Patterns

## Approach

- Write tests before or alongside implementation
- Test behavior, not implementation details
- Keep tests focused and independent
- Each test should be understandable in isolation

## Structure

- Arrange-Act-Assert pattern
- One assertion concept per test
- Descriptive test names explaining expected behavior
- Group related tests logically

## Coverage

- Test happy path, edge cases, and error conditions
- Test boundary values and empty/null inputs
- Don't test framework or library internals
- Integration tests for critical paths and system boundaries

## Practices

- Tests should be deterministic and repeatable
- Mock external dependencies at boundaries (APIs, databases, filesystem)
- Use the project's existing test framework and patterns
- Place test files following project conventions
- Clean up test state; don't depend on test execution order
