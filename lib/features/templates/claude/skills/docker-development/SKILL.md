---
description: Docker and container development patterns. Use when writing Dockerfiles, docker-compose files, or debugging container builds.
---

# Docker Development

## Project-Specific Patterns

This container build system uses conventions you should follow:

- **BuildKit cache mounts** for all package managers (`--mount=type=cache`):
  pip, npm, cargo, go, and bundle all cache to `/cache/<tool>`
- **Feature scripts** in `lib/features/` are sourced individually by the
  Dockerfile — each feature is independently installable
- **`init: true`** is required in all docker-compose services for zombie reaping
  (tini is PID 1 in the container)
- **Non-root user** by default — configurable via `USERNAME` build arg
- **Build args for config, env vars for runtime** — features use
  `INCLUDE_<FEATURE>=true/false`, runtime uses env vars like `GITHUB_TOKEN`

## Dockerfile Conventions

- Order layers from least to most frequently changing
- Use specific base image tags with version pins, not `:latest`
- Use `COPY` instead of `ADD` unless extracting archives
- Combine related `RUN` commands to reduce layers
- Use `.dockerignore` to exclude unnecessary files from context

## Docker Compose

```yaml
services:
  dev:
    init: true  # Required — ensures proper zombie reaping
    build:
      args:
        - INCLUDE_PYTHON_DEV=true
    environment:
      - GITHUB_TOKEN=${GITHUB_TOKEN}  # Runtime secrets as env vars
    volumes:
      - project-cache:/cache          # Named volume for cache persistence
```

## Debugging Container Builds

- Check build logs inside the container: `check-build-logs.sh <feature-name>`
- Check installed versions: `check-installed-versions.sh`
- Verify feature flags: `cat /etc/container/config/enabled-features.conf`
- Test features in isolation: `./tests/test_feature.sh <feature>`

## When to Use

- Writing or modifying Dockerfiles and docker-compose files
- Debugging container build failures
- Adding new features to the container build system

## When NOT to Use

- Application-level code that happens to run in a container
- Kubernetes deployment configuration (use `cloud-infrastructure` skill)
