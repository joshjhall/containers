# Cache Issues

Debug and resolve BuildKit and application cache problems.

## Symptoms

- Build doesn't use cached layers
- Package managers re-download everything
- Cache mount not persisting between builds
- "No space left on device" from cache growth

## Quick Checks

```bash
# Check BuildKit cache usage
docker buildx du

# Check cache directory size
du -sh /var/lib/docker/buildkit

# List cache mounts
docker buildx du --verbose | grep "exec.cachemount"

# Check disk space
df -h /var/lib/docker
```

## Common Causes

### 1. Cache Invalidation

**Symptom**: Layer rebuilds even though nothing changed

**Check**: Look for changes in earlier layers that invalidate cache.

**Common invalidators**:

- Modified files COPYed early in Dockerfile
- Changed build args that affect earlier layers
- Missing `--mount=type=cache` on RUN commands

**Fix**: Order Dockerfile to put rarely-changed items first

### 2. Cache Mount Not Persisting

**Symptom**: pip/npm/cargo downloads on every build

**Check**:

```bash
# Verify cache directory exists in container
docker run --rm <image> ls -la /cache

# Check mount configuration in Dockerfile
grep "mount=type=cache" containers/Dockerfile
```

**Fix**: Ensure BuildKit is enabled: `DOCKER_BUILDKIT=1`

### 3. Cache Volume Permissions

**Symptom**: "Permission denied" when writing to cache

**Check**:

```bash
docker run --rm -v project-cache:/cache <image> ls -la /cache
```

**Fix**:

```bash
# Fix ownership
docker run --rm -v project-cache:/cache <image> \
  sudo chown -R vscode:vscode /cache
```

### 4. Cache Size Growth

**Symptom**: Disk filling up, "no space left"

**Check**:

```bash
docker buildx du
du -sh /var/lib/docker/buildkit
```

**Fix**:

```bash
# Prune cache older than 24 hours
docker builder prune --filter until=24h

# Set cache size limit
docker buildx prune --keep-storage=10GB
```

### 5. Different Builder Instance

**Symptom**: Cache not shared between builds

**Check**:

```bash
# List builders
docker buildx ls

# Check which builder is active
docker buildx inspect
```

**Fix**: Use consistent builder across builds

## Diagnostic Steps

### Step 1: Verify BuildKit is Enabled

```bash
# Check BuildKit is being used
DOCKER_BUILDKIT=1 docker build --progress=plain . 2>&1 | head -20

# Should see BuildKit format, not legacy
```

### Step 2: Check Cache Mounts

The Dockerfile uses cache mounts for package managers:

```dockerfile
RUN --mount=type=cache,target=/cache/pip,uid=1000,gid=1000 \
    pip install ...
```

Verify these are working:

```bash
# Build and check cache was created
docker build --progress=plain -f containers/Dockerfile . 2>&1 | grep "mount"
```

### Step 3: Analyze Cache Usage

```bash
# Detailed cache breakdown
docker buildx du --verbose

# By type
docker buildx du --verbose | grep -E "^(regular|exec)"
```

### Step 4: Test Cache Persistence

```bash
# First build
time docker build -f containers/Dockerfile .

# Second build (should be faster)
time docker build -f containers/Dockerfile .

# If times are similar, cache isn't working
```

### Step 5: Check Runtime Cache

```bash
# Run container and check cache dirs
docker run --rm -v project-cache:/cache <image> /bin/bash -c "
  echo 'pip cache:' && du -sh /cache/pip 2>/dev/null || echo 'empty'
  echo 'npm cache:' && du -sh /cache/npm 2>/dev/null || echo 'empty'
  echo 'go cache:' && du -sh /cache/go 2>/dev/null || echo 'empty'
"
```

## Application Cache Configuration

### pip (Python)

```bash
# Verify pip cache
docker run --rm <image> pip cache info

# Environment variable
PIP_CACHE_DIR=/cache/pip
```

### npm (Node.js)

```bash
# Verify npm cache
docker run --rm <image> npm cache ls

# Environment variable
NPM_CONFIG_CACHE=/cache/npm
```

### Cargo (Rust)

```bash
# Verify cargo cache
docker run --rm <image> ls -la /cache/cargo

# Environment variable
CARGO_HOME=/cache/cargo
```

### Go

```bash
# Verify go cache
docker run --rm <image> go env | grep CACHE

# Environment variables
GOCACHE=/cache/go
GOMODCACHE=/cache/go/mod
```

## Resolution

### Rebuild Cache From Scratch

```bash
# Clear all build cache
docker builder prune --all --force

# Clear specific cache type
docker builder prune --filter type=exec.cachemount
```

### Reset Runtime Cache Volume

```bash
# Remove cache volume
docker volume rm project-cache

# Recreate with correct permissions
docker volume create project-cache
docker run --rm -v project-cache:/cache debian:bookworm-slim \
  chown -R 1000:1000 /cache
```

### Fix Cache Permissions

```bash
# In docker-compose.yml, use init container
services:
  cache-init:
    image: debian:bookworm-slim
    volumes:
      - cache:/cache
    command: chown -R 1000:1000 /cache

  app:
    depends_on:
      cache-init:
        condition: service_completed_successfully
    volumes:
      - cache:/cache
```

### Set Cache Size Limits

```bash
# Configure BuildKit GC
cat > /etc/docker/daemon.json << 'EOF'
{
  "builder": {
    "gc": {
      "enabled": true,
      "defaultKeepStorage": "20GB"
    }
  }
}
EOF

# Restart Docker
sudo systemctl restart docker
```

### Use External Cache

```bash
# For CI: Use registry cache
docker buildx build \
  --cache-from type=registry,ref=myregistry/cache:latest \
  --cache-to type=registry,ref=myregistry/cache:latest \
  .

# For local: Use directory cache
docker buildx build \
  --cache-from type=local,src=/path/to/cache \
  --cache-to type=local,dest=/path/to/cache \
  .
```

## Prevention

1. **Set up cache monitoring** - Alert on cache growth
2. **Configure automatic pruning** - Keep cache size bounded
3. **Use consistent builder** - Don't switch between builders
4. **Document cache volumes** - Include in project setup
5. **Test cache effectiveness** - Include in CI benchmarks

## Escalation

If cache issues persist:

1. Document cache sizes and growth rate
2. Note which cache types are problematic
3. Include Docker and BuildKit versions
4. Describe build environment (CI vs local)
5. Open GitHub issue with `bug` label
