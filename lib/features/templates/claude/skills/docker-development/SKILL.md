---
description: Docker and container development patterns
---

# Docker Development

## Dockerfile Best Practices

- Use multi-stage builds to minimize image size
- Order layers from least to most frequently changing
- Use specific base image tags, not :latest
- Run as non-root user
- Use COPY instead of ADD unless extracting archives
- Use .dockerignore to exclude unnecessary files
- Combine RUN commands to reduce layers
- Use BuildKit cache mounts for package managers

## Docker Compose

- Always include `init: true` for proper zombie reaping
- Use named volumes for persistence
- Use build args for configuration, env vars for runtime
- Never pass secrets as build arguments

## Container Patterns

- Use tini or --init for proper signal handling
- Keep containers single-purpose
- Use health checks for service readiness
- Log to stdout/stderr, not files
- Use environment variables for runtime configuration
