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
  - [Security: Handling Secrets](#security-handling-secrets)
  - [General Best Practices](#general-best-practices)
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

The project includes comprehensive test coverage with **647 total tests** across unit and integration test suites.

### Unit Tests

Unit tests validate individual components and scripts (487 tests, 99% pass rate):

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

Integration tests verify that feature combinations build and work together (160 tests across 6 variants):

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

## Security Considerations

### Docker Socket Usage

When using the `INCLUDE_DOCKER=true` feature, you may need to mount the Docker socket to manage containers from within your dev environment.

#### Development Use (Recommended)

**Use Case**: Local development where your main container needs to manage dependency containers (databases, Redis, message queues, etc.)

```yaml
# docker-compose.yml or .devcontainer/docker-compose.yml
services:
  devcontainer:
    build:
      context: ..
      dockerfile: containers/Dockerfile
      args:
        INCLUDE_DOCKER: "true"
        INCLUDE_PYTHON_DEV: "true"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock  # ⚠️ Development only
      - ..:/workspace/myproject
```

**Why this is useful**:
- Start/stop database containers for testing
- Run integration tests that need real services
- Manage multi-container development stacks
- Use docker-compose from within dev container

**Security Impact**:
- ⚠️ **Grants root-equivalent access to the host system**
- Container can start privileged containers
- Container can mount any host directory
- Container can read/modify all other containers

#### Production Use (Not Recommended)

**❌ DO NOT** mount the Docker socket in production containers:

```yaml
# ❌ INSECURE - Never do this in production
services:
  app:
    image: myapp:prod
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock  # ❌ Dangerous!
```

**Alternatives for Production**:
1. **Docker-in-Docker (DinD)**: Run Docker daemon inside container (for CI/CD)
2. **Docker API**: Use restricted Docker API with limited permissions
3. **Kubernetes**: Use Kubernetes API instead of Docker
4. **External orchestration**: Let CI/CD system manage containers

#### Development vs Production Builds

Create separate container variants:

```bash
# Development: Include Docker CLI + mount socket
docker-compose -f docker-compose.dev.yml up

# Production: No Docker, no socket mounting
docker build -t myapp:prod \
  --build-arg INCLUDE_DOCKER=false \
  -f containers/Dockerfile \
  .
```

#### Security Best Practices

1. **Only mount socket in trusted environments**
   - ✅ Local development on your machine
   - ✅ Isolated development containers
   - ❌ Production deployments
   - ❌ Multi-tenant environments
   - ❌ Containers running untrusted code

2. **Use least-privilege alternatives when possible**
   - Consider rootless Docker
   - Use Docker contexts with limited access
   - Explore Docker socket proxies with ACLs

3. **Monitor socket access**
   - Audit what containers access the socket
   - Log Docker API calls in sensitive environments

For more security guidance, see [SECURITY.md](SECURITY.md).

### Passwordless Sudo Access

By default, containers are configured with passwordless sudo for development convenience. For production deployments, disable this feature to follow the principle of least privilege.

#### Development Use (Default)

```bash
# Default behavior - passwordless sudo enabled
docker build -t myapp:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapp \
  --build-arg INCLUDE_PYTHON_DEV=true \
  .
```

**Why this is useful for development**:
- Quickly install system packages during development
- Test installation scripts without password prompts
- Standard development container behavior

**Security Impact**:
- ⚠️ **Non-root user can execute any command as root without password**
- Container escape could grant full host access (if combined with other vulnerabilities)
- Suitable for trusted development environments only

#### Production Use (Recommended)

```bash
# Production: Disable passwordless sudo
docker build -t myapp:prod \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapp \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg ENABLE_PASSWORDLESS_SUDO=false \
  .
```

**Benefits**:
- ✅ Follows least privilege principle
- ✅ Limits damage from container escape vulnerabilities
- ✅ User remains in sudo group but requires password

**When to disable passwordless sudo**:
- ❌ Production deployments
- ❌ Multi-tenant environments
- ❌ CI/CD runner containers (if they don't need sudo)
- ❌ Containers processing untrusted input

**When passwordless sudo is acceptable**:
- ✅ Local development on your machine
- ✅ Isolated development containers
- ✅ VS Code Dev Containers
- ✅ CI/CD containers that need to install dependencies (with caution)

#### Security Best Practices

1. **Use separate builds for dev and prod**
   ```bash
   # scripts/build-dev.sh
   docker build --build-arg ENABLE_PASSWORDLESS_SUDO=true ...

   # scripts/build-prod.sh
   docker build --build-arg ENABLE_PASSWORDLESS_SUDO=false ...
   ```

2. **Review sudo requirements**
   - If your application never needs sudo, disable it
   - If only specific commands need sudo, configure sudoers accordingly
   - Consider removing sudo entirely for runtime-only containers

3. **Layer your security**
   - Disable passwordless sudo
   - Use read-only filesystems where possible
   - Drop unnecessary capabilities
   - Use security profiles (AppArmor, SELinux)

---

## Best Practices

### Security: Handling Secrets

**⚠️ Critical: Never Pass Secrets as Build Arguments**

Build arguments are **permanently stored** in Docker images and visible in multiple locations:

- **Docker build logs** - Plain text output during build
- **Image history** - `docker history <image>` reveals all build args
- **Container inspection** - `docker inspect <container>` exposes build-time values
- **Image layer metadata** - Embedded in the image filesystem

**❌ DON'T DO THIS:**
```bash
# These secrets will be permanently embedded in the image!
docker build --build-arg API_KEY=secret123 ...
docker build --build-arg DATABASE_PASSWORD=pass123 ...
docker build --build-arg AWS_SECRET_ACCESS_KEY=... ...
```

**✅ DO THIS INSTEAD:**

1. **Runtime Environment Variables** (recommended for development):
   ```bash
   docker run -e API_KEY=secret123 my-image:latest

   # Or with .env file
   docker run --env-file .env my-image:latest
   ```

2. **Docker Secrets** (recommended for Docker Swarm/Compose):
   ```bash
   # Create secret
   echo "secret123" | docker secret create api_key -

   # Use in service
   docker service create --secret api_key my-image:latest
   ```

3. **Mounted Config Files** (recommended for sensitive files):
   ```bash
   # Mount secrets directory read-only
   docker run -v ./secrets:/secrets:ro my-image:latest
   ```

4. **Secret Management Tools** (recommended for production):
   ```bash
   # 1Password CLI (included via INCLUDE_OP=true)
   docker run -e OP_SERVICE_ACCOUNT_TOKEN=... my-image:latest

   # AWS Secrets Manager, Vault, etc.
   docker run -e AWS_REGION=us-east-1 my-image:latest
   ```

For more information, see `/workspace/containers/SECURITY.md`.

---

### General Best Practices

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
   - Remove passwordless sudo in production builds (`ENABLE_PASSWORDLESS_SUDO=false`)
   - **Never pass secrets as build arguments** - they're stored permanently in the image
   - Mount secrets at runtime, don't bake them in
   - Regularly update the submodule for security patches
   - See detailed security guidance below

4. **Version pinning**:
   - Pin the submodule to specific commits for stability
   - Use version build arguments for reproducible builds
   - Document version requirements in your project

5. **Build context**:
   - The build context should be your project root (where you run `docker build .`)
   - The Dockerfile path is `-f containers/Dockerfile`
   - Your project files are available for COPY commands during build
   - Use `.dockerignore` to exclude sensitive files from build context

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
