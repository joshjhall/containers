# Universal Container Build System

[![CI/CD Pipeline](https://github.com/joshjhall/containers/actions/workflows/ci.yml/badge.svg)](https://github.com/joshjhall/containers/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A modular, extensible container build system designed to be shared across projects as a git submodule. Build everything from minimal agent containers to full-featured development environments using a single, configurable Dockerfile.

## Table of Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [VS Code Dev Container](#vs-code-dev-container)
- [Available Features](#available-features)
- [Example Use Cases](#example-use-cases)
- [Version Management](#version-management)
- [Testing](#testing)
- [Best Practices](#best-practices)
- [Contributing](#contributing)

## Features

- 🔧 **Modular Architecture**: Enable only the tools you need via build arguments
- 🚀 **Efficient Caching**: BuildKit cache mounts for faster rebuilds
- 🔒 **Security First**: Non-root users, proper permissions, validated installations
- 🌍 **Multi-Purpose**: Development, CI/CD, production, and agent containers
- 📦 **28 Feature Modules**: Python, Node.js, Rust, Go, Ruby, Java, R, and 100+ tools
- ☁️ **Cloud Ready**: AWS, GCP, Kubernetes, Terraform integrations
- 🐧 **Debian Compatible**: Supports Debian 11 (Bullseye), 12 (Bookworm), and 13 (Trixie)

---

## Quick Start

### Installation

#### For New Projects

1. Add as a git submodule:

```bash
git submodule add https://github.com/joshjhall/containers.git containers
git submodule update --init --recursive
```

2. Build your container using the Dockerfile from the submodule:

```bash
# Build from project root (recommended)
docker build -t myproject:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  .

# For testing containers standalone (without a parent project)
cd containers
docker build -t test:dev \
  --build-arg PROJECT_PATH=. \
  --build-arg PROJECT_NAME=test \
  --build-arg INCLUDE_NODE_DEV=true \
  .
```

#### For Existing Projects

1. Add the submodule:

```bash
git submodule add https://github.com/joshjhall/containers.git containers
```

2. Create build scripts or update your CI/CD to use the shared Dockerfile:

```bash
# scripts/build-dev.sh
docker build -t myproject:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_POSTGRES_CLIENT=true \
  .

# scripts/build-prod.sh  
docker build -t myproject:prod \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_PYTHON=true \
  .
```

---

## VS Code Dev Container

This system integrates seamlessly with VS Code Dev Containers. Simply reference the shared Dockerfile in your `.devcontainer/docker-compose.yml`:

```yaml
services:
  devcontainer:
    build:
      context: ..
      dockerfile: containers/Dockerfile
      args:
        BASE_IMAGE: mcr.microsoft.com/devcontainers/base:bookworm
        PROJECT_NAME: myproject
        INCLUDE_PYTHON_DEV: "true"
        INCLUDE_NODE_DEV: "true"
    volumes:
      - ..:/workspace/myproject
```

For complete examples with databases, 1Password integration, and advanced configurations, see the [examples/devcontainer/](examples/devcontainer/) directory

---

## Available Features

All features are enabled via `INCLUDE_<FEATURE>=true` build arguments.

### Languages

| Feature | Build Arg | What's Included |
|---------|-----------|-----------------|
| **Python** | `INCLUDE_PYTHON=true` | Python 3.14+ from source, pip, pipx |
| **Python Dev** | `INCLUDE_PYTHON_DEV=true` | + Poetry, black, ruff, mypy, pytest, jupyter |
| **Node.js** | `INCLUDE_NODE=true` | Node 22 LTS, npm, yarn, pnpm |
| **Node Dev** | `INCLUDE_NODE_DEV=true` | + TypeScript, ESLint, Jest, Vite, webpack |
| **Rust** | `INCLUDE_RUST=true` | Latest stable, cargo |
| **Rust Dev** | `INCLUDE_RUST_DEV=true` | + clippy, rustfmt, cargo-watch, bacon |
| **Go** | `INCLUDE_GOLANG=true` | Latest with module support |
| **Go Dev** | `INCLUDE_GOLANG_DEV=true` | + delve, gopls, staticcheck |
| **Ruby** | `INCLUDE_RUBY=true` | Ruby 3.3+, bundler |
| **Ruby Dev** | `INCLUDE_RUBY_DEV=true` | + rubocop, solargraph |
| **Java** | `INCLUDE_JAVA=true` | OpenJDK 21 |
| **Java Dev** | `INCLUDE_JAVA_DEV=true` | + Maven, Gradle |
| **R** | `INCLUDE_R=true` | R environment |
| **R Dev** | `INCLUDE_R_DEV=true` | + tidyverse, devtools |

### Infrastructure & Cloud

| Feature | Build Arg | What's Included |
|---------|-----------|-----------------|
| **Docker** | `INCLUDE_DOCKER=true` | Docker CLI, compose, lazydocker |
| **Kubernetes** | `INCLUDE_KUBERNETES=true` | kubectl, helm, k9s |
| **Terraform** | `INCLUDE_TERRAFORM=true` | terraform, terragrunt, tfdocs |
| **AWS** | `INCLUDE_AWS=true` | AWS CLI v2 |
| **GCloud** | `INCLUDE_GCLOUD=true` | Google Cloud SDK |
| **Cloudflare** | `INCLUDE_CLOUDFLARE=true` | Cloudflare CLI tools |

### Database Clients

| Feature | Build Arg |
|---------|-----------|
| **PostgreSQL** | `INCLUDE_POSTGRES_CLIENT=true` |
| **Redis** | `INCLUDE_REDIS_CLIENT=true` |
| **SQLite** | `INCLUDE_SQLITE_CLIENT=true` |

### Utilities

| Feature | Build Arg | What's Included |
|---------|-----------|-----------------|
| **Dev Tools** | `INCLUDE_DEV_TOOLS=true` | git, gh CLI, lazygit, fzf, ripgrep, bat, eza/exa, delta |
| **1Password** | `INCLUDE_OP=true` | 1Password CLI |
| **Ollama** | `INCLUDE_OLLAMA=true` | Local LLM support |

---

## Example Use Cases

### TypeScript API Project

```bash
# Development: Full TypeScript toolchain + debugging tools
docker build -t myapi:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapi \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_POSTGRES_CLIENT=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  .

# Production: Just Node.js runtime
docker build -t myapi:prod \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapi \
  --build-arg INCLUDE_NODE=true \
  --build-arg BASE_IMAGE=node:22-slim \
  .
```

### Python ML Project

```bash
# Development: Full Python stack + Jupyter
docker build -t myml:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myml \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg PYTHON_VERSION=3.11.2 \
  .

# Training: Python + cloud tools
docker build -t myml:train \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myml \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_AWS=true \
  --build-arg INCLUDE_KUBERNETES=true \
  .
```

### Multi-Language Microservice

```bash
# Development: Everything you might need
docker build -t myservice:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myservice \
  --build-arg INCLUDE_GOLANG_DEV=true \
  --build-arg INCLUDE_RUST_DEV=true \
  --build-arg INCLUDE_DOCKER=true \
  --build-arg INCLUDE_KUBERNETES=true \
  .

# CI/CD: Just build tools
docker build -t myservice:ci \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myservice \
  --build-arg INCLUDE_GOLANG=true \
  --build-arg INCLUDE_RUST=true \
  .
```

---

## Version Management

### Updating the Submodule

To update to the latest version:

```bash
cd containers
git pull origin main
cd ..
git add containers
git commit -m "Update container build system"
```

### Checking for Updates

The container system includes a version checker to identify when newer versions of pinned tools are available:

```bash
# Check all pinned versions
./containers/bin/check-versions.sh

# Output in JSON format (for CI integration)
./containers/bin/check-versions.sh json

# With GitHub token (to avoid rate limits)
GITHUB_TOKEN=ghp_your_token ./containers/bin/check-versions.sh

# Or add to .env file
cp containers/.env.example containers/.env
# Edit .env and add your GITHUB_TOKEN
./containers/bin/check-versions.sh
```

The script will check:

- Language versions (Python, Node.js, Go, Rust, Ruby, Java, R)
- Tool versions (Poetry, Terraform, kubectl, GitHub CLI, etc.)
- Report which tools have updates available

#### Automated Weekly Checks

The GitHub Actions workflow automatically checks for updates weekly:

1. Runs every Sunday at 2am UTC (configured via cron schedule)
2. Creates a pull request with version updates when available
3. Auto-merges after CI tests pass (if configured)

The workflow creates PRs with updated versions that can be reviewed before merging.

### Updating Versions

When updates are available, edit the appropriate files:

- Language versions: Update `ARG *_VERSION` in `Dockerfile`
- Tool versions: Update version variables in `lib/features/*.sh`

---

## Testing

### Unit Tests

The project includes a comprehensive unit test framework (487 tests, 99% pass rate):

```bash
# Run all unit tests (no Docker required)
./tests/run_unit_tests.sh

# Run specific test suite
./tests/unit/features/python.sh
./tests/unit/base/logging.sh
```

**Unit Test Coverage:**
- ✅ 487 unit tests covering all features and utilities
- ✅ 99% pass rate (486 passed, 1 legitimate skip)
- ✅ Tests bash scripts directly without Docker
- ✅ Fast execution (~30 seconds)

### Integration Tests

Integration tests verify that feature combinations build and work together:

```bash
# Run all integration tests
./tests/run_integration_tests.sh

# Run specific integration test
./tests/run_integration_tests.sh python_dev
```

**Integration Test Coverage:**
- ✅ python-dev: Python + dev tools + databases + Docker
- ✅ node-dev: Node.js + dev tools + databases + Docker
- ✅ cloud-ops: Kubernetes + Terraform + AWS + GCloud
- ✅ polyglot: Python + Node.js multi-language
- ✅ rust-golang: Systems programming polyglot
- ✅ minimal: Base container with no features

### Quick Verification

To quickly verify installed features in a running container:

```bash
# From your project root
./containers/bin/test-all-features.sh

# Show all tools (including not installed)
./containers/bin/test-all-features.sh --all
```

---

## Best Practices

1. **Choose the right base image**:
   - `debian:bookworm-slim` (Debian 12): Minimal size, good compatibility (default)
   - `debian:bullseye-slim` (Debian 11): Older stable release
   - `debian:trixie-slim` (Debian 13): Latest testing release
   - `ubuntu:24.04`: More packages available, larger size
   - `mcr.microsoft.com/devcontainers/base:bookworm`: VS Code optimized

2. **Optimize build times**:
   - Only include features you actually need
   - Use BuildKit cache mounts (already configured)
   - Layer expensive operations early in the Dockerfile

3. **Security considerations**:
   - Always use non-root users in production
   - Mount secrets at runtime, don't bake them in
   - Regularly update the submodule for security patches

4. **Version pinning**:
   - Pin the submodule to specific commits for stability
   - Use version build arguments for reproducible builds
   - Document version requirements in your project

5. **Build context**:
   - The build context should be your project root (where you run `docker build .`)
   - The Dockerfile path is `-f containers/Dockerfile`
   - Your project files are available for COPY commands during build

---

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Add tests for new features
4. Submit a pull request

### Code Quality

Optional git hooks are available for code quality checks:

```bash
# Enable shellcheck pre-commit hook
git config core.hooksPath .githooks

# Disable if too intrusive
git config --unset core.hooksPath
```

See [.githooks/README.md](.githooks/README.md) for configuration options.

## License

MIT License - see LICENSE file for details
