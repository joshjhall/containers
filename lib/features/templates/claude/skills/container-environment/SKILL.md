---
description: Container development environment details and available tools. Use when you need to know what tools, languages, and caches are available in this container.
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
- Build logs available via: `check-build-logs.sh <feature-name>`

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

- `check-build-logs.sh python-dev` — view build logs for a specific feature
- `check-build-logs.sh` — view the overall build summary
- `check-installed-versions.sh` — show all installed tool versions
- `test-dev-tools` — verify development tool installation
- `cat /etc/container/config/enabled-features.conf` — check feature flags
