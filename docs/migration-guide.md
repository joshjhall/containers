# Migration Guide

This guide helps you upgrade between major versions of the container build
system when used as a git submodule in your projects.

## Table of Contents

- [Overview](#overview)
- [Current Version](#current-version)
- [Upgrade Paths](#upgrade-paths)
- [Breaking Changes by Version](#breaking-changes-by-version)
- [Migration Procedures](#migration-procedures)
- [Testing Your Migration](#testing-your-migration)
- [Rollback Procedures](#rollback-procedures)

______________________________________________________________________

## Overview

This container build system follows [Semantic Versioning](https://semver.org/):

- **MAJOR version** (X.0.0): Breaking changes that require migration
- **MINOR version** (4.X.0): New features, backward compatible
- **PATCH version** (4.5.X): Bug fixes, backward compatible

### Version Support Policy

- **Latest stable**: Fully supported with security updates
- **Previous minor**: Security fixes only
- **Older versions**: No support, upgrade recommended

______________________________________________________________________

## Current Version

**Latest Stable**: v4.12.1 (2025-11-30)

Check your current version:

````bash
# From your project root
cat containers/VERSION

# Or check git submodule commit
cd containers && git describe --tags
```text

---

## Upgrade Paths

### Recommended Upgrade Paths

```text
v3.x → v4.0.0 → v4.12.x (current)
v4.0.x → v4.12.x (direct upgrade)
v4.1.x → v4.12.x (direct upgrade)
v4.5.x → v4.12.x (direct upgrade)
```

**Best Practice**: Always upgrade through major versions sequentially (v3 → v4 →
v5), not skipping major versions.

---

## Breaking Changes by Version

### v4.0.0 (Major Release)

**Date**: 2024-XX-XX

#### Breaking Changes

1. **Debian Trixie (13) Support Added**
   - **Impact**: Builds on Debian 13 use new GPG key management
   - **Migration**: Automatic - scripts detect Debian version
   - **Action Required**: None if using default base images

1. **apt-key Deprecation Handling**
   - **Impact**: Features using apt repositories (terraform, gcloud, kubernetes)
     changed
   - **Migration**: Automatic version detection
   - **Action Required**: Rebuild images if locked to old Debian versions

1. **Python Installation Method Changed**
   - **Impact**: Switched from pyenv to direct source installation
   - **Migration**: Simplified installation, same user experience
   - **Action Required**: None - environment variables remain compatible

#### New Features (v4.0+)

- Debian 11, 12, and 13 (Trixie) support
- Improved cache strategy
- Enhanced security hardening
- Health check system

#### Deprecations

- ❌ pyenv for Python (removed)
- ❌ rbenv for Ruby (removed)
- ❌ Legacy apt-key commands (automatic fallback)

---

### v4.5.0 → v4.7.0 (Minor Upgrades)

**No Breaking Changes** - Safe direct upgrade

#### Notable Additions

- Container healthcheck system (`bin/healthcheck.sh`)
- Retry logic with exponential backoff
- Comprehensive documentation improvements
- Security hardening enhancements

#### Action Required

- **Optional**: Add HEALTHCHECK to your Dockerfile
- **Optional**: Use new healthcheck features
- **Recommended**: Review new security documentation

---

## Migration Procedures

### Upgrading the Submodule

#### Step 1: Check Current Version

```bash
cd /path/to/your/project
cd containers
git describe --tags
# Output: v4.5.0 (example)
```text

#### Step 2: Review Release Notes

Before upgrading, review the [CHANGELOG.md](../CHANGELOG.md) for your target
version.

#### Step 3: Update Submodule

```bash
cd containers

# Fetch latest tags
git fetch --tags

# Check available versions
git tag --sort=-v:refname | head -10

# Checkout desired version (example: v4.7.0)
git checkout v4.7.0

# Return to project root
cd ..

# Commit the submodule update
git add containers
git commit -m "chore: Upgrade container build system to v4.7.0"
```text

#### Step 4: Rebuild Images

```bash
# Clear Docker cache to ensure clean build
docker builder prune -af

# Rebuild your development image
docker build -t myproject:dev \
  -f containers/Dockerfile \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_NODE=true \
  .

# Test the new image
docker run --rm myproject:dev python3 --version
docker run --rm myproject:dev node --version
```text

#### Step 5: Update CI/CD (if applicable)

```yaml
# .github/workflows/build.yml example
- name: Checkout code
  uses: actions/checkout@v4
  with:
    submodules: recursive # Ensure submodules are checked out

- name: Build container
  run: docker build -t test:latest .
```text

---

## Version-Specific Migration Instructions

### Migrating from v3.x to v4.0+

#### Pre-Migration Checklist

- [ ] Review all custom build arguments in your Dockerfiles
- [ ] Check if you're using pyenv or rbenv (removed in v4.0)
- [ ] Verify base image (default is now debian:trixie-slim)
- [ ] Back up current working images

#### Migration Steps

1. **Update Base Image Reference**

```dockerfile
# Old (v3.x)
FROM mcr.microsoft.com/devcontainers/base:bookworm

# New (v4.0+)
FROM mcr.microsoft.com/devcontainers/base:trixie
```text

1. **Remove pyenv/rbenv References**

If you have custom scripts or configurations referencing pyenv or rbenv:

```bash
# Old - NO LONGER NEEDED
export PYENV_ROOT="/opt/pyenv"
pyenv global 3.11.0

# New - Direct installation
python3 --version  # Already at specified version
```text

1. **Update Build Arguments (if customized)**

No changes required - all build arguments remain compatible.

1. **Test Migration**

```bash
# Build with v4.0+
docker build -t myproject:test-v4 .

# Verify installations
docker run --rm myproject:test-v4 check-installed-versions.sh

# Compare with v3.x image
docker run --rm myproject:old check-installed-versions.sh
```text

#### Known Issues and Solutions

**Issue**: Build fails with "apt-key: command not found"

- **Cause**: Using Debian Trixie without updated scripts
- **Solution**: Ensure submodule is at v4.0.1+ (includes Trixie fix)

**Issue**: Python/Ruby version mismatch

- **Cause**: Version pinning from pyenv era
- **Solution**: Specify version via build args:

  ```bash
  docker build --build-arg PYTHON_VERSION=3.12.0 .
````

______________________________________________________________________

### Migrating from v4.x to v4.7.0 (Minor Update)

This is a **non-breaking upgrade**. Simply update the submodule:

````bash
cd containers && git checkout v4.7.0 && cd ..
git add containers
git commit -m "chore: Update to v4.7.0"
docker build --no-cache -t myproject:latest .
```text

**Optional Enhancements to Adopt**:

1. **Add Health Checks** (new in v4.7.0)

```dockerfile
# Add to your Dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD /usr/local/bin/healthcheck.sh --quick || exit 1
```text

1. **Use Retry Configuration** (new in v4.7.0)

```bash
# Environment variables for retry behavior
docker build \
  -e RETRY_MAX_ATTEMPTS=5 \
  -e RETRY_INITIAL_DELAY=1 \
  -t myproject:latest .
```text

---

## Testing Your Migration

### Verification Checklist

After migration, verify everything works:

```bash
# 1. Check version
docker run --rm myproject:latest cat /containers/VERSION
# Expected: 4.7.0

# 2. Verify installed tools
docker run --rm myproject:latest check-installed-versions.sh

# 3. Test language installations
docker run --rm myproject:latest python3 --version
docker run --rm myproject:latest node --version
docker run --rm myproject:latest rustc --version

# 4. Check environment variables
docker run --rm myproject:latest env | grep -E "(CACHE|VERSION|PATH)"

# 5. Test development workflow
docker run -it --rm -v "$(pwd):/workspace/project" myproject:latest bash
# Inside container: run your normal dev commands
```text

### Integration Testing

```bash
# Run your project's test suite in the new image
docker run --rm -v "$(pwd):/workspace/project" \
  myproject:latest \
  bash -c "cd /workspace/project && ./run-tests.sh"

# Compare build times (optional)
time docker build --no-cache -t myproject:test .
```text

### Smoke Tests

Create a smoke test script:

```bash
#!/bin/bash
# smoke-test.sh
set -e

echo "Running smoke tests..."

# Test 1: Container starts
docker run --rm myproject:latest echo "Container starts: OK"

# Test 2: Tools available
docker run --rm myproject:latest which python3
docker run --rm myproject:latest which node

# Test 3: Cache directories exist
docker run --rm myproject:latest ls -la /cache

# Test 4: Healthcheck passes
docker run --rm myproject:latest healthcheck.sh --quick

echo "All smoke tests passed!"
```text

---

## Rollback Procedures

### Quick Rollback

If migration fails, rollback to previous version:

```bash
cd containers

# Rollback to previous tag (example: v4.5.0)
git checkout v4.5.0

cd ..
git add containers
git commit -m "rollback: Revert to container system v4.5.0"

# Rebuild with old version
docker build --no-cache -t myproject:latest .
```text

### Emergency Rollback

See [docs/emergency-rollback.md](operations/rollback.md) for comprehensive
rollback procedures including:

- Rollback with version pinning
- Rollback with git reflog
- Recovery from failed builds
- CI/CD rollback procedures

---

## Common Migration Issues

### Issue: Build Fails After Upgrade

**Symptoms**:

```text
ERROR: failed to solve: failed to compute cache key
```text

**Solutions**:

1. Clear Docker cache: `docker builder prune -af`
1. Rebuild without cache: `docker build --no-cache .`
1. Check Dockerfile syntax changes
1. Verify build arguments are still valid

### Issue: Features Not Installing

**Symptoms**: Features that worked before now fail

**Solutions**:

1. Check feature names haven't changed:

   ```bash
   ./containers/bin/list-features.sh
````

1. Verify build arguments:

   ```bash
   grep "^ARG INCLUDE_" containers/Dockerfile
   ```

1. Check feature dependencies:

   ```bash
   cat containers/docs/feature-dependencies.md
   ```

### Issue: Environment Variables Missing

**Symptoms**: Application can't find expected env vars

**Solutions**:

1. Compare environment variables:

   ```bash
   # Old image
   docker run --rm old-image:latest env > old-env.txt

   # New image
   docker run --rm new-image:latest env > new-env.txt

   # Compare
   diff old-env.txt new-env.txt
   ```

1. Check docs:

   ```bash
   cat containers/docs/environment-variables.md
   ```

### Issue: Performance Regression

**Symptoms**: Builds or runtime slower after upgrade

**Solutions**:

1. Check image size:

   ```bash
   docker images myproject --format "{{.Size}}"
   ```

1. Profile build time:

   ```bash
   time docker build --no-cache .
   ```

1. Review cache strategy:

   ```bash
   cat containers/docs/cache-strategy.md
   ```

______________________________________________________________________

## Best Practices

### Before Migration

1. **Test in Development First**

   - Never upgrade in production directly
   - Test in dev/staging environment
   - Run full test suite

1. **Document Your Configuration**

   - List all `INCLUDE_*` build arguments you use
   - Document any custom Dockerfile modifications
   - Note environment variable customizations

1. **Create a Backup**

   ```bash
   # Tag current working image
   docker tag myproject:latest myproject:pre-migration-backup
   ```

### During Migration

1. **Use Version Pinning**

   ```bash
   # Pin to specific version in your CI/CD
   git submodule update --init --recursive
   cd containers && git checkout v4.7.0
   ```

1. **Maintain Changelog**

   - Document why you're upgrading
   - Note any configuration changes
   - Record test results

### After Migration

1. **Monitor for Issues**

   - Watch build times
   - Check application logs
   - Monitor resource usage

1. **Update Documentation**

   - Update README with new version
   - Document any new features adopted
   - Note any workarounds applied

1. **Share Knowledge**

   - Document lessons learned
   - Update team runbooks
   - Share migration tips with team

______________________________________________________________________

## Getting Help

### Resources

- [CHANGELOG.md](../CHANGELOG.md) - Detailed change history
- [troubleshooting.md](troubleshooting.md) - Common issues and solutions
- [production-deployment.md](production-deployment.md) - Production best
  practices
- [feature-dependencies.md](reference/features.md) - Feature compatibility

### Support Channels

1. **Check Documentation First**

   - Review [docs/](../docs/) directory
   - Search troubleshooting guide
   - Check GitHub issues

1. **GitHub Issues**

   - Search existing issues: `https://github.com/joshjhall/containers/issues`
   - Create new issue with:
     - Old version
     - New version
     - Error messages
     - Steps to reproduce

1. **Emergency Rollback**

   - See [emergency-rollback.md](operations/rollback.md)
   - Pin to last known good version
   - Report issue after recovery

______________________________________________________________________

## Version History Reference

| Version | Release Date | Type  | Notes                                            |
| ------- | ------------ | ----- | ------------------------------------------------ |
| v4.7.0  | 2025-11-11   | Minor | Health checks, retry logic, documentation        |
| v4.5.0  | 2025-11-09   | Minor | Checksum verification, security improvements     |
| v4.4.0  | 2025-XX-XX   | Minor | Feature additions                                |
| v4.3.2  | 2025-XX-XX   | Patch | Bug fixes                                        |
| v4.3.1  | 2025-XX-XX   | Patch | Bug fixes                                        |
| v4.3.0  | 2025-XX-XX   | Minor | Feature additions                                |
| v4.2.0  | 2025-XX-XX   | Minor | Feature additions                                |
| v4.1.0  | 2025-XX-XX   | Minor | Feature additions                                |
| v4.0.0  | 2024-XX-XX   | Major | **Breaking**: Debian Trixie, pyenv/rbenv removal |

______________________________________________________________________

## Deprecation Notices

### Currently Deprecated

None.

### Future Deprecations

Watch the [CHANGELOG.md](../CHANGELOG.md) for deprecation notices. Deprecated
features will:

1. Be marked deprecated for at least one major version
1. Include migration path in documentation
1. Show warnings during build
1. Be removed in next major version

______________________________________________________________________

## Related Documentation

- [CHANGELOG.md](../CHANGELOG.md) - Complete version history
- [emergency-rollback.md](operations/rollback.md) - Emergency procedures
- [troubleshooting.md](troubleshooting.md) - Problem resolution
- [production-deployment.md](production-deployment.md) - Production guidelines
- [CLAUDE.md](../CLAUDE.md) - Build system overview
