# Build Issues

This section covers common build failures and their solutions when using the
container build system.

## Understanding Build vs Buildx

**Important**: Docker may use `buildx` by default on some systems, which has
different behavior than traditional `docker build`.

**Check which builder you're using**:

```bash
# Check current builder
docker buildx ls

# Check if buildx is default
docker version | grep -A 10 "Server:"

# Use traditional builder
docker build .

# Use buildx explicitly
docker buildx build .
```

**Key differences**:

- **Argument order**: Buildx requires the context (`.`) at the very end
- **Cache behavior**: Buildx may handle cache mounts differently
- **Output**: Different progress display formats

**Solution**: For this project, prefer traditional `docker build` or use the
test framework which handles both correctly.

## Build argument order (Buildx)

**Symptom**: Build fails with "context must be last argument" or similar error.

**Problem**: Buildx requires build context (`.`) as the final argument.

```bash
# ✗ WRONG (works with docker build, fails with buildx)
docker build -t myimage . --build-arg ARG=value

# ✓ CORRECT (works with both)
docker build -t myimage --build-arg ARG=value .
```

**Solution**: Always put the build context (`.`) at the end of the command.

## Build fails with "permission denied" errors

**Symptom**: Build fails when trying to execute scripts.

**Solution**:

```bash
# Ensure all scripts have executable permissions
chmod +x lib/**/*.sh bin/*.sh
git add -u
git commit -m "fix: Add executable permissions to scripts"
```

## BuildKit cache mount errors

**Symptom**: Errors about cache mounts or permission issues during build.

**Solution**:

```bash
# Clear BuildKit cache
docker builder prune -af

# Rebuild without cache
docker build --no-cache -t myproject:dev .
```

## Script sourcing failures

**Symptom**: Build fails with "file not found" when sourcing scripts, even
though the file exists.

```text
/bin/bash: line 1: /tmp/build-scripts/base/logging.sh: No such file or directory
```

**Causes**:

1. Scripts not copied to build context
1. Incorrect COPY statement in Dockerfile
1. Symlinks not resolved

**Solution**:

```bash
# Verify files are in build context
ls -la lib/base/

# Check Dockerfile COPY statement
grep "COPY lib" Dockerfile

# Ensure no broken symlinks
find lib -type l -exec test ! -e {} \; -print

# Rebuild with verbose output
DOCKER_BUILDKIT=0 docker build --progress=plain -t test .
```

## Build fails immediately: "failed to xattr ... too many levels of symbolic links"

**Symptom**: Every `docker build` from the repo root fails before any build step
runs, while loading the build definition:

```text
#1 [internal] load build definition from Dockerfile
#1 ERROR: error from sender: failed to xattr .codegraph: too many levels of symbolic links
------
ERROR: failed to build: failed to solve: failed to read dockerfile:
  error from sender: failed to xattr .codegraph: too many levels of symbolic links
```

Remove the named symlink and the error moves to the next one (`AGENTS.md`). This
blocks every integration test that builds an image
(`./tests/run_integration_tests.sh`, `just test-integration-*`,
`just test-feature`).

**Cause**: `lgetxattr(2)` on a **symlink** returns `ELOOP` on the virtiofs layer
backing `/workspace`. BuildKit's context sender calls it on every path it walks,
so the transfer aborts. The problem is the symlink-ness, not those two paths —
any symlink added to the repo trips it.

The symlinks themselves are healthy (`readlink`, `stat`, `cat`, and git all work
on them). This is **not** the stale-attribute decay that `workspace-fs-health`
repairs, and relinking does not help: a symlink created seconds ago fails
identically, because the condition belongs to the mount.

`.dockerignore` does **not** help either — the sender xattrs paths before
applying ignore filters, so an excluded path is still probed.

**Fix**: The bindfs overlay passes `--xattr-none`
(`lib/runtime/lib/setup-bindfs.sh`), which makes bindfs answer the call itself
with `EOPNOTSUPP` — what BuildKit expects for "no xattrs" — instead of relaying
the lower layer's `ELOOP`. Safe because nothing in these images reads xattrs.
(`--xattr-ro` does *not* work: it still relays `ELOOP` for symlinks.)

The overlay is applied at **entrypoint**, so the fix takes effect on container
**restart**, and only on an image built after it. On a container that predates
it, `workspace-fs-health` names the condition at startup rather than leaving you
with the cryptic BuildKit error.

**Check whether you are affected**:

```bash
python3 -c "import os; print(os.listxattr('AGENTS.md', follow_symlinks=False))"
# affected:  OSError: [Errno 40] Too many levels of symbolic links
# fixed:     OSError: [Errno 95] Operation not supported   (or [])
```

**Workaround if you cannot restart**: build with the tracked symlinks
temporarily removed, then restore them.

```bash
git ls-files -s | /usr/bin/awk -F'\t' '$1 ~ /^120000 / { print $2 }' | xargs rm -f
./tests/run_integration_tests.sh <suite>
git checkout -- .   # both symlinks are tracked
```

## Feature script execution fails mid-build

**Symptom**: Build stops during a feature installation with unclear error.

**Debugging steps**:

1. **Check the build logs**:

```bash
# Build with plain progress output
DOCKER_BUILDKIT=0 docker build --progress=plain . 2>&1 | tee build.log

# Search for errors
grep -i "error\|failed\|fatal" build.log
```

1. **Test feature script in isolation**:

```bash
# Use test framework
./tests/test_feature.sh python-dev

# Or manually with Docker
docker run --rm -it debian:trixie-slim bash
# Then inside container:
apt-get update && apt-get install -y curl ca-certificates
# Copy and run your feature script
```

1. **Check feature dependencies**:

```bash
# Some features require others
# Example: python-dev requires python
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  .
```

## Compilation failures (Python, Ruby, Rust from source)

**Symptom**: Build fails when compiling language runtimes from source.

**Common causes**:

- Missing build dependencies
- Insufficient memory
- Corrupted downloads

**Solutions**:

```bash
# Check system dependencies are installed
docker run --rm debian:trixie-slim bash -c \
  "apt-get update && apt-get install -y build-essential"

# Increase Docker memory limit (Docker Desktop)
# Settings → Resources → Memory: 4GB+

# Verify download integrity
docker build --no-cache --build-arg PYTHON_VERSION=3.12.0 . 2>&1 | \
  grep -A 5 "Verifying checksum"

# Try a different version
docker build --build-arg PYTHON_VERSION=3.11.7 .
```

## Cache invalidation issues

**Symptom**: Changes to scripts not reflected in build, or build uses old cached
layers.

**Understanding Docker layer caching**:

- Each `RUN` command creates a cached layer
- Cache invalidates if command changes or previous layers change
- COPY commands cache based on file content hashes

**Solutions**:

```bash
# Force rebuild without cache
docker build --no-cache -t myproject:dev .

# Invalidate from specific point
# Add --build-arg with changing value
docker build --build-arg BUST_CACHE=$(date +%s) .

# Clear all Docker build cache
docker builder prune -af

# Verify no cached layers used
DOCKER_BUILDKIT=0 docker build --progress=plain --no-cache . 2>&1 | \
  grep "cache"
```

## Multi-stage build failures

**Symptom**: Build fails referencing files from previous stages, or "stage not
found" errors.

**Common issues**:

1. Stage name typo
1. Incorrect `--from` reference
1. File paths don't match between stages

**Solution**:

```bash
# Verify stage names in Dockerfile
grep "^FROM.*AS" Dockerfile

# Build only specific stage for testing
docker build --target base -t test:base .

# Check what files exist in a stage
docker run --rm test:base ls -la /tmp/build-scripts/
```

## Environment variable vs build argument confusion

**Symptom**: Variables not available during build, or runtime values not set.

**Understanding ARG vs ENV**:

- `ARG`: Only available during build, not in running container
- `ENV`: Available during build AND runtime
- ARG can have default values: `ARG PYTHON_VERSION=3.12.0`

**Check what's available**:

```bash
# View build arguments in Dockerfile
grep "^ARG" Dockerfile

# Check if build arg is used
docker build --build-arg PYTHON_VERSION=3.14.0 .

# Runtime check
docker run --rm myimage env | grep PYTHON
```

**See also**: [environment-variables.md](../reference/environment-variables.md) for complete
reference.

## Intermediate build failure analysis

**Symptom**: Need to inspect container state at point of failure.

**Solution**: Create a debug point and inspect

```bash
# Method 1: Build to just before failure
# Add RUN command before failing step
RUN echo "Debug checkpoint" && bash

# Rebuild and commit at that point
docker build -t debug:checkpoint .
docker run -it debug:checkpoint bash

# Method 2: Use failed build container
# When build fails, Docker leaves container
docker ps -a | head -5

# Commit the failed state
docker commit <container-id> debug:failed

# Inspect
docker run --rm -it debug:failed bash
```

## Testing feature installation without full build

**Solution**: Use the feature test script

```bash
# Test single feature quickly
./tests/test_feature.sh python-dev

# This creates minimal container and tests just that feature
# Faster than full build when debugging a specific feature
```

## "Failed to resolve base image" error

**Symptom**: Cannot pull base Debian image.

**Solution**:

```bash
# Check Docker daemon is running
docker info

# Try pulling base image manually
docker pull mcr.microsoft.com/devcontainers/base:trixie

# Check network connectivity
ping -c 3 mcr.microsoft.com
```

## Out of disk space during build

**Symptom**: Build fails with "no space left on device" error.

**Solution**:

```bash
# Check disk usage
df -h

# Clean up Docker resources
docker system prune -af --volumes

# Check build context size (should be reasonable)
du -sh .
```

## Version download failures

**Symptom**: Failed to download specific tool versions (e.g., Python, Node.js).

**Solution**:

```bash
# Check if version exists
curl -I https://www.python.org/ftp/python/3.14.0/Python-3.14.0.tgz

# Update to a known good version
docker build --build-arg PYTHON_VERSION=3.13.7 .

# Check version-tracking.md for tested versions
cat docs/reference/versions.md
```
