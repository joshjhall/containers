# Cache Strategy

This document explains how the container build system uses caching to optimize
build times and reduce network bandwidth.

## Overview

The build system employs a **two-layer caching strategy**:

1. **BuildKit cache mounts** - Temporary caches during image builds (package
   downloads, compilation artifacts)
1. **Persistent cache directories** - Persistent caches in `/cache` directory
   for runtime and rebuilds

All language package managers are configured to use consistent cache paths under
`/cache`, making it easy to mount a single volume to persist all caches.

## Detailed Guides

| Guide                                                                       | Description                                                                |
| --------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| [BuildKit Cache Mounts](caching/buildkit-cache-mounts.md)                   | Build-time vs runtime caches, APT cache mounts, cache mount limitations    |
| [Language Caches](caching/language-caches.md)                               | Per-language cache directories, environment variables, directory structure |
| [Runtime Volumes](caching/runtime-volumes.md)                               | Volume mounts for persistent caching, Docker Compose patterns              |
| [Invalidation & Best Practices](caching/invalidation-and-best-practices.md) | When caches invalidate, clearing caches, 7 best practices                  |
| [Troubleshooting & Advanced](caching/troubleshooting-and-advanced.md)       | Permission errors, stale caches, sizing, cache warming, multi-stage builds |

## Quick Reference

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

## Key Takeaways

1. **Two cache layers**: BuildKit (build-time) and `/cache` directory (runtime)
1. **BuildKit caches** speed up apt operations during builds
1. **Runtime caches** in `/cache` persist package downloads
1. **Mount volumes** for persistent caches: `-v cache:/cache`
1. **Clear caches selectively** when troubleshooting
1. **Monitor cache sizes** to prevent disk exhaustion
1. **Use named volumes** for portability and management

## Related Documentation

- [environment-variables.md](../reference/environment-variables.md) - Cache-related
  environment variables
- [troubleshooting.md](../troubleshooting.md) - Build and cache troubleshooting
- [production-deployment.md](../production-deployment.md) - Production caching
  strategies
- [CLAUDE.md](../../CLAUDE.md) - Build system overview
