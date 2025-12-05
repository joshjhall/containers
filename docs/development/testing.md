# Testing Framework Documentation

## Overview

The Container Build System includes a comprehensive testing framework with 850+
unit tests covering all library files. The framework is designed to test bash
scripts in isolation with proper mocking and assertion capabilities.

## Architecture

### Test Structure

```text
tests/
├── framework.sh           # Core testing framework with assertions
├── run_unit_tests.sh      # Main test runner
├── results/               # Test output and reports
└── unit/
    ├── base/             # Tests for base system scripts
    ├── bin/              # Tests for user-facing scripts
    ├── features/         # Tests for feature installation scripts
    └── runtime/          # Tests for runtime scripts
```

### Test File Conventions

- Test files mirror the structure of the lib directory
- Each lib file has a corresponding test file
- Test files are executable bash scripts
- Test files source the framework and follow a standard structure

## Writing Tests

### Basic Test Structure

```bash
#!/usr/bin/env bash
# Unit tests for lib/features/example.sh
# Tests example functionality

set -euo pipefail

# Source test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"

# Initialize test framework
init_test_framework

# Test suite
test_suite "Example Tests"

# Setup function - runs before each test
setup() {
    export TEST_TEMP_DIR="$RESULTS_DIR/test-example"
    mkdir -p "$TEST_TEMP_DIR"
}

# Teardown function - runs after each test
teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

# Test function
test_example_functionality() {
    # Test implementation
    assert_equals "expected" "actual" "Test description"
}

# Run tests with setup/teardown
run_test_with_setup() {
    local test_function="$1"
    local test_description="$2"

    setup
    run_test "$test_function" "$test_description"
    teardown
}

# Run all tests
run_test_with_setup test_example_functionality "Example functionality works"

# Generate test report
generate_report
```

## Available Assertions

The framework provides comprehensive assertion functions:

### Basic Assertions

- `assert_true <condition> [message]` - Assert condition is true
- `assert_false <condition> [message]` - Assert condition is false
- `assert_equals <expected> <actual> [message]` - Assert values are equal
- `assert_not_equals <expected> <actual> [message]` - Assert values are not
  equal

### String Assertions

- `assert_empty <value> [message]` - Assert string is empty
- `assert_not_empty <value> [message]` - Assert string is not empty
- `assert_contains <haystack> <needle> [message]` - Assert string contains
  substring
- `assert_not_contains <haystack> <needle> [message]` - Assert string doesn't
  contain substring

### File Assertions

- `assert_file_exists <path> [message]` - Assert file exists
- `assert_file_not_exists <path> [message]` - Assert file doesn't exist
- `assert_directory_exists <path> [message]` - Assert directory exists
- `assert_directory_not_exists <path> [message]` - Assert directory doesn't
  exist
- `assert_executable <path> [message]` - Assert file is executable

### Command Assertions

- `assert_command_exists <command> [message]` - Assert command is available
- `assert_command_not_exists <command> [message]` - Assert command is not
  available
- `assert_exit_code <expected> <actual> [message]` - Assert exit code matches

## Running Tests

### Run All Tests

```bash
./tests/run_unit_tests.sh
```

### Run Individual Test Suite

```bash
./tests/unit/features/python.sh
```

### Run with Verbose Output

```bash
./tests/run_unit_tests.sh --verbose
```

## Test Output

### Console Output

- Color-coded results (green for pass, red for fail, yellow for skip)
- Progress indicators for each test suite
- Summary statistics at the end

### Test Reports

Generated in `tests/results/`:

- Individual test reports: `test-report-YYYYMMDD-HHMMSS.txt`
- Summary reports: `unit-test-summary-YYYYMMDD-HHMMSS.txt`
- Test-specific output in subdirectories

## Mocking and Test Isolation

### Environment Variables

Tests run with isolated environment variables:

- `TEST_TEMP_DIR` - Temporary directory for test files
- `PROJECT_ROOT` - Path to project root
- `RESULTS_DIR` - Path to test results

### Mocking Functions

Create mock functions in setup to override real implementations:

```bash
setup() {
    # Mock a function
    mock_fetch_url() {
        echo "mocked response"
    }

    # Override PATH for testing
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}
```

### Filesystem Isolation

- Use `TEST_TEMP_DIR` for all file operations
- Clean up in teardown function
- Never modify actual system files

## Special Considerations

### Filesystem Permissions

Some tests check executable permissions which may not work correctly on certain
filesystems (e.g., fakeowner mounts in containers). Tests should detect and skip
appropriately:

```bash
test_executable_check() {
    # Check if filesystem handles permissions correctly
    local test_file="$TEST_TEMP_DIR/test"
    touch "$test_file"
    chmod 644 "$test_file"

    if [[ -x "$test_file" ]]; then
        skip_test "Filesystem doesn't handle executable permissions"
        return
    fi

    # Continue with test...
}
```

### Non-Interactive Testing

Tests must run non-interactively:

- No user input required
- No interactive commands (e.g., `git rebase -i`)
- Mock or skip interactive functionality

### Error Handling

- Tests should handle errors gracefully
- Use `|| true` to continue after expected failures
- Capture stderr when testing error conditions

## Best Practices

1. **Isolation**: Each test should be independent and not rely on others
1. **Cleanup**: Always clean up test artifacts in teardown
1. **Descriptive Names**: Use clear, descriptive test function names
1. **Meaningful Assertions**: Include descriptive messages with assertions
1. **Fast Execution**: Keep tests fast by avoiding unnecessary operations
1. **Deterministic**: Tests should produce consistent results
1. **Coverage**: Aim for comprehensive coverage of all code paths

## Continuous Integration

The test framework is designed to run in CI/CD pipelines:

- Exit code 0 for all tests passing
- Exit code 1 for any test failures
- Machine-parseable output in results directory
- No interactive prompts or manual intervention required

## Debugging Failed Tests

### Run Single Test with Debug Output

```bash
bash -x ./tests/unit/features/python.sh
```

### Check Test Reports

```bash
cat tests/results/test-report-*.txt
```

### Common Issues

1. **Permission Errors**: Ensure test files are executable
1. **Path Issues**: Use absolute paths or `$PROJECT_ROOT`
1. **Environment Pollution**: Check for unset variables in teardown
1. **Race Conditions**: Avoid time-dependent tests

## Contributing Tests

When adding new features or fixing bugs:

1. Write tests first (TDD approach)
1. Ensure tests fail initially
1. Implement the feature/fix
1. Verify tests pass
1. Check for regressions by running full test suite
1. Update test documentation if adding new patterns
