# Build Failures

Debug and resolve Docker build failures.

## Symptoms

- `docker build` exits with non-zero status
- Build hangs indefinitely
- Missing files or features in built image
- CI pipeline fails at build step

## Quick Checks

```bash
# Check Docker is running
docker info

# Check disk space
df -h /var/lib/docker

# Check build context size
du -sh .

# Verify Dockerfile syntax
docker build --check -f containers/Dockerfile .
```

## Common Causes

### 1. Network Timeout

**Symptom**: "Could not resolve host" or timeout errors during package download

**Check**:

```bash
# Test DNS
docker run --rm debian:bookworm-slim nslookup deb.debian.org

# Test connectivity
docker run --rm debian:bookworm-slim curl -I https://deb.debian.org
```

**Fix**:

- Check network connectivity
- Configure Docker DNS: `--dns 8.8.8.8`
- Use apt mirror closer to your location

### 2. Disk Space Exhausted

**Symptom**: "No space left on device"

**Check**:

```bash
docker system df
df -h /var/lib/docker
```

**Fix**:

```bash
# Clean unused resources
docker system prune -a --volumes

# Remove old build cache
docker builder prune --all
```

### 3. Build Argument Errors

**Symptom**: Features not installed or wrong versions

**Check**:

```bash
# List all build args
grep "^ARG " containers/Dockerfile
```

**Fix**: Ensure build args are spelled correctly and use correct format:

```bash
# Correct
--build-arg INCLUDE_PYTHON_DEV=true

# Wrong
--build-arg INCLUDE_PYTHON_DEV=TRUE
--build-arg INCLUDE-PYTHON-DEV=true
```

### 4. Context Too Large

**Symptom**: Build takes very long at "Sending build context"

**Check**:

```bash
# Check context size
du -sh .

# Check .dockerignore
cat .dockerignore
```

**Fix**: Add unnecessary files to `.dockerignore`

### 5. Checksum Verification Failed

**Symptom**: "Checksum mismatch" or GPG verification errors

**Check**:

```bash
# Check network isn't intercepting downloads
curl -I https://www.python.org/ftp/python/
```

**Fix**:

- Verify no proxy/firewall is modifying downloads
- Update checksums if version was updated
- Check for upstream key rotation

## Diagnostic Steps

### Step 1: Enable Verbose Output

```bash
# Build with progress output
docker build --progress=plain -f containers/Dockerfile .

# Export build log
docker build --progress=plain -f containers/Dockerfile . 2>&1 | tee build.log
```

### Step 2: Identify Failing Layer

Look for the last successful step and the first failing step in the output:

```text
#15 [base-setup 3/5] RUN /tmp/build-scripts/base/install-packages.sh
#15 DONE 45.2s

#16 [base-setup 4/5] RUN /tmp/build-scripts/base/create-user.sh
#16 ERROR: process "/bin/sh -c ..." returned non-zero code: 1
```

### Step 3: Debug Specific Layer

```bash
# Build up to the failing layer
docker build --target base-setup -f containers/Dockerfile .

# Run container from that point
docker run -it --rm <partial_image_id> /bin/bash

# Manually run the failing command
/tmp/build-scripts/base/create-user.sh
```

### Step 4: Check BuildKit Cache

```bash
# List build cache
docker buildx du

# Clear specific cache
docker builder prune --filter type=exec.cachemount
```

### Step 5: Test Minimal Build

```bash
# Build with minimal features
docker build -f containers/Dockerfile \
  --build-arg PROJECT_PATH=. \
  --build-arg PROJECT_NAME=test \
  --build-arg INCLUDE_PYTHON=false \
  --build-arg INCLUDE_NODE=false \
  .
```

## Common Error Messages

### "Could not resolve 'deb.debian.org'"

```bash
# Fix: Use explicit DNS
docker build --network=host -f containers/Dockerfile .

# Or configure Docker daemon DNS in /etc/docker/daemon.json
{
  "dns": ["8.8.8.8", "8.8.4.4"]
}
```

### "gpg: keyserver receive failed"

```bash
# GPG keyserver might be down
# The build system has fallbacks, but you can also:

# 1. Wait and retry
# 2. Use different keyserver (configured automatically)
# 3. Skip GPG verification (not recommended for production)
```

### "apt-get update failed"

```bash
# Check if apt cache is stale
docker build --no-cache -f containers/Dockerfile .

# Or specific layer
docker build --no-cache-filter=base-setup -f containers/Dockerfile .
```

### "COPY failed: file not found"

```bash
# Check file exists in build context
ls -la <path_in_error>

# Check .dockerignore isn't excluding it
grep <filename> .dockerignore

# Verify PROJECT_PATH is correct
--build-arg PROJECT_PATH=.
```

## Resolution

### Rebuild Without Cache

```bash
docker build --no-cache -f containers/Dockerfile .
```

### Clean Build Environment

```bash
# Remove all build cache
docker builder prune --all

# Remove dangling images
docker image prune

# Full cleanup
docker system prune -a --volumes
```

### Use Test Framework

```bash
# Proper way to test builds
./tests/test_feature.sh python-dev

# Or run integration tests
./tests/run_integration_tests.sh
```

## Prevention

1. **Use CI for builds** - Consistent environment
2. **Pin base image versions** - Avoid unexpected changes
3. **Monitor disk space** - Set up alerts
4. **Keep .dockerignore updated** - Reduce context size
5. **Test locally before pushing** - Catch issues early

## Escalation

If the issue persists:

1. Run `docker build --progress=plain` and save full output
2. Note Docker version: `docker version`
3. Note build args used
4. Check if issue is reproducible in CI
5. Open GitHub issue with `bug` label and build logs
