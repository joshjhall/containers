# Alert: Container Build Failed

## Overview

- **Alert Name**: ContainerBuildFailed
- **Severity**: Warning
- **Component**: build
- **Threshold**: Build errors > 0 for 5 minutes

## Description

One or more features failed to install correctly during container build. This is
indicated by non-zero error counts in the build logs. While the container may
still run, missing features will not be available.

## Impact

### User Impact

- **MEDIUM**: Specific features may be unavailable (e.g., Python, Node.js, Go)
- Users may encounter "command not found" errors
- Development workflows may be broken
- Some functionality silently missing

### System Impact

- Build cache may be corrupted
- Subsequent builds may inherit the same failures
- CI/CD pipeline may be blocked
- Container images in registry may be incomplete

## Diagnosis

### Quick Checks

1. **Identify failed feature**:

   ```bash
   # Check master summary log
   cat /var/log/container-build/master-summary.log | grep -v "0 errors"

   # Or from metrics
   curl http://localhost:9090/metrics | grep 'container_build_errors_total{.*} [1-9]'
   ```

2. **Check feature-specific logs**:

   ```bash
   # List all build logs
   ls -lah /var/log/container-build/*-errors.log

   # Check specific feature
   check-build-logs.sh python-dev
   check-build-logs.sh node-dev
   ```

3. **Verify feature availability**:

   ```bash
   # Check if commands are available
   which python3 node go rustc java

   # Check versions
   check-installed-versions.sh
   ```

### Detailed Investigation

#### 1. Analyze Error Log

```bash
# View detailed error log for failed feature
FEATURE="python-dev"  # Replace with actual feature
check-build-logs.sh $FEATURE

# Look for specific error patterns:
# - "E: Unable to locate package"  → Missing apt repository
# - "404 Not Found"                 → URL/version no longer available
# - "Permission denied"             → File permission issues
# - "No space left on device"       → Disk full during build
# - "Connection timed out"          → Network issues
```

#### 2. Check Build Arguments

```bash
# View Dockerfile build arguments
docker inspect <image-id> | jq '.[0].Config.OnBuild'

# Check what was requested vs. what was installed
echo "Requested: INCLUDE_PYTHON_DEV=true"
docker inspect <image-id> | jq '.[0].Config.Env' | grep PYTHON
```

#### 3. Reproduce Locally

```bash
# Rebuild with verbose output
docker build \
  --progress=plain \
  --no-cache \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg PROJECT_NAME=test \
  --build-arg PROJECT_PATH=. \
  -f Dockerfile \
  -t test:debug \
  .  2>&1 | tee build-debug.log

# Search for errors in output
grep -i "error\|failed\|fatal" build-debug.log
```

#### 4. Check Dependencies

```bash
# Verify system dependencies
docker run --rm <image-id> bash -c "
  dpkg -l | grep -E 'build-essential|curl|wget|ca-certificates'
"

# Check network connectivity during build
docker build --network=host ...
```

### Common Causes

1. **Network Issues**:
   - Download timeouts
   - DNS resolution failures
   - Firewall/proxy blocking downloads
   - Rate limiting from package repositories

2. **Version Mismatches**:
   - Requested version no longer available
   - Incompatible version combinations
   - Repository URLs changed

3. **Dependency Conflicts**:
   - Missing system packages
   - Conflicting package versions
   - Circular dependencies

4. **Resource Constraints**:
   - Disk full during installation
   - Out of memory during compilation
   - Build timeout

5. **Permission Issues**:
   - Cannot write to installation directory
   - Cannot execute downloaded scripts
   - Incorrect file ownership

6. **Script Bugs**:
   - Errors in feature installation scripts
   - Broken package checksums
   - Incorrect paths

## Resolution

### Quick Fix

#### Option 1: Disable Failed Feature

```bash
# Rebuild without the failing feature
docker build \
  --build-arg INCLUDE_PYTHON_DEV=false \
  --build-arg INCLUDE_NODE_DEV=true \
  ...
  -t <image> .
```

#### Option 2: Use Cached Layer

```bash
# If error is intermittent (network), retry without --no-cache
docker build --build-arg ... -t <image> .
```

#### Option 3: Use Working Version

```bash
# Pin to known-good version
docker build \
  --build-arg PYTHON_VERSION=3.11 \  # instead of latest
  --build-arg NODE_VERSION=20.0.0 \
  ...
  -t <image> .
```

### Permanent Fix

#### 1. Fix Version Pins

Edit `Dockerfile` or feature script:

```bash
# Update lib/features/python-dev.sh
ARG PYTHON_VERSION="3.11"  # Pin to specific version

# Or update version in .env.versions
echo "PYTHON_VERSION=3.11" >> .env.versions
```

#### 2. Fix Missing Dependencies

```bash
# Add missing system packages to feature script
# In lib/features/python-dev.sh

# Add to dependencies list
REQUIRED_PACKAGES=(
    build-essential
    libssl-dev      # ← Add missing dependency
    zlib1g-dev
    ...
)
```

#### 3. Fix Network Issues

```bash
# Add retry logic to downloads
# In lib/base/download-verify.sh

curl --retry 3 --retry-delay 5 --max-time 300 ...

# Or use alternative mirror
PYTHON_DOWNLOAD_URL="https://mirror.example.com/python/..."
```

#### 4. Fix Permission Issues

```bash
# Ensure correct permissions in Dockerfile
RUN chown -R $USERNAME:$USERNAME /usr/local/lib/python*
RUN chmod -R 755 /usr/local/bin/python*
```

### Verification

```bash
# 1. Rebuild from scratch
docker build --no-cache --progress=plain ...

# 2. Verify no errors in logs
docker run --rm <new-image-id> bash -c "
  cat /var/log/container-build/master-summary.log | grep errors
"
# Should show "0 errors" for all features

# 3. Test feature functionality
docker run --rm <new-image-id> bash -c "
  python3 --version
  pip --version
  pytest --version
"

# 4. Check metrics
docker run -d -p 9090:9090 <new-image-id>
curl http://localhost:9090/metrics | grep container_build_errors_total
# Should return 0 for all features
```

## Prevention

### Short-term

- **Pin all versions** to avoid breakage from upstream changes
- **Add retry logic** to all download operations
- **Increase timeouts** for slow networks
- **Cache packages** in private registry/mirror

### Long-term

- **Automated version updates**:

  ```bash
  # Use check-versions.sh and update-versions.sh
  ./bin/check-versions.sh --json > current-versions.json
  ./bin/update-versions.sh current-versions.json
  ```

- **Build validation in CI**:

  ```yaml
  # .github/workflows/ci.yml
  - name: Validate build logs
    run: |
      grep "0 errors" /var/log/container-build/master-summary.log
  ```

- **Dependency pinning**:

  ```bash
  # Create lockfile for system packages
  dpkg -l > debian-packages.lock

  # Version pins in apt preferences
  echo "Package: python3\nPin: version 3.11.*\nPin-Priority: 1000" > /etc/apt/preferences.d/python
  ```

- **Private package mirror**:

  ```bash
  # Use artifactory/nexus for caching
  pip install --index-url https://pypi.internal.example.com/simple
  ```

### Monitoring Improvements

```yaml
# Alert on version drift
- alert: ContainerVersionDrift
  expr: |
    container_installed_version != container_expected_version
```

## Escalation

Escalate if:

- **Multiple features failing** (indicates systemic issue)
- **Persistent across rebuilds** (not transient network issue)
- **Blocking critical deployment** (production deployment waiting)
- **Unknown root cause** after 1 hour investigation

Escalate to:

1. **Feature maintainer** (if specific to one feature)
2. **Team lead** (if blocking work)
3. **Platform team** (if infrastructure related)

## Related

- **Related Alerts**:
  - ContainerBuildSlow (may fire alongside)
  - ContainerBuildWarnings (lower severity)
  - ContainerMetricsMissing (if build fails completely)
- **Related Documentation**:
  - [Feature Scripts](../../features/)
  - [Version Management](../../version-tracking.md)
  - [Troubleshooting](../../troubleshooting.md)
- **Related Scripts**:
  - `lib/features/*.sh` - Feature installation scripts
  - `bin/check-versions.sh` - Version checking
  - `bin/update-versions.sh` - Version updates

## History

- **First Occurrence**: [Track in build logs]
- **Frequency**: Query via:
  `count_over_time(ALERTS{alertname="ContainerBuildFailed"}[7d])`
- **Common Features**: Track which features fail most often
- **False Positive Rate**: Should be low for build errors

## Post-Incident

After resolution:

1. **Update version pins** to prevent recurrence
2. **Document** root cause in feature script comments
3. **Add test** for the failure scenario
4. **Review** dependency chain for fragility
5. **Consider** vendoring critical dependencies
