# Production Deployment Guide

This guide covers best practices and considerations for deploying containers
built with this system to production environments.

**Important**: This container build system is designed primarily for
**development environments**. For production deployments, additional hardening
and optimization is required.

## Development vs Production

| Aspect            | Development                 | Production                    |
| ----------------- | --------------------------- | ----------------------------- |
| **User**          | Non-root with sudo          | Non-root, NO sudo             |
| **Secrets**       | Can be in env vars          | Must use secrets management   |
| **Image Size**    | Larger (includes dev tools) | Minimized (only runtime deps) |
| **Updates**       | Frequent                    | Controlled, tested            |
| **Logging**       | Verbose                     | Structured, minimal           |
| **Health Checks** | Optional                    | Required                      |

## Detailed Guides

| Guide                                                      | Description                                                               |
| ---------------------------------------------------------- | ------------------------------------------------------------------------- |
| [Security Hardening](production/security-hardening.md)     | Disable sudo, non-root user, read-only filesystem, capabilities, scanning |
| [Image Optimization](production/image-optimization.md)     | Feature selection, multi-stage builds, layer optimization                 |
| [Runtime & Resources](production/runtime-and-resources.md) | Environment variables, config validation, memory/CPU/IO limits            |
| [Secrets & Health](production/secrets-and-health.md)       | Docker/K8s secrets, 1Password, Vault, health checks, probes               |
| [Deployment Platforms](production/deployment-platforms.md) | Logging, registries, Docker Compose, Kubernetes, AWS ECS/Fargate          |

## Production Readiness Checklist

### Security

- [ ] Passwordless sudo disabled (`ENABLE_PASSWORDLESS_SUDO=false`)
- [ ] Running as non-root user
- [ ] No secrets in build arguments or ENV in Dockerfile
- [ ] Secrets management system in place
- [ ] Image scanned for vulnerabilities
- [ ] Security updates applied
- [ ] Read-only root filesystem (if applicable)
- [ ] Capabilities dropped to minimum required

### Optimization

- [ ] Only necessary features included (no dev tools)
- [ ] Multi-stage build for minimal size
- [ ] Layers optimized
- [ ] Base image regularly updated
- [ ] Image tagged with version, not just `latest`

### Reliability

- [ ] Health check endpoint implemented
- [ ] Liveness and readiness probes configured
- [ ] Resource limits set (memory, CPU)
- [ ] Restart policy configured
- [ ] Graceful shutdown handling
- [ ] Logging to stdout/stderr
- [ ] Structured logging format

### Monitoring

- [ ] Metrics exposed (Prometheus format)
- [ ] Centralized logging configured
- [ ] Alerts configured for critical metrics
- [ ] APM/tracing integrated (optional)

### Deployment

- [ ] CI/CD pipeline for builds
- [ ] Automated testing before deployment
- [ ] Blue-green or canary deployment strategy
- [ ] Rollback procedure documented
- [ ] Image pushed to production registry
- [ ] Image signing enabled (optional)

### Documentation

- [ ] Production configuration documented
- [ ] Runbook for common issues
- [ ] Secrets management documented
- [ ] Deployment procedure documented

## Additional Resources

- [Security Best Practices](security-hardening.md) - Comprehensive security
  guide
- [Environment Variables](reference/environment-variables.md) - Configuration
  reference
- [Troubleshooting](troubleshooting.md) - Common issues and solutions
- [CLAUDE.md](../CLAUDE.md) - Build system overview
