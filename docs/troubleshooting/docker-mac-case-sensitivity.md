# Docker for Mac Case-Sensitivity Issues

## Problem

Even with a case-sensitive APFS volume on macOS, Docker for Mac's file sharing
layer may not preserve case-sensitivity for bind mounts. This causes Linux
containers to see case-insensitive filesystems when they expect
case-sensitivity.

## Root Cause

Docker for Mac uses a file sharing mechanism (osxfs, gRPC FUSE, or VirtioFS) to
mount host directories into containers. These mechanisms may not preserve all
filesystem semantics, including case-sensitivity.

## Solutions

### Option 1: Enable VirtioFS (Recommended)

VirtioFS has better POSIX compliance and may preserve case-sensitivity.

**Requirements**: Docker Desktop for Mac 4.6+

**Steps**:

1. Open Docker Desktop settings
2. Navigate to: Settings → General → Choose file sharing implementation
3. Select "VirtioFS" (if available)
4. Restart Docker Desktop
5. Rebuild your devcontainer

**Verify**:

```bash
# In container
./bin/detect-case-sensitivity.sh /workspace/containers
# Should show: "is case-sensitive"
```

### Option 2: Use Docker Volumes (Most Reliable)

Docker volumes exist entirely in Docker's namespace and always preserve
case-sensitivity.

**Trade-off**: Can't edit files directly on macOS (need remote editing or sync)

**Docker Compose**:

```yaml
services:
  devcontainer:
    volumes:
      - workspace-volume:/workspace/containers # Named volume instead of bind mount
    # ... rest of config

volumes:
  workspace-volume: # Creates persistent Docker volume
```

**With VS Code Remote Containers**:

VS Code can edit files in Docker volumes directly via the Remote Container
extension.

### Option 3: Suppress Warning (Least Invasive)

If you're aware of the limitations and code carefully:

**In docker-compose.yml**:

```yaml
environment:
  - SKIP_CASE_CHECK=true # Suppress startup warning
```

**Or in devcontainer.json**:

```json
{
  "containerEnv": {
    "SKIP_CASE_CHECK": "true"
  }
}
```

**Important**: You must be careful about:

- Git case-only renames (won't work)
- Case-sensitive imports (`from MyModule` vs `from mymodule`)
- Build tools expecting exact case matches

### Option 4: Use Colima Instead of Docker Desktop

Colima is an alternative container runtime for macOS that may have better
filesystem support.

```bash
# Install Colima
brew install colima

# Start with VZ framework (better filesystem support)
colima start --vm-type vz --mount-type virtiofs

# Use with VS Code
# Works with "Remote - Containers" extension
```

## Testing Case-Sensitivity

```bash
# Test workspace mount
./bin/detect-case-sensitivity.sh /workspace/containers

# Test other paths
./bin/detect-case-sensitivity.sh /tmp
./bin/detect-case-sensitivity.sh /var
```

## Known Limitations by File Sharing Type

### osxfs (Legacy)

- ❌ Does not preserve case-sensitivity
- ❌ Slow performance
- ✅ Most compatible

### gRPC FUSE

- ❌ Does not preserve case-sensitivity
- ✅ Better performance than osxfs
- ✅ Good compatibility

### VirtioFS

- ⚠️ May preserve case-sensitivity (version dependent)
- ✅ Best performance
- ✅ Better POSIX compliance
- ❌ Requires newer Docker Desktop (4.6+)

## When This Matters

### High Impact

- **Git operations**: Case-only renames fail
- **Go imports**: Package names are case-sensitive
- **Python imports**: Module names are case-sensitive
- **Build systems**: Makefiles, CMake, etc. expect exact case

### Low Impact

- **Shell scripts**: Usually case-insensitive for files
- **Documentation**: Markdown, README files
- **Configuration**: YAML, JSON files

## Workarounds if Stuck with Case-Insensitive

1. **Never rename with case only**: `git mv README.md readme.md` won't work
2. **Use consistent casing**: Always lowercase or always PascalCase
3. **Avoid case-sensitive imports**: Don't rely on case differences
4. **Test in CI**: CI runs in Linux with case-sensitive fs

## Recommended Configuration

For macOS developers working with Linux containers:

```yaml
# .devcontainer/docker-compose.yml
services:
  devcontainer:
    volumes:
      # Option A: Bind mount (convenient but may be case-insensitive)
      - ..:/workspace/project

      # Option B: Named volume (always case-sensitive)
      - project-workspace:/workspace/project

      # Option C: Hybrid (code in volume, config in bind mount)
      - project-src:/workspace/project/src # Code
      - ../.git:/workspace/project/.git # Git (read-only)
      - ../README.md:/workspace/project/README.md:ro # Docs

    environment:
      # Suppress warning if you've verified your setup
      - SKIP_CASE_CHECK=${SKIP_CASE_CHECK:-false}

volumes:
  project-workspace:
  project-src:
```

## References

- [Docker for Mac file sharing](https://docs.docker.com/desktop/mac/permission-requirements/)
- [VirtioFS documentation](https://docs.docker.com/desktop/mac/apple-silicon/)
- [Case-sensitive APFS](https://support.apple.com/guide/disk-utility/file-system-formats-dsku19ed921c/)
- [Container filesystem guide](../troubleshooting/case-sensitive-filesystems.md)
