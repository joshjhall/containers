# Cache Types and BuildKit Cache Mounts

This page covers the two types of caching used in the container build system and
how BuildKit cache mounts work.

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

______________________________________________________________________

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
