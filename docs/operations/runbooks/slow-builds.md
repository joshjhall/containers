# Slow Builds

Diagnose and resolve slow Docker build performance.

## Symptoms

- Build takes significantly longer than expected
- Build appears to hang at certain steps
- CI/CD pipeline timeouts
- High disk or network I/O during builds

## Quick Checks

```bash
# Check current build cache size
docker buildx du

# Check disk I/O
iostat -x 1 5

# Check network
curl -o /dev/null -s -w '%{time_total}' https://deb.debian.org

# Check Docker resource usage
docker stats --no-stream
```

## Common Causes

### 1. No Build Cache

**Symptom**: Every build downloads packages and compiles from scratch

**Check**:

```bash
# Look for cache misses in build output
docker build --progress=plain -f containers/Dockerfile . 2>&1 | grep -E "CACHED|RUN"
```

**Fix**:

- Use BuildKit: `DOCKER_BUILDKIT=1`
- Mount cache volumes
- Use `--cache-from` for CI

### 2. Large Build Context

**Symptom**: Long delay at "Sending build context to Docker daemon"

**Check**:

```bash
# Check context size
du -sh .

# Find large files
find . -size +10M -type f
```

**Fix**:

- Update `.dockerignore` to exclude unnecessary files
- Move large files outside build context
- Use multi-stage builds

### 3. Slow Package Downloads

**Symptom**: Build hangs during `apt-get install` or tool downloads

**Check**:

```bash
# Test apt mirror speed
curl -o /dev/null -s -w '%{time_total}' http://deb.debian.org/debian/dists/trixie/Release
```

**Fix**:

- Use closer apt mirror
- Configure local apt-cacher-ng
- Check network bandwidth

### 4. Sequential Feature Installation

**Symptom**: Features installed one by one taking long time

**Check**: This is expected behavior as features have dependencies.

**Fix**: Only enable features you actually need.

## Diagnostic Steps

### Step 1: Time Each Build Stage

```bash
# Build with timing
time docker build --progress=plain -f containers/Dockerfile \
  --build-arg PROJECT_PATH=. \
  --build-arg PROJECT_NAME=test \
  . 2>&1 | tee build.log

# Analyze timings
grep -E "^#[0-9]+ \[" build.log | sed 's/^#[0-9]* //'
```

### Step 2: Identify Cache Misses

```bash
# Check for uncached layers
docker build --progress=plain -f containers/Dockerfile . 2>&1 | grep -v CACHED
```

Cache misses happen when:

- Layer content changed
- Previous layer was not cached
- No cache available (first build)

### Step 3: Profile Network Usage

```bash
# During build, in another terminal
iftop -i docker0

# Or check bandwidth
nethogs docker0
```

### Step 4: Check Disk Performance

```bash
# Check I/O wait
vmstat 1 10

# Check disk latency
ioping /var/lib/docker
```

### Step 5: Compare With Benchmark

```bash
# Run performance benchmark
./tests/benchmarks/run-benchmark.sh

# Compare with expected times (varies by hardware)
# Minimal build: ~60s
# Full dev build: ~5-10 minutes
```

## Performance Optimization

### Enable BuildKit Cache Mount

Already configured in Dockerfile for `/cache/*` directories.

### Use Registry Cache

```bash
# Push cache to registry
docker build --cache-to type=registry,ref=myregistry/cache:latest \
  --cache-from type=registry,ref=myregistry/cache:latest \
  -f containers/Dockerfile .
```

### CI/CD Cache Configuration

```yaml
# GitHub Actions example
- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v3

- name: Build with cache
  uses: docker/build-push-action@v5
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

### Local Build Cache

```bash
# Create persistent buildx builder
docker buildx create --name mybuilder --driver docker-container --use

# Build with local cache
docker buildx build --cache-to type=local,dest=/tmp/buildcache \
  --cache-from type=local,src=/tmp/buildcache \
  -f containers/Dockerfile .
```

### Reduce Build Context

```bash
# Add to .dockerignore
.git
node_modules
__pycache__
*.pyc
.env
tests/
docs/
*.md
```

### Parallel Builds

```bash
# Build multiple variants in parallel
docker build --build-arg INCLUDE_PYTHON_DEV=true -t myapp:python . &
docker build --build-arg INCLUDE_NODE_DEV=true -t myapp:node . &
wait
```

## Expected Build Times

| Build Type            | Expected Time | Notes              |
| --------------------- | ------------- | ------------------ |
| Minimal (cached)      | 30-60s        | Base + utilities   |
| Minimal (uncached)    | 2-3 min       | Downloads packages |
| Single language (dev) | 3-5 min       | Python, Node, etc. |
| Full dev (cached)     | 2-4 min       | Multiple features  |
| Full dev (uncached)   | 8-15 min      | All downloads      |

Times vary based on:

- Network speed
- Disk I/O performance
- CPU cores
- Available RAM

## Resolution

### Clear and Rebuild Cache

```bash
# Clear all build cache
docker builder prune --all

# Rebuild with fresh cache
docker build --no-cache -f containers/Dockerfile .
```

### Use Pre-built Base Image

```bash
# Pull pre-built image
docker pull ghcr.io/joshjhall/containers:python-dev

# Extend with your customizations
FROM ghcr.io/joshjhall/containers:python-dev
COPY . /workspace/project
```

### Optimize for Your Use Case

1. **Only enable needed features** - Each feature adds time
1. **Use production builds** - Smaller, faster
1. **Leverage layer caching** - Order Dockerfile commands
1. **Use multi-stage builds** - Reduce final image size

## Prevention

1. **Monitor build times** in CI/CD
1. **Set up build cache** for all environments
1. **Keep .dockerignore updated**
1. **Use benchmark tests** to detect regressions
1. **Review build logs** periodically for optimization opportunities

## Escalation

If builds remain slow after optimization:

1. Document build times and what was tried
1. Include hardware specs (CPU, RAM, disk type)
1. Provide network test results
1. Note which steps are slowest
1. Open GitHub issue with performance metrics
