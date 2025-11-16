# CHANGELOG Format Documentation

This document explains how the CHANGELOG.md is automatically generated and how
to write commits that produce useful changelog entries.

## Overview

The CHANGELOG.md is automatically generated using
[git-cliff](https://git-cliff.org/) based on conventional commit messages. The
`bin/release.sh` script regenerates it on each release.

## Commit Message Convention

We follow the [Conventional Commits](https://www.conventionalcommits.org/)
specification. Each commit message should be structured as:

```
<type>: <description>

[optional body]

[optional footer(s)]
```

### Commit Types

The following commit types are recognized and grouped in the CHANGELOG:

| Type        | CHANGELOG Section | Purpose                  | Example                                      |
| ----------- | ----------------- | ------------------------ | -------------------------------------------- |
| `feat:`     | **Added**         | New features             | `feat: Add Mojo language support`            |
| `add:`      | **Added**         | New additions            | `add: Add k9s to kubernetes tools`           |
| `fix:`      | **Fixed**         | Bug fixes                | `fix: Resolve checksum verification timeout` |
| `perf:`     | **Improved**      | Performance improvements | `perf: Optimize Docker layer caching`        |
| `refactor:` | **Changed**       | Code refactoring         | `refactor: Simplify user creation logic`     |
| `docs:`     | **Documentation** | Documentation changes    | `docs: Update Python version in README`      |
| `test:`     | **Testing**       | Test additions/changes   | `test: Add integration test for Rust`        |
| `chore:`    | **Miscellaneous** | Maintenance tasks        | `chore: Update dependencies`                 |
| `ci:`       | **CI/CD**         | CI/CD changes            | `ci: Add Debian 13 to test matrix`           |
| `build:`    | **Build**         | Build system changes     | `build: Update Docker base image`            |
| `revert:`   | **Reverted**      | Revert previous commit   | `revert: Undo feature X`                     |

**Special cases:**

- `chore(release):` commits are automatically **skipped** (not shown in
  CHANGELOG)
- Commits with `security` in the body are grouped under **Security** section

### Examples of Good Commit Messages

```bash
# New feature
feat: Add comparison mode to check-installed-versions.sh

Add --compare flag that only shows tools with version differences
(outdated or newer), making it easier to focus on actionable updates.

# Bug fix
fix: Replace tilde with $HOME in log_feature_summary paths

Fix SC2088 shellcheck warnings: tilde does not expand in quotes.
Replace ~/ with $HOME/ in --paths arguments.

# Documentation
docs: Add CHANGELOG format documentation

Document conventional commit format and git-cliff configuration
for automatic CHANGELOG generation.

# Security fix
fix: Prevent command injection in version validation

Add input sanitization to validate_version() function.

security: Addresses CVE-2024-XXXXX
```

### Breaking Changes

To mark a breaking change, add `BREAKING CHANGE:` or `!` after the type:

```bash
# Method 1: Using ! in commit type
feat!: Remove deprecated PYTHON2_VERSION build arg

BREAKING CHANGE: Python 2 is no longer supported.
Users must migrate to Python 3.

# Method 2: Using footer
feat: Redesign caching strategy

BREAKING CHANGE: Cache directory structure has changed.
Mount points must be updated in docker-compose.yml.
```

Breaking changes appear with `[**BREAKING**]` tag in CHANGELOG.

## Configuration (cliff.toml)

The CHANGELOG generation is configured in `cliff.toml`:

### Key Settings

- **Format**: Based on [Keep a Changelog](https://keepachangelog.com/)
- **Versioning**: Follows [Semantic Versioning](https://semver.org/)
- **Sorting**: Commits sorted by `oldest` first within each section
- **Tag Pattern**: Matches `v[0-9].*` (e.g., v4.7.0, v5.0.0)

### Commit Parsers

See the table above for how commit types map to CHANGELOG sections.

## How to Generate CHANGELOG

The CHANGELOG is automatically generated during the release process:

```bash
# Using the release script (recommended)
./bin/release.sh patch  # or minor, major, or specific version

# Manual generation (for testing)
git-cliff --tag v4.8.0 --output CHANGELOG.md
```

The `bin/release.sh` script:

1. Determines the next version number
2. Updates VERSION file and other version references
3. Generates CHANGELOG.md using git-cliff
4. Creates a git tag with the version

## Best Practices

### DO

✅ Use conventional commit format for all commits ✅ Write clear, descriptive
commit messages ✅ Reference issue numbers in commit body when applicable ✅
Group related changes in a single commit when appropriate ✅ Use imperative mood
("Add feature" not "Added feature")

### DON'T

❌ Use vague messages like "Fix stuff" or "Update files" ❌ Mix unrelated
changes in one commit ❌ Skip the type prefix (`feat:`, `fix:`, etc.) ❌ Use
past tense in commit messages ❌ Manually edit CHANGELOG.md (it's
auto-generated)

## Examples from This Project

### Good Examples

```bash
# Clear feature addition
feat: Add centralized cleanup handling for interrupted builds

# Specific bug fix with context
fix: Use install command for atomic sudo file creation

# Documentation improvement
docs: Update roadmap with Option C: Reliability completion
```

### Poor Examples (Don't do this)

```bash
# Too vague
update stuff

# Missing type
Add feature

# Past tense
fixed: Fixed the bug

# Mixed concerns
feat: Add feature X, fix bug Y, update docs
```

## Testing Your Commits

Before committing, you can preview how your commit will appear in the CHANGELOG:

```bash
# View what the next CHANGELOG would look like
git-cliff --unreleased
```

## Further Reading

- [Conventional Commits Specification](https://www.conventionalcommits.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [Semantic Versioning](https://semver.org/)
- [git-cliff Documentation](https://git-cliff.org/docs/)
