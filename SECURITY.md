# Security Policy

## Reporting a Vulnerability

The security of this project is taken seriously. If you discover a security vulnerability, please follow responsible disclosure practices:

### Reporting Process

**DO NOT** open a public GitHub issue for security vulnerabilities.

Instead, please report security issues via:

1. **GitHub Security Advisories** (preferred)
   - Navigate to the [Security tab](https://github.com/joshjhall/containers/security/advisories)
   - Click "Report a vulnerability"
   - Provide detailed information about the vulnerability

2. **Direct Contact**
   - Create a private issue via GitHub's vulnerability reporting feature
   - Include as much detail as possible

### What to Include

When reporting a vulnerability, please include:

- **Description**: Clear description of the vulnerability
- **Impact**: Potential impact and affected components
- **Reproduction**: Step-by-step instructions to reproduce
- **Affected Versions**: Which versions are affected
- **Suggested Fix**: If you have suggestions for remediation

### Response Timeline

- **Initial Response**: Within 48 hours of report submission
- **Status Update**: Within 7 days with assessment and timeline
- **Fix Deployment**: Varies by severity (see below)

### Severity Levels

- **Critical**: Fix within 7 days
- **High**: Fix within 30 days
- **Medium**: Fix within 90 days
- **Low**: Fix in next regular release

## Supported Versions

Security updates are provided for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| 4.x     | ✅ Yes             |
| 3.x     | ⚠️ Limited (critical only) |
| < 3.0   | ❌ No longer supported |

## Security Considerations for Users

### Container Security Context

This build system is designed primarily for **development environments**. When using in production:

- **Remove passwordless sudo**: Production containers should not have sudo access
- **Avoid Docker socket mounting**: Only mount `/var/run/docker.sock` in trusted dev environments
- **Use read-only filesystems**: Consider `--read-only` flag for production containers
- **Scan images regularly**: Use Trivy or similar tools to scan for vulnerabilities

### Docker Socket Security

Mounting the Docker socket (`/var/run/docker.sock`) grants **root-equivalent access** to the host system:

- ⚠️ **Development Use**: Appropriate for local dev environments where you need to manage dependency containers (databases, Redis, etc.)
- ❌ **Production Use**: Never mount the socket in production
- ❌ **Untrusted Code**: Never mount the socket when running untrusted code

See the [Docker Socket Usage section in README](README.md#docker-socket-usage) for detailed guidance.

### Secret Management

- **Never commit secrets**: Use `.env` files (gitignored) or 1Password CLI integration
- **Use 1Password CLI**: Feature flag `INCLUDE_OP=true` provides secure secret management
- **Rotate secrets regularly**: Especially for CI/CD tokens and service accounts

### Supply Chain Security

This project:
- ✅ Runs Gitleaks secret scanning in CI
- ✅ Runs Trivy container vulnerability scanning
- ✅ Uses GPG verification for critical packages
- ✅ Pins tool versions for reproducibility

However, be aware:
- Some installation scripts are downloaded from third-party sources
- Review the feature scripts in `lib/features/` before building
- Use official base images from trusted registries

## Security Update Process

When security vulnerabilities are reported and confirmed:

1. **Assessment**: Security team assesses severity and impact
2. **Fix Development**: Patch is developed in private branch
3. **Testing**: Full CI/CD pipeline validation
4. **Release**: Security release with CVE details (if applicable)
5. **Notification**: GitHub Security Advisory published
6. **Documentation**: CHANGELOG updated with security notes

## Known Security Considerations

### Automated Patch Releases

This project uses an automated weekly patch release system:

- Checks for updated tool versions every Sunday
- Automatically creates patch releases after CI validation
- **Review auto-patch changes**: Check auto-patch/* branches before they merge

### Build-Time Secrets

Be cautious about secrets in the build context:

- Docker `COPY` commands can include files from your project
- Create a `.dockerignore` file to exclude sensitive files
- Never use `ARG` for secrets (they're visible in image history)
- Use multi-stage builds to avoid embedding secrets

## Security Best Practices

When using this container system:

1. **Regularly update**: Keep submodule updated to latest version
2. **Scan your images**: Run `trivy image yourimage:tag` regularly
3. **Review build logs**: Check `check-build-logs.sh` for unexpected behavior
4. **Minimal privileges**: Use least-privilege principle for container runtime
5. **Network isolation**: Use Docker networks for container-to-container communication

## Security Testing

The project includes:

- **Secret Scanning**: Gitleaks in CI/CD
- **Vulnerability Scanning**: Trivy for containers
- **Code Quality**: Shellcheck for all shell scripts
- **Integration Tests**: Validation of all container variants

To run security scans locally:

```bash
# Run Gitleaks locally
docker run --rm -v $(pwd):/repo zricethezav/gitleaks:latest detect --source /repo

# Scan a built image with Trivy
trivy image myproject:dev --severity HIGH,CRITICAL

# Run shellcheck on scripts
find lib -name "*.sh" -exec shellcheck {} \;
```

## Contact

For security concerns that don't constitute vulnerabilities (questions, clarifications, etc.), you can:

- Open a regular GitHub issue with the `security` label
- Start a discussion in GitHub Discussions

For urgent security matters, use the vulnerability reporting process above.

---

**Last Updated**: 2025-11-09
**Security Policy Version**: 1.1
