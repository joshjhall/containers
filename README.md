# Universal Container Build System

[![CI/CD Pipeline](https://github.com/joshjhall/containers/actions/workflows/ci.yml/badge.svg)](https://github.com/joshjhall/containers/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A modular, extensible container build system designed to be shared across
projects as a git submodule. Build everything from minimal agent containers to
full-featured development environments using a single, configurable Dockerfile.

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
- [Emergency Procedures](#emergency-procedures)

## Features

- 🔧 **Modular Architecture**: Enable only the tools you need via build
  arguments
- 🚀 **Efficient Caching**: BuildKit cache mounts for faster rebuilds
- 🔒 **Security Hardened**: Non-root users, input validation, checksum
  verification, secure temp files, rate limiting
- 🌍 **Multi-Purpose**: Development, CI/CD, production, and agent containers
- 📦 **28 Feature Modules**: Python, Node.js, Rust, Go, Ruby, Java, R, and 100+
  tools
- ☁️ **Cloud Ready**: AWS, GCP, Kubernetes, Terraform integrations
- 🐧 **Debian Compatible**: Supports Debian 11 (Bullseye), 12 (Bookworm), and 13
  (Trixie)

______________________________________________________________________

## Quick Start

### Installation

#### For New Projects

1. Add as a git submodule:

```bash
git submodule add https://github.com/joshjhall/containers.git containers
git submodule update --init --recursive
```

1. Build your container using the Dockerfile from the submodule:

```bash
# Build from project root (recommended)
docker build -t myproject:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  .

# For testing containers standalone (without a parent project)
cd containers
docker build -t test:dev \
  --build-arg PROJECT_PATH=. \
  --build-arg PROJECT_NAME=test \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_NODE_DEV=true \
  .
```

#### For Existing Projects

1. Add the submodule:

```bash
git submodule add https://github.com/joshjhall/containers.git containers
```

1. Create build scripts or update your CI/CD to use the shared Dockerfile:

```bash
# scripts/build-dev.sh
docker build -t myproject:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_PYTHON=true \
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

______________________________________________________________________

## VS Code Dev Container

This system integrates seamlessly with VS Code Dev Containers. Simply reference
the shared Dockerfile in your `.devcontainer/docker-compose.yml`:

```yaml
services:
  devcontainer:
    build:
      context: ..
      dockerfile: containers/Dockerfile
      args:
        BASE_IMAGE: mcr.microsoft.com/devcontainers/base:trixie
        PROJECT_NAME: myproject
        INCLUDE_PYTHON_DEV: 'true'
        INCLUDE_NODE_DEV: 'true'
    volumes:
      - ..:/workspace/myproject
```

For complete examples with databases, 1Password integration, and advanced
configurations, see the [examples/contexts/devcontainer/](examples/contexts/devcontainer/)
directory

______________________________________________________________________

## Available Features

All features are enabled via `INCLUDE_<FEATURE>=true` build arguments.

### Languages

| Feature        | Build Arg                 | What's Included                                 |
| -------------- | ------------------------- | ----------------------------------------------- |
| **Python**     | `INCLUDE_PYTHON=true`     | Python 3.14+ from source, pip, pipx, Poetry, uv |
| **Python Dev** | `INCLUDE_PYTHON_DEV=true` | + black, ruff, mypy, pytest, jupyter            |
| **Node.js**    | `INCLUDE_NODE=true`       | Node 22 LTS, npm, yarn, pnpm                    |
| **Node Dev**   | `INCLUDE_NODE_DEV=true`   | + TypeScript, ESLint, Jest, Vite, webpack       |
| **Rust**       | `INCLUDE_RUST=true`       | Latest stable, cargo                            |
| **Rust Dev**   | `INCLUDE_RUST_DEV=true`   | + clippy, rustfmt, cargo-watch, bacon           |
| **Go**         | `INCLUDE_GOLANG=true`     | Latest with module support                      |
| **Go Dev**     | `INCLUDE_GOLANG_DEV=true` | + delve, gopls, staticcheck                     |
| **Ruby**       | `INCLUDE_RUBY=true`       | Ruby 3.3+, bundler                              |
| **Ruby Dev**   | `INCLUDE_RUBY_DEV=true`   | + rubocop, solargraph                           |
| **Java**       | `INCLUDE_JAVA=true`       | OpenJDK 21                                      |
| **Java Dev**   | `INCLUDE_JAVA_DEV=true`   | + Maven, Gradle                                 |
| **R**          | `INCLUDE_R=true`          | R environment                                   |
| **R Dev**      | `INCLUDE_R_DEV=true`      | + tidyverse, devtools                           |
| **Kotlin**     | `INCLUDE_KOTLIN=true`     | Kotlin compiler (auto-triggers Java)            |
| **Kotlin Dev** | `INCLUDE_KOTLIN_DEV=true` | + ktlint, detekt, kotlin-language-server        |
| **Mojo**       | `INCLUDE_MOJO=true`       | Mojo language runtime                           |
| **Mojo Dev**   | `INCLUDE_MOJO_DEV=true`   | + Mojo development tools                        |

### Mobile Development

| Feature         | Build Arg                  | What's Included                            |
| --------------- | -------------------------- | ------------------------------------------ |
| **Android**     | `INCLUDE_ANDROID=true`     | Android SDK, cmdline-tools (triggers Java) |
| **Android Dev** | `INCLUDE_ANDROID_DEV=true` | + Gradle, ADB, emulator support            |

### Infrastructure & Cloud

| Feature        | Build Arg                 | What's Included                 |
| -------------- | ------------------------- | ------------------------------- |
| **Docker**     | `INCLUDE_DOCKER=true`     | Docker CLI, compose, lazydocker |
| **Kubernetes** | `INCLUDE_KUBERNETES=true` | kubectl, helm, k9s              |
| **Terraform**  | `INCLUDE_TERRAFORM=true`  | terraform, terragrunt, tfdocs   |
| **AWS**        | `INCLUDE_AWS=true`        | AWS CLI v2                      |
| **GCloud**     | `INCLUDE_GCLOUD=true`     | Google Cloud SDK                |
| **Cloudflare** | `INCLUDE_CLOUDFLARE=true` | Cloudflare CLI tools            |

### Database Clients

| Feature        | Build Arg                      |
| -------------- | ------------------------------ |
| **PostgreSQL** | `INCLUDE_POSTGRES_CLIENT=true` |
| **Redis**      | `INCLUDE_REDIS_CLIENT=true`    |
| **SQLite**     | `INCLUDE_SQLITE_CLIENT=true`   |

### Utilities

| Feature       | Build Arg                | What's Included                                                        |
| ------------- | ------------------------ | ---------------------------------------------------------------------- |
| **Dev Tools** | `INCLUDE_DEV_TOOLS=true` | Claude Code CLI, git, gh CLI, lazygit, fzf, ripgrep, bat               |
| **1Password** | `INCLUDE_OP=true`        | 1Password CLI (auto-loads tokens from 1Password)                       |
| **Ollama**    | `INCLUDE_OLLAMA=true`    | Local LLM support                                                      |
| **Cron**      | `INCLUDE_CRON=true`      | Cron daemon for scheduled tasks (auto with Rust/Dev Tools)             |
| **Bindfs**    | `INCLUDE_BINDFS=true`    | FUSE overlay for macOS VirtioFS permission fixes (auto with Dev Tools) |

### Claude Code Integration

When `INCLUDE_DEV_TOOLS=true`, the container includes:

- **Claude Code CLI** - Anthropic's official CLI for Claude
- **MCP Servers** (when Node.js available) - Filesystem, GitHub/GitLab integration
- **Auto-setup watcher** - Automatically configures plugins after authentication
- **LSP plugins** - Language-specific plugins based on enabled features

MCP servers require Node.js. Add `INCLUDE_NODE=true` for full Claude Code support:

```bash
docker build -t myproject:dev \
  --build-arg INCLUDE_DEV_TOOLS=true \
  --build-arg INCLUDE_NODE=true \
  ...
```

See [CLAUDE.md](CLAUDE.md) for detailed Claude Code configuration.

______________________________________________________________________

## Example Use Cases

### TypeScript API Project

```bash
# Development: Full TypeScript toolchain + debugging tools
docker build -t myapi:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapi \
  --build-arg INCLUDE_NODE=true \
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
  --build-arg INCLUDE_PYTHON=true \
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
  --build-arg INCLUDE_GOLANG=true \
  --build-arg INCLUDE_GOLANG_DEV=true \
  --build-arg INCLUDE_RUST=true \
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

______________________________________________________________________

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

The container system includes a version checker to identify when newer versions
of pinned tools are available:

```bash
# Check all pinned versions
./containers/bin/check-versions.sh

# Output in JSON format (for CI integration)
./containers/bin/check-versions.sh --json

# With GitHub token (to avoid rate limits)
GITHUB_TOKEN=ghp_your_token ./containers/bin/check-versions.sh

# Or add to .env file (from project root; containers/ is a git submodule)
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
1. Creates a pull request with version updates when available
1. Auto-merges after CI tests pass (if configured)

The workflow creates PRs with updated versions that can be reviewed before
merging.

### Updating Versions

When updates are available, edit the appropriate files:

- Language versions: Update `ARG *_VERSION` in `Dockerfile`
- Tool versions: Update version variables in `lib/features/*.sh`

### Version Specification Strategy

The build system supports **two version specification strategies** depending on
whether you're installing a language runtime or a utility tool:

#### Languages (Partial Version Support)

**Supported Languages:** Python, Node.js, Rust, Ruby, Go, Java

**Partial versions are supported** and automatically resolve to the latest patch
version:

```bash
# All of these work:
PYTHON_VERSION="3.12"        # → Resolves to 3.12.12 (latest patch)
PYTHON_VERSION="3.12.7"      # → Uses exact version
PYTHON_VERSION="3"           # → Resolves to 3.13.1 (latest stable)

NODE_VERSION="20"            # → Resolves to 20.19.5 (latest LTS patch)
RUST_VERSION="1.84"          # → Resolves to 1.84.1 (latest patch)
```

**Why use partial versions?**

- ✅ **Automatic security updates** - Get latest patches without manual version
  bumps
- ✅ **Pinned checksums** - Latest patches use git-tracked checksums (Tier 2
  verification)
- ✅ **Simpler configuration** - Specify major.minor, get best patch
  automatically
- ✅ **Weekly auto-updates** - CI automatically updates pinned checksums for
  latest patches

**When to use exact versions:**

- Strict reproducibility requirements
- Testing specific version behavior
- Known issues with latest patch

#### Tools (Exact Version Required)

**Examples:** npm, gh (GitHub CLI), kubectl, helm, terraform, etc.

**Exact versions are required:**

```bash
# Tools require exact versions:
GH_VERSION="2.60.1"          # ✓ Correct
GH_VERSION="2.60"            # ✗ Error - partial not supported

KUBECTL_VERSION="1.31.4"     # ✓ Correct
KUBECTL_VERSION="1.31"       # ✗ Error - partial not supported
```

**Why exact versions only?**

- Reduces maintenance burden (dozens of tools vs. 6 languages)
- Tools change less frequently than language patches
- Most users pin exact tool versions anyway

### Checksum Verification (4-Tier Security)

All downloads are verified using a **4-tier progressive security system** that
tries the most secure method first and falls back gracefully:

#### Tier 1: GPG Signature Verification (Best)

Cryptographic proof using publisher's public key.

- **Available for:** Python, Node.js, Go (framework ready, full implementation
  in progress)
- **Security:** ✅ Highest - proves authenticity via cryptographic signature
- **Process:** Downloads `.asc` signature file and verifies against publisher's
  GPG key

```text
🔐 TIER 1: Attempting GPG signature verification
   Fetching signature from python.org...
   ✅ TIER 1 VERIFICATION PASSED
   Security: Cryptographically verified by publisher
```

#### Tier 2: Pinned Checksums (Good)

Git-tracked checksums from `lib/checksums.json`.

- **Available for:** Languages (latest patches), common tool versions
- **Security:** ✅ High - git-tracked, auditable, reviewed
- **Updates:** Weekly via auto-patch workflow

```text
📌 TIER 2: Checking pinned checksums database
   ✓ Found pinned checksum in git-tracked database
   ✅ TIER 2 VERIFICATION PASSED
   Security: Git-tracked checksum, auditable and reviewed
```

**Trigger Tier 2:** Use partial versions for languages:

```bash
PYTHON_VERSION="3.12"  # Uses Tier 2 for latest 3.12.x patch
```

#### Tier 3: Published Checksums (Acceptable)

Download checksum from official publisher (e.g., python.org, nodejs.org).

- **Available for:** Most languages when version not in checksums.json
- **Security:** ⚠️ Medium - MITM vulnerable but better than calculating
- **Process:** Fetches checksum from publisher's server, compares to download

```text
🌐 TIER 3: Fetching published checksum from official source
   Checking python.org FTP directory...
   ✓ Retrieved checksum from official publisher
   ✅ TIER 3 VERIFICATION PASSED
   Security: Downloaded from official source (MITM risk remains)
```

**Trigger Tier 3:** Specify exact version not in checksums.json:

```bash
PYTHON_VERSION="3.12.7"  # If 3.12.7 not in checksums.json, uses Tier 3
```

#### Tier 4: Calculated Checksums (Fallback)

Calculate checksum of downloaded file (TOFU - Trust On First Use).

- **Available for:** All downloads (fallback only)
- **Security:** ⚠️ Low - no external verification, MITM vulnerable
- **Warning:** Prominent warning box displayed during build

```text
⚠️  TIER 4: Using calculated checksum (FALLBACK)

   ╔════════════════════════════════════════════════════════════╗
   ║                    SECURITY WARNING                        ║
   ╠════════════════════════════════════════════════════════════╣
   ║ No trusted checksum available for verification.            ║
   ║                                                            ║
   ║ Using TOFU (Trust On First Use) - calculating checksum     ║
   ║ from downloaded file without external verification.        ║
   ║                                                            ║
   ║ Risk: Vulnerable to man-in-the-middle attacks.             ║
   ╚════════════════════════════════════════════════════════════╝
```

**This happens when:**

- Using tool version not in checksums.json
- Using older language version without published checksums
- Publisher doesn't provide checksums

#### How the System Works

For every download, the system:

1. **Attempts Tier 1** (GPG) if available for that tool
1. **Falls back to Tier 2** (pinned checksums) if GPG unavailable
1. **Falls back to Tier 3** (published checksums) if not pinned
1. **Falls back to Tier 4** (calculated) as last resort
1. **Logs detailed explanation** of which tier succeeded and why

**Result:** You get the **best available security** for every download with
**full transparency** about verification method.

______________________________________________________________________

## Testing

The project includes a comprehensive test suite across unit and integration
tests. Run `./tests/run_all.sh` to see current counts.

### Unit Tests

Unit tests validate individual components and scripts:

```bash
# Run all unit tests (no Docker required)
./tests/run_unit_tests.sh

# Run specific test suite
./tests/unit/features/python.sh
./tests/unit/base/logging.sh
```

**Unit Test Coverage:**

- ✅ Covers all features and utilities
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

To verify installed features in a running container:

```bash
# Inside the container - check all installed tool versions
check-installed-versions.sh

# Check build logs for any issues
check-build-logs.sh
```

______________________________________________________________________

## Security Features

This build system includes comprehensive security hardening:

### Build-Time Security

- **Checksum Verification**: All downloaded binaries verified with SHA256/SHA512
  checksums
- **Atomic Operations**: Directory creation uses atomic `install -d` to prevent
  TOCTOU attacks
- **Secure Temporary Files**: Restrictive permissions (700) on all temporary
  directories
- **Input Validation**: Function inputs sanitized against command injection
- **Completion Script Safety**: Shell completions validated before sourcing

### Runtime Security

- **Configuration Validation**: Optional runtime validation of environment
  variables, format checking, and secret detection (see
  [examples/validation/](examples/validation/))
- **Rate Limiting**: Exponential backoff for external API calls with
  configurable retry logic
- **GitHub API Token Support**: Automatic detection and use of `GITHUB_TOKEN`
  for higher rate limits
- **Non-Root Execution**: All containers run as non-root user by default
- **Minimal Attack Surface**: Only install features you actually need

### Configuration Options

```bash
# Passwordless sudo (disabled by default for security)
# Enable for local development convenience:
--build-arg ENABLE_PASSWORDLESS_SUDO=true   # Development only
# Keep disabled for production (default):
--build-arg ENABLE_PASSWORDLESS_SUDO=false  # Production (default)

# Configure retry behavior
-e RETRY_MAX_ATTEMPTS=5
-e RETRY_INITIAL_DELAY=2
-e RETRY_MAX_DELAY=30
```

For detailed security information, see [SECURITY.md](SECURITY.md).

______________________________________________________________________

## Security Considerations

### Docker Socket Usage

When using the `INCLUDE_DOCKER=true` feature, you may need to mount the Docker
socket to manage containers from within your dev environment.

#### Development Use (Recommended)

**Use Case**: Local development where your main container needs to manage
dependency containers (databases, Redis, message queues, etc.)

**Configuration**:

```yaml
# docker-compose.yml or .devcontainer/docker-compose.yml
services:
  devcontainer:
    build:
      context: ..
      dockerfile: containers/Dockerfile
      args:
        INCLUDE_DOCKER: 'true'
        INCLUDE_PYTHON_DEV: 'true'
        # Enable passwordless sudo so entrypoint can fix Docker socket permissions
        ENABLE_PASSWORDLESS_SUDO: 'true'
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock # ⚠️ Development only
      - ..:/workspace/myproject
    command: ['sleep', 'infinity']
```

For **VS Code Dev Containers**, also set in `devcontainer.json`:

```json
{
  // Allow container's ENTRYPOINT to run (fixes Docker socket permissions)
  "overrideCommand": false
}
```

**How it works**:

- The container entrypoint automatically detects the Docker socket
- Creates a `docker` group and sets socket permissions to `660`
- Adds the container user to the `docker` group
- Uses passwordless sudo for privilege operations (non-root containers)
- Works on Linux, macOS, WSL2, and Docker Desktop

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
- **Only use in local development environments**

#### Production Use (Not Recommended)

**❌ DO NOT** mount the Docker socket in production containers:

```yaml
# ❌ INSECURE - Never do this in production
services:
  app:
    image: myapp:prod
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock # ❌ Dangerous!
```

**Alternatives for Production**:

1. **Docker-in-Docker (DinD)**: Run Docker daemon inside container (for CI/CD)
1. **Docker API**: Use restricted Docker API with limited permissions
1. **Kubernetes**: Use Kubernetes API instead of Docker
1. **External orchestration**: Let CI/CD system manage containers

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

### Passwordless Sudo

**Default**: Passwordless sudo is **DISABLED** by default (as of v4.8.7) for
security.

#### Development Use (Enable When Needed)

**Use Case**: Local development where you need to:

- Install additional system packages during runtime
- Fix file permissions quickly
- Debug system-level issues
- Run commands that require root without password prompts

```yaml
# docker-compose.yml for development
services:
  devcontainer:
    build:
      context: ..
      dockerfile: containers/Dockerfile
      args:
        INCLUDE_PYTHON_DEV: 'true'
        # Enable for local dev convenience
        ENABLE_PASSWORDLESS_SUDO: 'true' # ⚠️ Development only
```

**Why this is useful for development**:

- Quickly install packages: `sudo apt install <package>` (no password)
- Fix permission issues: `sudo chown developer:developer file`
- Test system configurations without password interruptions
- Streamline development workflow on your local machine

**Security Impact**:

- ⚠️ **Any compromised process can gain root access**
- No password barrier for privilege escalation
- Acceptable risk for **local development** on your personal machine
- **NOT acceptable** for production or shared environments

#### Production Use (Keep Disabled)

**✅ RECOMMENDED**: Keep passwordless sudo disabled in production (default):

```dockerfile
# Explicitly set for production (or omit - false is default)
--build-arg ENABLE_PASSWORDLESS_SUDO=false
```

**Alternatives for Production**:

1. **Pre-install everything at build time**: Use RUN commands in Dockerfile
1. **Init containers**: Use Kubernetes init containers for setup
1. **Proper IAM/RBAC**: Use cloud provider IAM instead of sudo
1. **Configuration management**: Use proper deployment tools

**Production Security Best Practices**:

- ❌ Never enable passwordless sudo in production
- ✅ Install all required packages during build
- ✅ Use least-privilege principles
- ✅ User can still sudo with password if absolutely necessary

#### Socket and Sudo Security Best Practices

1. **Only enable passwordless sudo in trusted environments**

   - ✅ Local development on your personal machine
   - ✅ Isolated development containers
   - ❌ Production deployments
   - ❌ Shared development environments
   - ❌ CI/CD systems (should build at build time)

1. **Only mount socket in trusted environments**

   - ✅ Local development on your machine
   - ✅ Isolated development containers
   - ❌ Production deployments
   - ❌ Multi-tenant environments
   - ❌ Containers running untrusted code

1. **Use least-privilege alternatives when possible**

   - Consider rootless Docker
   - Use Docker contexts with limited access
   - Explore Docker socket proxies with ACLs

1. **Monitor socket access**

   - Audit what containers access the socket
   - Log Docker API calls in sensitive environments

For more security guidance, see [SECURITY.md](SECURITY.md).

### Passwordless Sudo Access

By default, passwordless sudo is **disabled** for security. For development
environments that need Docker socket access or frequent system modifications,
you can enable it explicitly.

#### Development Use (Enable Explicitly)

```bash
# Enable passwordless sudo for development
docker build -t myapp:dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapp \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg ENABLE_PASSWORDLESS_SUDO=true \
  .
```

**Why this is useful for development**:

- Quickly install system packages during development
- Test installation scripts without password prompts
- Standard development container behavior

**Security Impact**:

- ⚠️ **Non-root user can execute any command as root without password**
- Container escape could grant full host access (if combined with other
  vulnerabilities)
- Suitable for trusted development environments only

#### Production Use (Default)

```bash
# Production: Passwordless sudo disabled by default
docker build -t myapp:prod \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapp \
  --build-arg INCLUDE_PYTHON=true \
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

#### Production Deployment Security Best Practices

1. **Use separate builds for dev and prod**

   ```bash
   # scripts/build-dev.sh
   docker build --build-arg ENABLE_PASSWORDLESS_SUDO=true ...

   # scripts/build-prod.sh
   docker build --build-arg ENABLE_PASSWORDLESS_SUDO=false ...
   ```

1. **Review sudo requirements**

   - If your application never needs sudo, disable it
   - If only specific commands need sudo, configure sudoers accordingly
   - Consider removing sudo entirely for runtime-only containers

1. **Layer your security**

   - Disable passwordless sudo
   - Use read-only filesystems where possible
   - Drop unnecessary capabilities
   - Use security profiles (AppArmor, SELinux)

### Zombie Process Reaping (Init System)

Containers using `sleep infinity` or long-running processes can accumulate
zombie processes when child processes (e.g., from pre-commit hooks, git
operations) are orphaned. This happens because the main process (PID 1) doesn't
implement `wait()` to reap child processes.

#### Built-in Protection

This container system includes **tini** as an init system wrapper, which:

- Properly reaps zombie processes
- Forwards signals to child processes
- Ensures clean container shutdown

The Dockerfile uses tini in the ENTRYPOINT:

```dockerfile
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
```

#### Belt-and-Suspenders: Docker Compose `init: true`

For extra protection (especially when `command:` overrides the entrypoint), add
`init: true` to your docker-compose services:

```yaml
services:
  devcontainer:
    build:
      context: ..
      dockerfile: containers/Dockerfile
    # Ensures proper zombie reaping even if command overrides entrypoint
    init: true
    command: ['sleep', 'infinity']
```

#### Diagnosing Zombie Processes

If you suspect zombie accumulation:

```bash
# Count zombie processes
ps aux | grep -c 'Z'

# List zombie processes with parent info
ps -eo pid,ppid,stat,cmd | grep ' Z'
```

#### When to Use `init: true`

- ✅ Always recommended for development containers
- ✅ Containers running `sleep infinity`
- ✅ Containers spawning many child processes (pre-commit, test runners)
- ✅ Long-running containers (days/weeks uptime)

______________________________________________________________________

## Best Practices

### Security: Handling Secrets

#### ⚠️ Critical: Never Pass Secrets as Build Arguments

Build arguments are **permanently stored** in Docker images and visible in
multiple locations:

- **Docker build logs** - Plain text output during build
- **Image history** - `docker history <image>` reveals all build args
- **Container inspection** - `docker inspect <container>` exposes build-time
  values
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

1. **Docker Secrets** (recommended for Docker Swarm/Compose):

   ```bash
   # Create secret
   echo "secret123" | docker secret create api_key -

   # Use in service
   docker service create --secret api_key my-image:latest
   ```

1. **Mounted Config Files** (recommended for sensitive files):

   ```bash
   # Mount secrets directory read-only
   docker run -v ./secrets:/secrets:ro my-image:latest
   ```

1. **Secret Management Tools** (recommended for production):

   ```bash
   # 1Password CLI (included via INCLUDE_OP=true)
   docker run -e OP_SERVICE_ACCOUNT_TOKEN=... my-image:latest

   # AWS Secrets Manager, Vault, etc.
   docker run -e AWS_REGION=us-east-1 my-image:latest
   ```

For more information, see `/workspace/containers/SECURITY.md`.

______________________________________________________________________

### General Best Practices

1. **Choose the right base image**:

   - `debian:trixie-slim` (Debian 13): Default, latest features (default)
   - `debian:bookworm-slim` (Debian 12): Stable release, good compatibility
   - `debian:bullseye-slim` (Debian 11): Older stable release
   - `ubuntu:24.04`: More packages available, larger size
   - `mcr.microsoft.com/devcontainers/base:trixie`: VS Code optimized

1. **Optimize build times**:

   - Only include features you actually need
   - Use BuildKit cache mounts (already configured)
   - Layer expensive operations early in the Dockerfile

1. **Security considerations**:

   - Always use non-root users in production
   - Remove passwordless sudo in production builds
     (`ENABLE_PASSWORDLESS_SUDO=false`)
   - **Never pass secrets as build arguments** - they're stored permanently in
     the image
   - Mount secrets at runtime, don't bake them in
   - Regularly update the submodule for security patches
   - See detailed security guidance below

1. **Version pinning**:

   - Pin the submodule to specific commits for stability
   - Use version build arguments for reproducible builds
   - Document version requirements in your project

1. **Build context**:

   - The build context should be your project root (where you run
     `docker build .`)
   - The Dockerfile path is `-f containers/Dockerfile`
   - Your project files are available for COPY commands during build
   - Use `.dockerignore` to exclude sensitive files from build context

______________________________________________________________________

## Contributing

Contributions are welcome! For detailed guidelines, see
[CONTRIBUTING.md](CONTRIBUTING.md).

### Contributing Quick Start

1. Fork the repository

1. **Run the development environment setup**:

   ```bash
   ./bin/setup-dev-environment.sh
   ```

   This will:

   - Enable git hooks for shellcheck and credential leak prevention
   - Verify your development environment
   - Check for recommended tools

1. Create a feature branch

1. Add tests for new features

1. Submit a pull request

See [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Feature script guidelines and templates
- Error handling best practices
- Testing requirements
- Code style guidelines
- Pull request process

See [.pre-commit-config.yaml](.pre-commit-config.yaml) for configuration options.

______________________________________________________________________

## Rollback and Emergency Procedures

### Rollback/Downgrade

If a release introduces critical issues, see
**[docs/operations/rollback.md](docs/operations/rollback.md)** for:

- Quick rollback commands
- Auto-patch revert procedures
- Emergency hotfix workflows
- Post-incident procedures

### Quick Rollback

```bash
# Revert problematic version
git revert --no-commit <bad_commit>
git commit -m "emergency: Rollback vX.Y.Z"

# Delete bad release and create patch
gh release delete vX.Y.Z --yes --cleanup-tag
./bin/release.sh --full-auto patch
```

### Release Channels

- **Stable releases** (`v4.6.0`): Manual, thoroughly tested
- **Auto-patch releases**: Automated dependency updates, may revert more
  frequently

**Recommendation**: Pin production to specific stable versions.

______________________________________________________________________

## License

MIT License - see LICENSE file for details
