# Contributing to Container Build System

Thank you for your interest in contributing! This document provides guidelines
and best practices for contributing to this project.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Feature Script Guidelines](#feature-script-guidelines)
- [Error Handling](#error-handling)
- [Testing Requirements](#testing-requirements)
- [Code Style](#code-style)
- [Documentation](#documentation)
- [Pull Request Process](#pull-request-process)

______________________________________________________________________

## Getting Started

### Prerequisites

- Bash 4.0+
- Docker with BuildKit enabled
- Git
- shellcheck (recommended)

### Development Setup

1. Fork and clone the repository:

   ```bash
   git clone https://github.com/YOUR_USERNAME/containers.git
   cd containers
   ```

1. Run the development environment setup:

   ```bash
   ./bin/setup-dev-environment.sh
   ```

   This will:

   - Enable git hooks for shellcheck and credential leak prevention
   - Verify your development environment
   - Check for recommended tools

1. Create a feature branch:

   ```bash
   git checkout -b feature/your-feature-name
   ```

______________________________________________________________________

## Feature Script Guidelines

### Script Header Template

All feature scripts should follow this standardized header pattern:

```bash
#!/bin/bash
# Feature Name Installation
#
# Purpose: Brief description of what this feature installs
#
# Dependencies:
#   - List any required features or tools
#
# Environment Variables:
#   - VAR_NAME: Description (default: value)
#
# References:
#   - https://link-to-official-docs
#
# shellcheck disable=SC2034 # USERNAME used by sourced scripts

# Strict error handling
set -euo pipefail

# Source required utilities
source /tmp/build-scripts/base/feature-header.sh
source /tmp/build-scripts/base/logging.sh
source /tmp/build-scripts/base/download-verify.sh
source /tmp/build-scripts/base/apt-utils.sh

# Feature configuration
FEATURE_NAME="FeatureName"
log_feature_start
```

### Required Components

Every feature script MUST include:

1. **Shebang and header comments**: Describe purpose, dependencies, environment
   variables
1. **Error handling**: `set -euo pipefail` immediately after shebang/comments
1. **Source utilities**: Import required base scripts
1. **Logging calls**:
   - `log_feature_start` at the beginning
   - `log_feature_summary` before completion
   - `log_feature_end` at the end
1. **Environment variable exports**: Add to `/etc/bashrc.d/` for persistence
1. **Verification**: Test that installed tools work correctly
1. **Configuration summary**: Use `log_feature_summary` to show what was
   installed

### Feature Script Structure

```bash
#!/bin/bash
# Feature installation header...
set -euo pipefail

# 1. Source required utilities
source /tmp/build-scripts/base/feature-header.sh
source /tmp/build-scripts/base/logging.sh

# 2. Feature configuration
FEATURE_NAME="MyFeature"
log_feature_start

# 3. Install system dependencies
apt_install package1 package2

# 4. Download and verify binaries
download_and_verify "https://url" "checksum" "/dest/path"

# 5. Install feature-specific tools
# ... installation logic ...

# 6. Configure environment
cat > /etc/bashrc.d/50-myfeature.sh << 'EOF'
export MYFEATURE_HOME="/path"
export PATH="${MYFEATURE_HOME}/bin:$PATH"
EOF

# 7. Verify installation
if ! command -v mytool >/dev/null 2>&1; then
    log_error "mytool installation verification failed"
    return 1
fi

# 8. Log summary
log_feature_summary \
    --feature "MyFeature" \
    --version "${VERSION}" \
    --tools "tool1,tool2" \
    --paths "/path1,/path2" \
    --env "VAR1,VAR2" \
    --commands "cmd1,cmd2" \
    --next-steps "Run 'test-myfeature' to verify"

# 9. Complete
log_feature_end
```

______________________________________________________________________

## Error Handling

### Standard Error Handling

All scripts MUST use strict error handling:

```bash
set -euo pipefail
```

This ensures:

- `set -e`: Exit immediately if a command fails
- `set -u`: Treat unset variables as errors
- `set -o pipefail`: Fail on any command in a pipeline

### Error Messages

Use the logging framework for consistent error messages:

```bash
# Log errors with context
log_error "Failed to install package: ${package_name}"

# Log warnings for non-critical issues
log_warning "Cache directory not found, using defaults"

# Log info for progress updates
log_message "Downloading ${tool_name} version ${version}"
```

### Error Message Format

Error messages should follow this pattern:

```bash
# ✅ Good: Specific, actionable
log_error "Failed to download Go ${GO_VERSION}: curl returned exit code 7"

# ❌ Bad: Vague, no context
log_error "Download failed"
```

### Handling Expected Failures

For operations that may legitimately fail, handle errors explicitly:

```bash
# ✅ Good: Explicit error handling
if ! download_file "$url" "$dest"; then
    log_warning "Download from primary mirror failed, trying backup..."
    download_file "$backup_url" "$dest" || {
        log_error "All download mirrors failed"
        return 1
    }
fi

# ❌ Bad: Ignoring errors silently
download_file "$url" "$dest" || true
```

### Recovery Mechanisms

When implementing retry logic or fallbacks:

```bash
# Use retry utilities for network operations
if command -v retry_with_backoff >/dev/null 2>&1; then
    retry_with_backoff curl -fsSL "$url" -o "$dest"
else
    curl -fsSL "$url" -o "$dest"
fi

# Provide fallbacks for optional features
if ! install_optional_tool; then
    log_warning "Optional tool installation failed, continuing without it"
fi
```

### Cleanup on Failure

Use trap handlers for critical cleanup:

```bash
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Installation failed, cleaning up..."
        rm -f /tmp/build-artifacts/*
    fi
}
trap cleanup EXIT
```

### Exit Code Conventions

All scripts MUST use consistent exit codes to enable proper error handling and
testing.

#### Standard Exit Codes

| Exit Code | Meaning       | When to Use                                        |
| --------- | ------------- | -------------------------------------------------- |
| `0`       | Success       | Script completed successfully                      |
| `1`       | General error | Any failure (file not found, command failed, etc.) |
| `2`       | Usage error   | Invalid arguments or missing required parameters   |

**Note**: Feature scripts should typically **not** exit directly. Instead, they
should `return 1` to allow the caller (Dockerfile RUN command) to handle the
error.

#### Feature Scripts Pattern

Feature scripts are sourced during builds and should use `return` instead of
`exit`:

```bash
#!/bin/bash
# Feature script - uses return, not exit
set -euo pipefail

source /tmp/build-scripts/base/feature-header.sh
source /tmp/build-scripts/base/logging.sh

FEATURE_NAME="MyFeature"
log_feature_start

# ✅ Good: Use return for errors
if ! download_and_verify "$url" "$checksum" "$dest"; then
    log_error "Download failed"
    return 1
fi

# ✅ Good: Let set -e handle command failures
install_package some-package
configure_feature

log_feature_end
# Script completes successfully (implicit return 0)
```

#### Standalone Scripts Pattern

Standalone scripts in `bin/` can use `exit`:

```bash
#!/bin/bash
# Standalone script - can use exit
set -euo pipefail

# Parse arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <argument>" >&2
    exit 2  # Usage error
fi

# Perform operation
if ! perform_operation "$1"; then
    echo "Operation failed" >&2
    exit 1  # General error
fi

exit 0  # Explicit success (optional - implicit if reached end)
```

#### DO/DON'T

**DO**:

- ✅ Use `return 1` in feature scripts (they're sourced, not executed)
- ✅ Use `exit 0` only when explicitly needed (e.g., early success)
- ✅ Rely on `set -e` to automatically fail on command errors
- ✅ Capture `$?` immediately after a command if needed: `cmd; status=$?`
- ✅ Use exit code 2 for usage/argument errors in CLI scripts

**DON'T**:

- ❌ Don't use `exit` in feature scripts (use `return` instead)
- ❌ Don't test exit codes indirectly: `cmd; if [ $? -eq 0 ]` (use
  `if cmd; then`)
- ❌ Don't ignore exit codes: `cmd || true` (unless intentional)
- ❌ Don't use exit codes > 2 (keep it simple and consistent)

#### Testing Exit Codes

When testing scripts, verify both success and failure paths:

```bash
# Test success case
test_success_case() {
    run_script arg1 arg2
    assert_exit_code 0 "Should succeed with valid arguments"
}

# Test failure case
test_failure_case() {
    run_script invalid_arg
    assert_exit_code 1 "Should fail with invalid argument"
}

# Test usage error
test_missing_args() {
    run_script
    assert_exit_code 2 "Should return usage error when args missing"
}
```

______________________________________________________________________

## Testing Requirements

### Unit Tests

All new scripts in `bin/` and `lib/` MUST have unit tests:

```bash
# Create unit test file
tests/unit/bin/my-script.sh

# Use the test framework
source "$(dirname "${BASH_SOURCE[0]}")/../../framework.sh"
init_test_framework
test_suite "My Script Tests"

test_function_exists() {
    assert_command_exists my_function "Function should exist"
}

test_output_format() {
    local output
    output=$(my_script --option)
    assert_equals "expected" "$output" "Should match expected output"
}

run_test_suite
```

Run unit tests before committing:

```bash
./tests/run_unit_tests.sh
```

### Integration Tests

For new features, add integration tests:

```bash
# Create integration test
tests/integration/builds/test_myfeature.sh

# Test using the integration test framework (preferred)
./tests/run_integration_tests.sh myfeature

# Or use the quick feature test script
./tests/test_feature.sh myfeature
```

Run integration tests:

```bash
./tests/run_integration_tests.sh myfeature
```

### Test Coverage Expectations

- **Unit tests**: All public functions in utilities
- **Integration tests**: All feature installations
- **Edge cases**: Version resolution, partial downloads, network failures
- **Error paths**: Test that errors are properly handled

______________________________________________________________________

## Code Style

### Shell Script Style

Follow these conventions:

1. **Indentation**: 4 spaces (no tabs)
1. **Line length**: Maximum 100 characters
1. **Variable naming**:
   - `UPPERCASE_WITH_UNDERSCORES` for constants/environment variables
   - `lowercase_with_underscores` for local variables
1. **Function naming**: `verb_noun` pattern (e.g., `install_python`,
   `fetch_checksum`)

### Example

```bash
#!/bin/bash
# Good style example
set -euo pipefail

# Constants
readonly DOWNLOAD_URL="https://example.com/file.tar.gz"
readonly CHECKSUM="abc123..."

# Function with proper documentation
install_tool() {
    local version="$1"
    local dest_dir="$2"

    log_message "Installing tool version ${version} to ${dest_dir}"

    if download_and_verify "$DOWNLOAD_URL" "$CHECKSUM" "${dest_dir}/tool"; then
        log_message "Installation successful"
        return 0
    else
        log_error "Installation failed"
        return 1
    fi
}
```

### Comment Style

Use the standardized comment formatting:

```bash
# ============================================================================
# Section Header (80 characters wide)
# ============================================================================

# Subsection description
# Can span multiple lines

# Brief comment for single line
command

# Multi-line explanation:
# - Point 1
# - Point 2
# - Point 3
complex_command
```

### Shellcheck

All scripts MUST pass shellcheck:

```bash
shellcheck lib/features/my-feature.sh
```

Common shellcheck directives:

```bash
# Disable specific warnings with explanation
# shellcheck disable=SC2034 # Variable used in sourced script
VARIABLE_NAME="value"

# Disable for specific line
# shellcheck disable=SC2086
word_splitting_intended $variable
```

______________________________________________________________________

## Documentation

### Required Documentation

When adding new features:

1. **Update README.md**: Add feature to the feature list
1. **Update docs/reference/environment-variables.md**: Document any new variables
1. **Update examples/**: Add usage examples if applicable
1. **Add inline comments**: Explain complex logic

### Documentation Style

- Use Markdown for all documentation
- Keep language clear and concise
- Include practical examples
- Link to official documentation where relevant

### Commit Messages

Follow conventional commit format:

```text
<type>(<scope>): <subject>

<body>

<footer>
```

Types:

- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring
- `test`: Test additions/changes
- `chore`: Maintenance tasks

Example:

```text
feat(python): Add support for Python 3.14

- Updated version validation
- Added checksum fetching for 3.14 releases
- Updated default version in Dockerfile

Closes #123
```

______________________________________________________________________

## Pull Request Process

### Before Submitting

1. **Run all tests**:

   ```bash
   ./tests/run_all.sh
   ```

1. **Run shellcheck**:

   ```bash
   find lib bin -name "*.sh" -exec shellcheck {} +
   ```

1. **Update documentation**: Ensure all docs are up to date

1. **Create atomic commits**: Each commit should be a logical unit

1. **Write clear commit messages**: Follow the conventional commit format

### Pull Request Template

When creating a PR, include:

```markdown
## Description

Brief description of changes

## Type of Change

- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing

- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Shellcheck passes
- [ ] Manual testing performed

## Checklist

- [ ] Code follows style guidelines
- [ ] Comments added for complex logic
- [ ] Documentation updated
- [ ] Tests added for new functionality
- [ ] No credentials or secrets in code
```

### Review Process

1. Automated checks must pass (CI, shellcheck)
1. At least one maintainer review required
1. Address all feedback
1. Squash commits if requested
1. Maintainer will merge when approved

______________________________________________________________________

## Common Patterns

### Version Validation

```bash
# Use version-validation.sh for consistent validation
source /tmp/build-scripts/base/version-validation.sh
validate_version_format "$VERSION" || {
    log_error "Invalid version format: $VERSION"
    return 1
}
```

### Checksum Verification

```bash
# Always verify checksums for downloads
source /tmp/build-scripts/base/checksum-fetch.sh
checksum=$(fetch_github_sha256_file "$url.sha256")
download_and_verify "$url" "$checksum" "$dest"
```

### Debian Version Detection

```bash
# Use apt-utils for Debian version compatibility
source /tmp/build-scripts/base/apt-utils.sh

if is_debian_version 13; then
    # Trixie-specific installation
else
    # Older Debian versions
fi
```

### Cache Directory Setup

```bash
# Use consistent cache paths
readonly CACHE_DIR="/cache/toolname"
install -d -m 0755 -o "${USER_UID}" -g "${USER_GID}" "$CACHE_DIR"
```

______________________________________________________________________

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue with reproduction steps
- **Security**: See [SECURITY.md](SECURITY.md)
- **Documentation**: Check [docs/](docs/) directory

______________________________________________________________________

## Code of Conduct

Be respectful and constructive in all interactions. We aim to maintain a
welcoming community for all contributors.

______________________________________________________________________

## License

By contributing, you agree that your contributions will be licensed under the
same license as the project.
