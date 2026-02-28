# Cache Troubleshooting and Advanced Topics

This page covers common cache-related issues and advanced caching techniques.

## Troubleshooting

### Issue: "Permission denied" errors in cache directories

**Symptoms**:

```text
ERROR: Could not install packages due to an OSError: [Errno 13] Permission denied: '/cache/pip'
```

**Causes**:

1. Cache directories have incorrect ownership
1. Running as different user than cache was created for
1. Volume mounted with incorrect permissions

**Solutions**:

1. **Check current ownership**:

   ```bash
   docker run --rm -v project-cache:/cache myproject:dev ls -la /cache
   ```

1. **Fix ownership** (if using volume):

   ```bash
   # Fix ownership to match container user (UID 1000)
   docker run --rm -v project-cache:/cache myproject:dev chown -R 1000:1000 /cache
   ```

1. **Rebuild with correct USER_UID**:

   ```bash
   # Build with specific UID/GID
   docker build --build-arg USER_UID=1001 -t myproject:dev .
   ```

### Issue: Build cache not working, packages re-downloaded every time

**Symptoms**:

```text
Downloading packages... (every build, even for same Dockerfile)
```

**Causes**:

1. BuildKit not enabled
1. Cache mounts not specified in Dockerfile
1. `--no-cache` flag used

**Solutions**:

1. **Enable BuildKit**:

   ```bash
   export DOCKER_BUILDKIT=1
   docker build -t myproject:dev .
   ```

1. **Verify cache mounts in Dockerfile**:

   ```dockerfile
   RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
       apt-get update && apt-get install -y python3
   ```

1. **Don't use `--no-cache` unless needed**:

   ```bash
   # Use cache
   docker build -t myproject:dev .

   # Disables cache
   docker build --no-cache -t myproject:dev .
   ```

### Issue: Cache directories not persisting across container restarts

**Symptoms**:

```text
# Install packages in container
pip install numpy

# Restart container, packages gone!
pip show numpy
# ERROR: Package not found
```

**Cause**: Not mounting `/cache` as a volume.

**Solution**:

```bash
# Mount cache volume
docker run -v project-cache:/cache myproject:dev
```

### Issue: Large cache volumes consuming disk space

**Symptoms**:

```bash
docker volume inspect project-cache
# "Size": "5.2GB"
```

**Solutions**:

1. **Identify large caches**:

   ```bash
   docker run --rm -v project-cache:/cache alpine du -sh /cache/*
   ```

1. **Clear specific large caches**:

   ```bash
   # Clear npm cache (typically safe)
   docker run --rm -v project-cache:/cache alpine npm cache clean --force

   # Clear pip cache
   docker run --rm -v project-cache:/cache alpine rm -rf /cache/pip
   ```

1. **Clear all caches and rebuild**:

   ```bash
   docker volume rm project-cache
   docker volume create project-cache
   docker run -v project-cache:/cache myproject:dev
   ```

### Issue: Different package versions than expected

**Symptoms**:

```bash
# Dockerfile specifies Python 3.14
# But container has packages for Python 3.12
```

**Cause**: Cached packages from previous Python version.

**Solution**: Clear language-specific cache when changing versions:

```bash
# Clear Python caches when changing Python version
docker run --rm -v project-cache:/cache alpine sh -c "
  rm -rf /cache/pip /cache/poetry /cache/pipx
"

# Rebuild
docker build -t myproject:dev .
```

### Issue: Cache not shared between builds

**Symptoms**: Each `docker build` downloads packages, even for identical
Dockerfiles.

**Causes**:

1. Using different Docker builders
1. BuildKit cache isolation
1. Building on different machines

**Solutions**:

1. **Use same builder**:

   ```bash
   # Check current builder
   docker buildx ls

   # Use default builder
   docker buildx use default
   ```

1. **Export/import build cache**:

   ```bash
   # Export cache
   docker buildx build --cache-to=type=local,dest=/tmp/cache .

   # Import cache on another machine
   docker buildx build --cache-from=type=local,src=/tmp/cache .
   ```

______________________________________________________________________

## Advanced Topics

### Cache Sizing Recommendations

**Development environments**:

- Small project: 1-2 GB cache volume
- Medium project: 2-5 GB cache volume
- Large monorepo: 5-10 GB cache volume

**Monitor cache growth**:

```bash
# Watch cache size over time
watch 'docker run --rm -v project-cache:/cache alpine du -sh /cache'
```

### Cache Warming

Pre-populate caches during image build for faster container startup:

```dockerfile
# Install common packages during build
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    pip install --cache-dir /cache/pip numpy pandas requests

# Packages now cached in image, available immediately at runtime
```

### Multi-Stage Build Cache Strategy

```dockerfile
# Stage 1: Build environment with full caches
FROM myproject:dev AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
RUN python setup.py build

# Stage 2: Runtime without caches
FROM python:3.14-slim AS runtime
COPY --from=builder /build/dist /app/dist
# No /cache directory in runtime image
```
