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

### Why `/cache/cargo` and `/cache/r` are NOT cache-mounted

It is tempting to add `--mount=type=cache,target=/cache/cargo` (or
`/cache/r`) to speed up the rust-dev / r-dev layers. **Don't** — for these
features `/cache` is not just a build cache, it is the *runtime install
location*:

- rust installs its binaries into `/cache/cargo/bin` and symlinks them into
  `/usr/local/bin`; `/cache/cargo/bin` is also on the runtime `PATH`.
- r installs packages into `/cache/r/library`, which is the runtime
  `R_LIBS_USER` / `R_LIBS_SITE` (set in `/etc/R/Renviron.site`).

A `type=cache` mount over those paths is discarded when the layer commits, so
the installed tools/packages would **vanish from the final image** and the
symlinks would dangle. Cache mounts are only safe on paths that are *purely*
transient build caches (like `/var/cache/apt`).

### How the rust cold-build cost was reduced instead (#517)

Rather than cache-mounting `/cache/cargo`, the rust feature scripts install
their cargo tools with **`cargo binstall`** — it downloads a prebuilt,
checksum-verified binary per crate instead of compiling from source. This
removes almost all of the cold-cache compile time that was blowing the CI
`build-feature` timeout, with no cache-persistence machinery and no risk to the
runtime image. `binstall` transparently falls back to `cargo install` for any
crate lacking a prebuilt binary. The `cargo-binstall` installer itself is a
prebuilt binary pinned in `lib/checksums.json` (Tier 2). See
`lib/features/rust.sh` and `lib/features/rust-dev.sh`.

> r-dev's CRAN compile and java-dev's JDK/apt cost are not yet addressed by
> this approach (R packages would need a binary package repo such as Posit
> PPM; java-dev compiles nothing at build time). Tracked as the #517 follow-up.
