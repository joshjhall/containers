# Development & Contribution Guide

This directory contains guides for contributors working on the container build
system.

## Getting Started

1. Read [Code Style Guide](code-style.md) for conventions
2. Review [Testing Framework](testing.md) to understand test structure
3. Check [Changelog Conventions](changelog.md) for commit message format

## Available Guides

### Development Workflow

- [**Code Style Guide**](code-style.md) - Comment conventions, shell script
  style, best practices
- [**Testing Framework**](testing.md) - How to write and run tests
- [**Releasing**](releasing.md) - Version management and release process
- [**Changelog Conventions**](changelog.md) - Commit message format and
  CHANGELOG generation

## Development Setup

```bash
# Clone with full history for releases
git clone https://github.com/your-org/containers.git
cd containers

# Run all tests
./tests/run_all.sh

# Run specific test suite
./tests/run_unit_tests.sh
./tests/run_integration_tests.sh

# Test a specific feature
./tests/test_feature.sh python-dev
```

## Making Changes

### 1. Write Code

Follow the [Code Style Guide](code-style.md):

- Use consistent comment formatting
- Add proper error handling
- Include logging statements
- Document complex logic

### 2. Write Tests

Follow the [Testing Framework](testing.md):

- Unit tests for utilities and libraries
- Integration tests for feature installations
- Test edge cases and error conditions

### 3. Commit Changes

Follow [Changelog Conventions](changelog.md):

```bash
# Good commit messages
feat: Add Node.js 23 support
fix: Resolve Ruby checksum timeout issue
docs: Update Python version in README

# Run tests before committing
./tests/run_all.sh
```

### 4. Release

Follow the [Releasing Guide](releasing.md):

```bash
# Create a release
./bin/release.sh patch  # or minor, major

# Review and commit
git diff
git add -A
git commit -m "chore(release): Release version X.Y.Z"
git tag -a vX.Y.Z -m "Release version X.Y.Z"
git push origin main vX.Y.Z
```

## Testing Philosophy

- **Unit tests**: Fast, no Docker required, test individual functions
- **Integration tests**: Build actual containers, test real installations
- **Feature tests**: Quick smoke tests during development

See [Testing Framework](testing.md) for details.

## Release Process

We use semantic versioning and automated changelog generation:

- **Patch** (x.y.Z): Bug fixes, security updates
- **Minor** (x.Y.0): New features, backward compatible
- **Major** (X.0.0): Breaking changes

See [Releasing](releasing.md) for the complete process.

## Related Documentation

- [Architecture](../architecture/) - Design decisions and patterns
- [CI/CD](../ci/) - Continuous integration workflows
- [Reference](../reference/) - Technical specifications
