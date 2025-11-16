# Operations & Deployment

This directory contains operational guides for managing and deploying the
container build system.

## Available Guides

- [**Automated Releases**](automated-releases.md) - Weekly auto-patch system for
  version updates
- [**Emergency Rollback**](rollback.md) - How to rollback when things go wrong

## Operational Workflows

### Automated Patch Releases

The system includes an automated weekly workflow that:

- Runs every Sunday at 2am UTC
- Checks for updated tool versions
- Creates auto-patch branches
- Runs full CI pipeline
- Auto-merges on success

See [Automated Releases](automated-releases.md) for details.

### Rollback Procedures

When issues are detected in production:

1. Review [Emergency Rollback](rollback.md) guide
2. Identify the problematic version
3. Rollback to last known good version
4. Create incident report
5. Fix root cause

## Production Deployment

For production deployment best practices, see:

- [Production Deployment Guide](../production-deployment.md) (root docs)
- [Migration Guide](../migration-guide.md) (root docs)

## Monitoring & Health

For runtime monitoring and health checks:

- [Healthcheck Guide](../healthcheck.md) (root docs)
- [Observability Design](../architecture/observability.md)
- [Observability Integration](../observability/) (observability directory)

## Security Operations

For security-related operations:

- [Security Hardening](../security-hardening.md) (root docs)
- [Security Checksums](../reference/security-checksums.md)

## Related Documentation

- [CI/CD](../ci/) - Build automation and metrics
- [Reference](../reference/) - Environment variables and configuration
- [Architecture](../architecture/) - System design
