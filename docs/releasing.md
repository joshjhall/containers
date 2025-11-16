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

The changelog is automatically generated using
[git-cliff](https://git-cliff.org/), which:

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

The "Unreleased" section can be manually edited. When you run the release
script, git-cliff will:

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

The release script will automatically install git-cliff if not found. You can
also install it manually:

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

## Security Releases

For releases focused on security improvements, follow these guidelines:

### When to Create a Security Release

Create a security-focused release when:

- Adding checksum verification to downloads
- Implementing GPG signature verification
- Fixing security vulnerabilities
- Adding security scanning (Trivy, Gitleaks)
- Hardening container configurations
- Addressing supply chain security

### Security Release Process

```bash
# For minor security improvements (patch)
./bin/release.sh patch

# For significant security features (minor)
./bin/release.sh minor

# Example: v4.5.0 added comprehensive checksum verification
./bin/release.sh minor
```

### Document Security Work

When creating a security release:

1. **Reference security documentation**:
   - Link to `docs/security-hardening.md` for roadmap items
   - Update `docs/checksum-verification.md` if adding verification
   - Document in CHANGELOG.md under "Security" or "Added" sections

2. **Example CHANGELOG entry** (from v4.5.0):

   ```markdown
   ### Added

   - Add checksum verification utilities for supply chain security
   - Add SHA256 checksum verification to golang.sh
   - Add GPG signature verification to AWS CLI v2 installation

   ### Documentation

   - Add SECURITY.md with vulnerability reporting procedures
   - Update checksum verification inventory
   ```

3. **Security release commit message**:

   ```bash
   git commit -m "chore(release): Release version 4.5.0

   Security improvements:
   - Complete checksum verification for all downloads (Phases 10-13)
   - Add GPG signature verification for AWS CLI
   - Document supply chain security measures

   See CHANGELOG.md for full details."
   ```

### Checklist for Security Releases

Before releasing security improvements:

- [ ] All security features tested in CI/CD
- [ ] Security documentation updated (SECURITY.md, security-hardening.md)
- [ ] CHANGELOG.md includes security improvements
- [ ] Related issues in security-hardening.md marked complete
- [ ] Tests cover new security features
- [ ] No security secrets in git history

### Example: v4.5.0 Security Release

Version 4.5.0 demonstrates a comprehensive security release:

**What was included**:

- Phases 10-13 of checksum verification (all downloads now verified)
- Dynamic checksum fetching for version flexibility
- GPG signature verification for AWS CLI
- Security documentation updates

**How it was released**:

```bash
# After completing all security work
./bin/release.sh minor  # 4.4.0 -> 4.5.0

# Review changes
git diff

# Commit with security context
git add -A
git commit -m "chore(release): Release version 4.5.0"

# Tag and push
git tag -a v4.5.0 -m "Release version 4.5.0 - Complete supply chain security"
git push origin main
git push origin v4.5.0
```

**CHANGELOG.md automatically captured**:

- 39 security-related commits
- References to docs/checksum-verification.md
- Links to security-hardening.md roadmap

### Security Hotfixes

For urgent security fixes:

```bash
# Create security hotfix branch
git checkout -b hotfix/security-CVE-2024-XXXX

# Make the fix
git commit -am "fix: Address CVE-2024-XXXX in tool installation"

# Patch release (highest priority)
./bin/release.sh patch

# Commit and tag
git add -A
git commit -m "chore(release): Security hotfix version 4.5.1

Fixes CVE-2024-XXXX by updating tool verification.

Security advisory: [link if public]"

git tag -a v4.5.1 -m "Security hotfix version 4.5.1"

# Push immediately
git push origin main
git push origin v4.5.1
```

### Related Security Documentation

- [Security Policy](../SECURITY.md) - Vulnerability reporting
- [Security Hardening Roadmap](./security-hardening.md) - Planned improvements
- [Checksum Verification](./checksum-verification.md) - Implementation guide
- [Troubleshooting: Security Issues](./troubleshooting.md#security--download-issues)

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
