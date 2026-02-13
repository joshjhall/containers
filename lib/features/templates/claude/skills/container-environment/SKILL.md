---
description: Container development environment details and available tools
---

# Container Environment

This skill describes the development container environment, installed tools,
and container-specific patterns.

## Container Patterns

- Working directory: /workspace
- Non-root user (configurable via USERNAME build arg)
- tini as PID 1 for zombie process reaping
- First-startup scripts in /etc/container/first-startup/
- Startup scripts in /etc/container/startup/
- Build logs available via: check-build-logs.sh <feature-name>

## Cache Paths

All caches are under /cache/ for Docker volume persistence:

- pip: /cache/pip
- npm: /cache/npm
- cargo: /cache/cargo
- go: /cache/go
- bundle: /cache/bundle
- dev-tools: /cache/dev-tools

## Installed Languages & Tools

<!-- DYNAMIC: This section is replaced at runtime with actual installed features -->

See /etc/container/config/enabled-features.conf for build-time feature flags.

## Useful Commands

- check-build-logs.sh <feature> - View build logs for a feature
- check-installed-versions.sh - Show installed tool versions
- test-dev-tools - Verify development tool installation
