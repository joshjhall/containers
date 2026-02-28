# Cache Invalidation and Best Practices

This page covers when and how caches are invalidated, and best practices for
managing caches effectively.

## Cache Invalidation

### When Caches Are Invalidated

**BuildKit caches** are invalidated when:

1. Dockerfile `RUN` instruction changes
1. Copied files change (COPY instructions before RUN)
1. Build arguments affecting the RUN command change
1. Cache manually cleared: `docker builder prune`

**Runtime caches** are invalidated when:

1. Image is rebuilt without mounting `/cache` volume
1. Cache directories manually deleted
1. Docker volume removed

### Manual Cache Clearing

**Clear BuildKit cache**:

```bash
# Clear all build cache
docker builder prune -af

# Clear specific cache (not directly possible, rebuild needed)
docker build --no-cache -t myproject:dev .
```

**Clear runtime caches** (volume mounted):

```bash
# Clear all language caches
docker run --rm -v project-cache:/cache alpine sh -c "rm -rf /cache/*"

# Clear specific caches
docker run --rm -v project-cache:/cache alpine rm -rf /cache/pip
docker run --rm -v project-cache:/cache alpine rm -rf /cache/npm

# Clear cache for specific language
docker run --rm -v project-cache:/cache alpine sh -c "
  rm -rf /cache/pip /cache/poetry /cache/pipx
"
```

**Clear runtime caches** (in image):

```bash
# Run container and clear caches
docker run --rm myproject:dev bash -c "
  rm -rf /cache/pip/* /cache/npm/*
"

# Or rebuild image
docker build --no-cache -t myproject:dev .
```

### When to Clear Caches

**Clear BuildKit cache when**:

- Builds are failing due to corrupted package downloads
- Testing changes to package installations
- Disk space is low
- Forcing fresh package downloads

**Clear runtime caches when**:

- Packages are corrupted
- Switching between incompatible versions
- Diagnosing package-related issues
- Reducing image/volume size

### Cache Invalidation Best Practices

1. **Don't clear caches unnecessarily** - Rebuilding caches takes time and
   bandwidth
1. **Clear specific caches** - Only clear the cache related to your issue
1. **Use `--no-cache` sparingly** - Only when truly needed for troubleshooting
1. **Monitor cache sizes** - Large caches may indicate issues

______________________________________________________________________

## Best Practices

### 1. Always Mount Cache Volumes in Development

```bash
# Good: Persistent caches
docker run -v cache:/cache myproject:dev

# Bad: No persistence, slower
docker run myproject:dev
```

### 2. Use Named Volumes, Not Bind Mounts

```bash
# Good: Docker-managed, cross-platform
docker run -v project-cache:/cache myproject:dev

# Works but not recommended: Host path binding
docker run -v /tmp/cache:/cache myproject:dev
```

**Why?** Named volumes:

- Work on all platforms (Linux, macOS, Windows)
- Managed by Docker (backup, migration)
- Better performance on macOS/Windows

### 3. One Volume Per Project

```bash
# Good: Isolated project caches
docker run -v projectA-cache:/cache projectA:dev
docker run -v projectB-cache:/cache projectB:dev

# Risky: Shared cache may cause conflicts
docker run -v shared-cache:/cache projectA:dev
docker run -v shared-cache:/cache projectB:dev
```

**Why?** Isolated caches prevent:

- Version conflicts between projects
- Disk space exhaustion affecting all projects
- Debugging confusion

### 4. Don't Include `/cache` in Bind Mounts

```bash
# Good: Separate mounts
docker run \
  -v "$(pwd):/workspace/project" \
  -v "cache:/cache" \
  myproject:dev

# Bad: Overwrites /cache with host directory
docker run \
  -v "$(pwd):/workspace" \
  myproject:dev
# Now /workspace/cache is empty or host directory!
```

### 5. Periodically Clean Old Caches

```bash
# Check cache sizes
docker run --rm -v project-cache:/cache alpine du -sh /cache/*

# Remove old/unused caches (example: npm cache over 30 days old)
docker run --rm -v project-cache:/cache alpine find /cache/npm -mtime +30 -delete
```

### 6. Build with Cache, Test Without Cache

```bash
# Development: Use cache for speed
docker build -t myproject:dev .

# CI/CD: Occasionally test without cache
docker build --no-cache -t myproject:test .
```

**Why?** Ensures builds work without relying on potentially stale caches.

### 7. Production Images: Minimal Caching

Production images should:

- Use multi-stage builds
- Not include development caches
- Only include runtime dependencies

```dockerfile
# Build stage: Use caches
FROM myproject:dev AS builder
RUN pip install -r requirements.txt

# Production stage: Copy only artifacts, no caches
FROM python:3.14-slim AS production
COPY --from=builder /app/dist /app/dist
```

See [production-deployment.md](../../production-deployment.md) for details.
