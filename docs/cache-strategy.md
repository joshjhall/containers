# Cache Strategy

This document explains how the container build system uses caching to optimize
build times and reduce network bandwidth during builds.

## Table of Contents

- [Overview](#overview)
- [Cache Types](#cache-types)
- [BuildKit Cache Mounts](#buildkit-cache-mounts)
- [Language Cache Directories](#language-cache-directories)
- [Cache Directory Structure](#cache-directory-structure)
- [Runtime Volume Mounts](#runtime-volume-mounts)
- [Cache Invalidation](#cache-invalidation)
- [Best Practices](#best-practices)
- [Troubleshooting](#troubleshooting)

---

## Overview

The build system employs a **two-layer caching strategy** to optimize builds:

1. **BuildKit cache mounts** - Temporary caches during image builds (package
   downloads, compilation artifacts)
2. **Persistent cache directories** - Persistent caches in `/cache` directory
   for runtime and rebuilds

### Benefits

- **Faster builds**: Subsequent builds reuse downloaded packages and compiled
  artifacts
- **Reduced bandwidth**: Package managers don't re-download already-cached
  packages
- **Smaller images**: Temporary build artifacts are not stored in image layers
- **Faster runtime**: Pre-downloaded packages available immediately

### Cache Philosophy

> "Cache early, cache often, cache correctly."

All language package managers are configured to use consistent cache paths under
`/cache`, making it easy to:

- Mount a single volume to persist all caches
- Clear specific caches without affecting others
- Monitor cache sizes and usage patterns

---

## Cache Types

### 1. Build-Time Caches (BuildKit)

**Purpose**: Temporary storage during `docker build` to speed up package
installation.

**Lifetime**: Persists across builds on the same Docker host, cleared with
`docker builder prune`.

**Used for**:

- APT package cache (`/var/cache/apt`, `/var/lib/apt`)
- Downloaded source tarballs (during compilation)
- Temporary build artifacts

**Example**:

```dockerfile
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y python3
```

**Benefits**:

- Faster `apt-get update` on subsequent builds
- Packages don't need to be re-downloaded unless versions change
- Multiple builds can share the same cache (with `sharing=locked`)

### 2. Runtime Caches (Persistent Directories)

**Purpose**: Store downloaded packages, libraries, and application data
persistently.

**Lifetime**: Stored in image or mounted as Docker volumes for persistence
across container restarts.

**Used for**:

- Python: pip packages, Poetry cache, pipx installations
- Node.js: npm cache, global packages, pnpm/yarn stores
- Rust: cargo registry, git checkouts, compiled crates
- Go: module cache, build cache
- Ruby: gem cache, bundle cache
- R: package library, temporary files
- And more...

**Example**:

```bash
docker run -v project-cache:/cache myproject:dev
```

---

## BuildKit Cache Mounts

### APT Package Cache

Every feature installation uses BuildKit cache mounts for APT operations:

```dockerfile
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    /tmp/build-scripts/features/python.sh
```

**Cache targets**:

- `/var/cache/apt` - Downloaded `.deb` package files
- `/var/lib/apt` - APT state and package lists

**Sharing mode**: `locked` allows multiple concurrent builds to safely share the
cache.

### Why This Matters

Without cache mounts:

```bash
# First build: Downloads 500MB of packages
docker build -t myapp:v1 .

# Second build: Downloads the SAME 500MB again
docker build -t myapp:v2 .
```

With cache mounts:

```bash
# First build: Downloads 500MB of packages, stores in cache
docker build -t myapp:v1 .

# Second build: Reuses cached packages, downloads only what changed
docker build -t myapp:v2 .  # Much faster!
```

### Cache Mount Limitations

**Important**: BuildKit caches are **NOT stored in the image** and are **NOT
available at runtime**.

- Cache mounts only exist during `docker build`
- At runtime, `/var/cache/apt` is empty (not a problem for running containers)
- Language caches use `/cache` directory which IS stored in the image

---

## Language Cache Directories

All language package managers are configured to use the `/cache` directory:

### Python

**Cache directories**:

- `/cache/pip` - pip package cache
- `/cache/poetry` - Poetry cache
- `/cache/pipx` - pipx virtual environments and binaries

**Environment variables**:

```bash
export PIP_CACHE_DIR="/cache/pip"
export POETRY_CACHE_DIR="/cache/poetry"
export PIPX_HOME="/cache/pipx"
export PIPX_BIN_DIR="/cache/pipx/bin"
```

**How it works**:

- Python feature script creates cache directories
- Sets ownership to `${USER_UID}:${USER_GID}`
- Configures pip, poetry, pipx to use these paths
- Packages installed during build are cached
- Runtime `pip install` reuses cached packages

### Node.js

**Cache directories**:

- `/cache/npm` - npm package cache
- `/cache/npm-global` - global npm packages
- `/cache/pnpm` - pnpm store (if pnpm installed)
- `/cache/yarn` - yarn cache (if yarn installed)

**Environment variables**:

```bash
export NPM_CONFIG_CACHE="/cache/npm"
export NPM_CONFIG_PREFIX="/cache/npm-global"
export PNPM_HOME="/cache/pnpm"
export YARN_CACHE_FOLDER="/cache/yarn"
```

**How it works**:

- npm installs packages to cache during build
- Global packages stored in `/cache/npm-global`
- Binaries accessible via PATH: `/cache/npm-global/bin`

### Rust

**Cache directories**:

- `/cache/cargo/registry` - crate registry index and downloads
- `/cache/cargo/git` - git dependencies
- `/cache/cargo/target` - compiled build artifacts (optional)

**Environment variables**:

```bash
export CARGO_HOME="/cache/cargo"
```

**How it works**:

- Cargo downloads crates to registry cache
- Compiled crates cached in registry
- `cargo build` reuses cached compiled dependencies

### Go

**Cache directories**:

- `/cache/go/mod` - downloaded Go modules
- `/cache/go/build` - compiled build cache

**Environment variables**:

```bash
export GOMODCACHE="/cache/go/mod"
export GOCACHE="/cache/go/build"
```

**How it works**:

- `go get` downloads modules to mod cache
- `go build` caches compilation artifacts
- Subsequent builds reuse compiled packages

### Ruby

**Cache directories**:

- `/cache/ruby/gems` - installed gems
- `/cache/ruby/bundle` - bundler cache

**Environment variables**:

```bash
export GEM_HOME="/cache/ruby/gems"
export GEM_PATH="/cache/ruby/gems"
export BUNDLE_PATH="/cache/ruby/bundle"
```

**How it works**:

- `gem install` stores gems in GEM_HOME
- `bundle install` caches dependencies
- Gem binaries accessible via PATH: `/cache/ruby/gems/bin`

### R

**Cache directories**:

- `/cache/r/library` - installed R packages
- `/cache/r/tmp` - temporary files during package installation

**Environment variables**:

```bash
export R_LIBS_USER="/cache/r/library"
export R_CACHE_DIR="/cache/r"
export TMPDIR="/cache/r/tmp"
```

**Configuration files**:

- `/etc/R/Renviron.site` - system-wide R environment
- `~/.Rprofile` - user R profile with cache configuration

**How it works**:

- `install.packages()` installs to R_LIBS_USER
- Binary packages cached, avoiding recompilation
- Large packages (tidyverse, data.table) only installed once

### Java

**Cache directories**:

- `/cache/maven` - Maven local repository
- `/cache/gradle` - Gradle cache

**Environment variables**:

```bash
export MAVEN_OPTS="-Dmaven.repo.local=/cache/maven"
export GRADLE_USER_HOME="/cache/gradle"
```

**How it works**:

- Maven downloads artifacts to local repository
- Gradle caches dependencies and build outputs
- Multi-project builds share cached dependencies

### Additional Tools

**Ollama** (LLM models):

- `/cache/ollama` - downloaded model files

**Mojo/Pixi**:

- `/cache/pixi` - Pixi package cache
- `/cache/mojo/project` - Mojo project environment

**Cloudflare**:

- Uses npm caches (wrangler is an npm package)

---

## Cache Directory Structure

The complete `/cache` directory structure:

```
/cache/
├── pip/                    # Python pip cache
├── poetry/                 # Python Poetry cache
├── pipx/                   # Python pipx installations
│   ├── venvs/             # Virtual environments
│   └── bin/               # Executable scripts
├── npm/                    # Node.js npm cache
├── npm-global/            # Global npm packages
│   └── bin/               # Global npm binaries
├── pnpm/                  # pnpm store
├── yarn/                  # Yarn cache
├── cargo/                 # Rust Cargo cache
│   ├── registry/          # Crate registry
│   └── git/               # Git dependencies
├── go/                    # Go cache
│   ├── mod/               # Module cache
│   └── build/             # Build cache
├── ruby/                  # Ruby cache
│   ├── gems/              # Installed gems
│   │   └── bin/           # Gem binaries
│   └── bundle/            # Bundle cache
├── r/                     # R cache
│   ├── library/           # R packages
│   └── tmp/               # Temporary files
├── maven/                 # Maven repository
├── gradle/                # Gradle cache
├── ollama/                # Ollama models
├── pixi/                  # Pixi cache
└── mojo/                  # Mojo environment
    └── project/           # Mojo project directory
```

### Ownership

All cache directories are owned by `${USER_UID}:${USER_GID}` (default:
`1000:1000`).

This ensures:

- Non-root user can write to caches
- No permission errors during package installation
- Consistent ownership across features

### Permissions

Directories created with mode `0755`:

- Owner: read, write, execute
- Group: read, execute
- Others: read, execute

This allows:

- User to install packages
- Other users to read cached packages (useful in multi-user containers)

---

## Runtime Volume Mounts

### Mounting Cache Volumes

For **persistent caches across container restarts**, mount `/cache` as a Docker
volume:

```bash
# Create named volume
docker volume create project-cache

# Mount at runtime
docker run -v project-cache:/cache myproject:dev
```

### Benefits of Volume Mounts

**Without volume mount**:

```bash
# First run: pip downloads packages
docker run myproject:dev pip install numpy pandas

# Container stopped, recreated
docker run myproject:dev pip install numpy pandas
# Downloads SAME packages again!
```

**With volume mount**:

```bash
# First run: pip downloads packages to volume
docker run -v project-cache:/cache myproject:dev pip install numpy pandas

# Container stopped, recreated
docker run -v project-cache:/cache myproject:dev pip install numpy pandas
# Reuses cached packages from volume - instant!
```

### Development Workflow

```bash
# Development environment with persistent caches
docker run -it \
  -v "$(pwd):/workspace/project" \
  -v "project-cache:/cache" \
  --name myproject-dev \
  myproject:dev
```

**Advantages**:

- Package installations persist across container restarts
- Faster iteration during development
- Shared caches across multiple containers (if using same volume)

### Docker Compose

```yaml
version: '3.8'

services:
  app:
    image: myproject:dev
    volumes:
      - .:/workspace/project
      - cache:/cache
    working_dir: /workspace/project

volumes:
  cache:
    driver: local
```

### Cache Volume Management

```bash
# List volumes
docker volume ls

# Inspect volume
docker volume inspect project-cache

# View cache size
docker run --rm -v project-cache:/cache alpine du -sh /cache/*

# Clear specific cache
docker run --rm -v project-cache:/cache alpine rm -rf /cache/pip

# Remove volume (clears all caches)
docker volume rm project-cache
```

---

## Cache Invalidation

### When Caches Are Invalidated

**BuildKit caches** are invalidated when:

1. Dockerfile `RUN` instruction changes
2. Copied files change (COPY instructions before RUN)
3. Build arguments affecting the RUN command change
4. Cache manually cleared: `docker builder prune`

**Runtime caches** are invalidated when:

1. Image is rebuilt without mounting `/cache` volume
2. Cache directories manually deleted
3. Docker volume removed

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
2. **Clear specific caches** - Only clear the cache related to your issue
3. **Use `--no-cache` sparingly** - Only when truly needed for troubleshooting
4. **Monitor cache sizes** - Large caches may indicate issues

---

## Best Practices

### 1. Always Mount Cache Volumes in Development

```bash
# ✅ Good: Persistent caches
docker run -v cache:/cache myproject:dev

# ❌ Bad: No persistence, slower
docker run myproject:dev
```

### 2. Use Named Volumes, Not Bind Mounts

```bash
# ✅ Good: Docker-managed, cross-platform
docker run -v project-cache:/cache myproject:dev

# ⚠️ Works but not recommended: Host path binding
docker run -v /tmp/cache:/cache myproject:dev
```

**Why?** Named volumes:

- Work on all platforms (Linux, macOS, Windows)
- Managed by Docker (backup, migration)
- Better performance on macOS/Windows

### 3. One Volume Per Project

```bash
# ✅ Good: Isolated project caches
docker run -v projectA-cache:/cache projectA:dev
docker run -v projectB-cache:/cache projectB:dev

# ⚠️ Risky: Shared cache may cause conflicts
docker run -v shared-cache:/cache projectA:dev
docker run -v shared-cache:/cache projectB:dev
```

**Why?** Isolated caches prevent:

- Version conflicts between projects
- Disk space exhaustion affecting all projects
- Debugging confusion

### 4. Don't Include `/cache` in Bind Mounts

```bash
# ✅ Good: Separate mounts
docker run \
  -v "$(pwd):/workspace/project" \
  -v "cache:/cache" \
  myproject:dev

# ❌ Bad: Overwrites /cache with host directory
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

See [production-deployment.md](production-deployment.md) for details.

---

## Troubleshooting

### Issue: "Permission denied" errors in cache directories

**Symptoms**:

```
ERROR: Could not install packages due to an OSError: [Errno 13] Permission denied: '/cache/pip'
```

**Causes**:

1. Cache directories have incorrect ownership
2. Running as different user than cache was created for
3. Volume mounted with incorrect permissions

**Solutions**:

1. **Check current ownership**:

   ```bash
   docker run --rm -v project-cache:/cache myproject:dev ls -la /cache
   ```

2. **Fix ownership** (if using volume):

   ```bash
   # Fix ownership to match container user (UID 1000)
   docker run --rm -v project-cache:/cache myproject:dev chown -R 1000:1000 /cache
   ```

3. **Rebuild with correct USER_UID**:
   ```bash
   # Build with specific UID/GID
   docker build --build-arg USER_UID=1001 -t myproject:dev .
   ```

### Issue: Build cache not working, packages re-downloaded every time

**Symptoms**:

```
Downloading packages... (every build, even for same Dockerfile)
```

**Causes**:

1. BuildKit not enabled
2. Cache mounts not specified in Dockerfile
3. `--no-cache` flag used

**Solutions**:

1. **Enable BuildKit**:

   ```bash
   export DOCKER_BUILDKIT=1
   docker build -t myproject:dev .
   ```

2. **Verify cache mounts in Dockerfile**:

   ```dockerfile
   RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
       apt-get update && apt-get install -y python3
   ```

3. **Don't use `--no-cache` unless needed**:

   ```bash
   # ✅ Use cache
   docker build -t myproject:dev .

   # ❌ Disables cache
   docker build --no-cache -t myproject:dev .
   ```

### Issue: Cache directories not persisting across container restarts

**Symptoms**:

```
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

2. **Clear specific large caches**:

   ```bash
   # Clear npm cache (typically safe)
   docker run --rm -v project-cache:/cache alpine npm cache clean --force

   # Clear pip cache
   docker run --rm -v project-cache:/cache alpine rm -rf /cache/pip
   ```

3. **Clear all caches and rebuild**:
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
2. BuildKit cache isolation
3. Building on different machines

**Solutions**:

1. **Use same builder**:

   ```bash
   # Check current builder
   docker buildx ls

   # Use default builder
   docker buildx use default
   ```

2. **Export/import build cache**:

   ```bash
   # Export cache
   docker buildx build --cache-to=type=local,dest=/tmp/cache .

   # Import cache on another machine
   docker buildx build --cache-from=type=local,src=/tmp/cache .
   ```

---

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

---

## Related Documentation

- [environment-variables.md](environment-variables.md) - Cache-related
  environment variables
- [troubleshooting.md](troubleshooting.md) - Build and cache troubleshooting
- [production-deployment.md](production-deployment.md) - Production caching
  strategies
- [CLAUDE.md](../CLAUDE.md) - Build system overview

---

## Summary

**Key Takeaways**:

1. **Two cache layers**: BuildKit (build-time) and `/cache` directory (runtime)
2. **BuildKit caches** speed up apt operations during builds
3. **Runtime caches** in `/cache` persist package downloads
4. **Mount volumes** for persistent caches: `-v cache:/cache`
5. **Clear caches selectively** when troubleshooting
6. **Monitor cache sizes** to prevent disk exhaustion
7. **Use named volumes** for portability and management

**Quick Reference**:

```bash
# Build with cache (default)
docker build -t myproject:dev .

# Run with persistent cache
docker run -v project-cache:/cache myproject:dev

# Check cache size
docker run --rm -v project-cache:/cache alpine du -sh /cache

# Clear all caches
docker volume rm project-cache && docker builder prune -af
```
