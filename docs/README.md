# Documentation Index

Welcome to the Container Build System documentation. This index helps you find the right documentation for your needs.

## Quick Navigation

**New to the project?** Start with:
1. [Main README](../README.md) - Overview and quick start
2. [CLAUDE.md](../CLAUDE.md) - Working with the codebase
3. [Troubleshooting](troubleshooting.md) - Common issues and solutions

**Building and releasing?**
- [Releasing](releasing.md) - Release process and versioning
- [Version Tracking](version-tracking.md) - Tool version management
- [Automated Patch Releases](automated-patch-releases.md) - Weekly automation

**Need help?**
- [Troubleshooting](troubleshooting.md) - Comprehensive troubleshooting guide

---

## Build & Release

### [Releasing](releasing.md)
Complete guide to the release process, including version bumping, CHANGELOG generation, and CI/CD automation. Includes section on security releases.

**Key topics**: release.sh script, semantic versioning, git-cliff, security releases

### [Version Tracking](version-tracking.md)
Documents which tool versions are pinned vs. using latest, and how the version tracking system works.

**Key topics**: version-updates.json, check-versions.sh, update-versions.sh

### [Automated Patch Releases](automated-patch-releases.md)
How the weekly automated patch release system works, including the auto-patch workflow and version update automation.

**Key topics**: auto-patch branches, version checking, CI/CD automation

---

## Security

### [Checksum Verification](checksum-verification.md) ✅ COMPLETE
**Status**: Historical reference and implementation guide

Complete audit of checksum verification across all downloads. Documents the security work completed in v4.5.0.

**Key topics**: download-verify.sh, checksum-fetch.sh, supply chain security

### [Configuration Validation Examples](../examples/validation/README.md) ✅ COMPLETE
**Status**: Production-ready validation framework

Runtime configuration validation system with environment variable validation, format checking, and secret detection. Includes complete examples for web apps, API services, and background workers.

**Key topics**: Runtime validation, environment variable checking, secret detection, custom validation rules

### [GitHub CI Authentication](github-ci-authentication.md)
Authentication setup for GitHub Actions, including tokens, PATs, and OIDC for Cosign image signing.

**Key topics**: GITHUB_TOKEN, PAT setup, Cosign OIDC, id-token permissions

---

## Testing & Development

### [Testing Framework](testing-framework.md)
Comprehensive testing guide covering unit tests, integration tests, and the test framework architecture.

**Key topics**: run_all.sh, test assertions, Docker testing, feature tests

### [Troubleshooting](troubleshooting.md)
Extensive troubleshooting guide for build issues, runtime problems, security issues, and CI/CD failures.

**Key topics**:
- Debian version compatibility
- Build failures
- Security & download issues (checksum, GPG verification)
- Feature-specific issues
- Debugging tools

---

## Architecture & Design

### [Architecture Review](architecture-review.md)
Deep dive into the modular architecture, including feature scripts, caching strategy, and design decisions.

**Key topics**: Feature modularity, BuildKit caching, logging utilities

### [Comment Style Guide](comment-style-guide.md)
Guidelines for code documentation and comment formatting throughout the codebase.

**Key topics**: Comment conventions, documentation standards

### [Partial Version Resolution Analysis](partial-version-resolution-analysis.md)
Technical analysis of partial version resolution support for Ruby and Go runtimes.

**Key topics**: Version flexibility, semantic versioning, runtime installation

---

## Subdirectories

### [archived/](archived/)
Completed work and historical documents preserved as reference.

**Contains**:
- `mojo-deprecation-notice.md` - Archived Mojo installation documentation (unsupported)

### [planned/](planned/)
Design documents and roadmaps for features not yet implemented.

**Contains**:
- `security-hardening.md` - Security hardening roadmap (16 planned improvements)
- `security-and-init-system.md` - Security scanning system design
- `security-scan-quick-reference.md` - Quick reference for planned security tools

---

## Related Files

### Root Directory

- **[README.md](../README.md)** - Main project documentation and quick start guide
- **[CLAUDE.md](../CLAUDE.md)** - Development guide for working with this codebase
- **[CHANGELOG.md](../CHANGELOG.md)** - Version history and release notes
- **[SECURITY.md](../SECURITY.md)** - Security policy and vulnerability reporting
- **[LICENSE](../LICENSE)** - Project license

### Examples

- **[examples/](../examples/)** - Docker Compose configurations and environment examples
  - `env/*.env` - Environment variable templates for each feature
  - `contexts/` - Docker Compose patterns
  - `validation/` - Runtime configuration validation examples (web apps, API services, workers)

---

## Documentation Lifecycle

Documents move through these states:

1. **Planned** ([planned/](planned/)) - Features designed but not implemented
2. **Active** (docs/) - Current features and processes
3. **Archived** ([archived/](archived/)) - Completed work preserved as reference

---

## Contributing to Documentation

When updating documentation:

1. **Keep it current** - Update docs when code changes
2. **Cross-reference** - Link to related docs
3. **Use examples** - Show real commands and output
4. **Status markers** - Use ✅ COMPLETE, 🔴 NOT STARTED, etc. for clarity
5. **Archive when done** - Move completed work to archived/

See [comment-style-guide.md](comment-style-guide.md) for style conventions.

---

## Getting Help

1. Check [Troubleshooting](troubleshooting.md) first
2. Search existing documentation using the navigation above
3. Check [CHANGELOG.md](../CHANGELOG.md) for recent changes
4. Review [GitHub Actions](https://github.com/joshjhall/containers/actions) for CI status
5. Create an issue at https://github.com/joshjhall/containers/issues

---

**Last Updated**: 2025-11-09
**Documentation Structure Version**: 1.0
