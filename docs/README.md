# Documentation Index

Welcome to the Container Build System documentation. This index helps you find
the right documentation for your needs.

## Quick Start

**New to the project?** Start with:

1. [Main README](../README.md) - Overview and quick start
1. [CLAUDE.md](../CLAUDE.md) - Working with the codebase
1. [Troubleshooting](troubleshooting.md) - Common issues and solutions

## User Documentation

Essential guides for building and using containers:

- **[Production Deployment](production-deployment.md)** - Production usage and
  best practices
- **[Migration Guide](migration-guide.md)** - Upgrading between versions
- **[Healthcheck](healthcheck.md)** - Health monitoring and validation
- **[Security Hardening](security-hardening.md)** - Security configuration and
  best practices
- **[Troubleshooting](troubleshooting.md)** - Common issues and solutions

## Documentation Categories

### [Architecture](architecture/)

Design decisions and technical analysis:

- [Architecture Review](architecture/review.md) - System architecture and design
  patterns
- [Caching Strategy](architecture/caching.md) - BuildKit cache optimization
- [Observability Design](architecture/observability.md) - Metrics, logging, and
  monitoring
- [Version Resolution](architecture/version-resolution.md) - Partial version
  resolution system

### [CI/CD](ci/)

Continuous integration and deployment:

- [GitHub CI Authentication](ci/authentication.md) - GitHub Actions
  authentication setup
- [Build Metrics](ci/build-metrics.md) - Image size and build time tracking

### [Development](development/)

Contributor and development guides:

- [Releasing](development/releasing.md) - Release process and versioning
- [Testing](development/testing.md) - Test framework and writing tests
- [Code Style](development/code-style.md) - Comment conventions and code
  standards
- [Changelog](development/changelog.md) - Commit message format and CHANGELOG
  generation

### [Observability](observability/)

Runtime monitoring and observability:

- [OpenTelemetry Integration](observability/opentelemetry-integration.md) -
  Complete OTel setup
- [Testing Strategy](observability/testing-strategy.md) - Observability testing
  approach
- [Runbooks](observability/runbooks/) - Incident response procedures

### [Operations](operations/)

Deployment and operational procedures:

- [Automated Releases](operations/automated-releases.md) - Weekly auto-patch
  system
- [Emergency Rollback](operations/rollback.md) - Rollback procedures

### [Reference](reference/)

Technical specifications and configuration:

- [Environment Variables](reference/environment-variables.md) - Build arguments
  and env vars
- [Feature Dependencies](reference/features.md) - Tool dependency matrix
- [Version Tracking](reference/versions.md) - Version pinning and update
  policies
- [Version Compatibility](reference/compatibility.md) - Platform compatibility
  matrix
- [Security Checksums](reference/security-checksums.md) - Checksum verification
  system

### [Troubleshooting](troubleshooting/)

Platform-specific troubleshooting:

- [Case-Sensitive Filesystems](troubleshooting/case-sensitive-filesystems.md) -
  Linux container filesystem issues
- [Docker for Mac](troubleshooting/docker-mac-case-sensitivity.md) -
  macOS-specific Docker issues

## Related Files

### Root Directory

- **[README.md](../README.md)** - Main project documentation
- **[CLAUDE.md](../CLAUDE.md)** - Development guide
- **[CHANGELOG.md](../CHANGELOG.md)** - Version history
- **[SECURITY.md](../SECURITY.md)** - Security policy
- **[LICENSE](../LICENSE)** - Project license

### Examples

- **[examples/](../examples/)** - Docker Compose configurations and examples
  - `env/*.env` - Environment variable templates
  - `contexts/` - Docker Compose patterns
  - `validation/` - Runtime configuration validation
  - `observability/` - Observability stack setup

## Finding What You Need

### I want to

#### Build a container

- Start: [Main README](../README.md)
- Configure:
  [Reference/Environment Variables](reference/environment-variables.md)
- Examples: [../examples/](../examples/)

#### Deploy to production

- Guide: [Production Deployment](production-deployment.md)
- Security: [Security Hardening](security-hardening.md)
- Health: [Healthcheck](healthcheck.md)

#### Upgrade versions

- Process: [Migration Guide](migration-guide.md)
- Compatibility: [Reference/Version Compatibility](reference/compatibility.md)

#### Contribute code

- Style: [Development/Code Style](development/code-style.md)
- Testing: [Development/Testing](development/testing.md)
- Releasing: [Development/Releasing](development/releasing.md)

#### Debug an issue

- Start: [Troubleshooting](troubleshooting.md)
- macOS:
  [Troubleshooting/Docker for Mac](troubleshooting/docker-mac-case-sensitivity.md)

#### Understand design decisions

- Overview: [Architecture/Review](architecture/review.md)
- Specific: Browse [Architecture/](architecture/) directory

## Contributing to Documentation

When updating documentation:

1. **Keep it current** - Update docs when code changes
1. **Cross-reference** - Link to related docs
1. **Use examples** - Show real commands and output
1. **Be concise** - Keep docs clear and focused
1. **Follow structure** - Use appropriate category directories

See [Development/Code Style](development/code-style.md) for style conventions.

## Getting Help

1. Check [Troubleshooting](troubleshooting.md) first
1. Search existing documentation using categories above
1. Check [CHANGELOG.md](../CHANGELOG.md) for recent changes
1. Review [GitHub Actions](https://github.com/joshjhall/containers/actions) for
   CI status
1. Create an issue at `https://github.com/joshjhall/containers/issues`

______________________________________________________________________

**Last Updated**: 2025-11-16 **Documentation Structure Version**: 2.0
