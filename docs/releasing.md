# Releasing

This document describes the release process for the Container Build System.

## Overview

Releases are managed through the `bin/release.sh` script, which automates:
- Version bumping (semantic versioning)
- CHANGELOG.md generation (using git-cliff)
- Updating version references across the codebase
- Providing git commands for tagging and publishing

## Quick Start

```bash
# Patch release (4.0.0 -> 4.0.1)
./bin/release.sh patch

# Minor release (4.0.0 -> 4.1.0)
./bin/release.sh minor

# Major release (4.0.0 -> 5.0.0)
./bin/release.sh major

# Specific version
./bin/release.sh 4.1.0
```

## Release Script Options

```bash
./bin/release.sh [OPTIONS] [major|minor|patch|VERSION]

Options:
  --force              Force version update even if same
  --skip-changelog     Skip CHANGELOG.md generation
  --non-interactive    Skip confirmation prompts (for CI/CD)

Examples:
  ./bin/release.sh patch                    # Bump patch version
  ./bin/release.sh --non-interactive minor  # Run without prompts
  ./bin/release.sh --skip-changelog 4.1.0   # Manual changelog
```

## What Gets Updated

The release script automatically updates:

1. **VERSION** - The version file read by CI/CD
2. **Dockerfile** - Version comment at the top
3. **tests/framework.sh** - Test framework version constant
4. **CHANGELOG.md** - Generated from git commits (unless `--skip-changelog`)

## CHANGELOG Generation

The changelog is automatically generated using [git-cliff](https://git-cliff.org/), which:

- Parses conventional commit messages
- Groups changes by type (Added, Fixed, Changed, etc.)
- Generates links to compare releases
- Preserves manual edits in the "Unreleased" section

### Commit Message Format

For best changelog results, use conventional commit format:

```
feat: Add new feature
fix: Fix bug in golang-dev
docs: Update README
ci: Enable all test variants
chore: Update dependencies
```

### Manual CHANGELOG Edits

The "Unreleased" section can be manually edited. When you run the release script, git-cliff will:
- Generate new sections from git history
- Preserve your manual additions
- Create proper version sections and links

## Complete Release Process

### 1. Prepare the Release

```bash
# Run the release script
./bin/release.sh patch

# Review the changes
git diff
```

### 2. Commit and Tag

```bash
# Commit all changes
git add -A
git commit -m "chore(release): Release version 4.0.1"

# Create annotated tag
git tag -a v4.0.1 -m "Release version 4.0.1"
```

### 3. Push to GitHub

```bash
# Push commits
git push origin main

# Push tag (triggers CI/CD release workflow)
git push origin v4.0.1
```

### 4. CI/CD Automation

When you push a tag (e.g., `v4.0.1`), GitHub Actions will:

1. **Build all container variants**:
   - minimal
   - python-dev
   - node-dev
   - cloud-ops
   - polyglot
   - rust-golang

2. **Push images to GitHub Container Registry**:
   - `ghcr.io/joshjhall/containers:minimal-v4.0.1`
   - `ghcr.io/joshjhall/containers:python-dev-v4.0.1`
   - `ghcr.io/joshjhall/containers:node-dev-v4.0.1`
   - `ghcr.io/joshjhall/containers:cloud-ops-v4.0.1`
   - `ghcr.io/joshjhall/containers:polyglot-v4.0.1`
   - `ghcr.io/joshjhall/containers:rust-golang-v4.0.1`

3. **Create GitHub Release**:
   - Extracts release notes from CHANGELOG.md
   - Attaches build artifacts
   - Links to container images

## Versioning Strategy

We follow [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR** (X.0.0): Breaking changes, incompatible API changes
- **MINOR** (x.X.0): New features, backwards-compatible
- **PATCH** (x.x.X): Bug fixes, backwards-compatible

### Examples

- **Patch** (4.0.0 → 4.0.1): Fix golang-dev linker issue
- **Minor** (4.0.0 → 4.1.0): Add Java language support
- **Major** (4.0.0 → 5.0.0): Change base image to Ubuntu

## Installing git-cliff

The release script will automatically install git-cliff if not found. You can also install it manually:

```bash
# Using cargo (recommended)
cargo install git-cliff

# Using pre-built binary (Linux/macOS)
curl -sL https://github.com/orhun/git-cliff/releases/download/v2.8.0/git-cliff-2.8.0-x86_64-unknown-linux-gnu.tar.gz | tar xz
sudo mv git-cliff-*/git-cliff /usr/local/bin/

# Using Homebrew (macOS)
brew install git-cliff
```

## Manual CHANGELOG Updates

If you prefer to update the changelog manually:

```bash
# Skip automatic generation
./bin/release.sh --skip-changelog patch

# Edit CHANGELOG.md manually
vim CHANGELOG.md

# Then commit and tag as usual
```

## CI/CD Integration

For automated releases from CI/CD:

```bash
# Non-interactive mode (no prompts)
./bin/release.sh --non-interactive patch
```

This is useful for:
- Automated version bumps
- Scheduled releases
- Integration with other automation tools

## Hotfix Releases

For urgent fixes:

```bash
# Create hotfix branch
git checkout -b hotfix/critical-fix

# Make your fix and commit
git commit -am "fix: Critical security issue"

# Create patch release
./bin/release.sh patch

# Commit and tag
git add -A
git commit -m "chore(release): Hotfix version 4.0.1"
git tag -a v4.0.1 -m "Hotfix version 4.0.1"

# Push to trigger release
git push origin main
git push origin v4.0.1
```

## Troubleshooting

### git-cliff Installation Fails

If automatic installation fails:

```bash
# Install manually
cargo install git-cliff

# Or skip changelog generation
./bin/release.sh --skip-changelog patch
```

### Version Already Exists

```bash
# Force update (use with caution)
./bin/release.sh --force 4.0.1
```

### Uncommitted Changes

The script warns about uncommitted changes but doesn't block. Best practice:

```bash
# Stash changes before releasing
git stash

# Run release
./bin/release.sh patch

# Apply stash after
git stash pop
```

## Related Documentation

- [Automated Patch Releases](./automated-patch-releases.md) - Weekly automation
- [CI/CD Pipeline](../.github/workflows/ci.yml) - GitHub Actions configuration
- [Keep a Changelog](https://keepachangelog.com/) - Changelog format
- [Semantic Versioning](https://semver.org/) - Version numbering
- [git-cliff Documentation](https://git-cliff.org/) - Changelog generation tool
