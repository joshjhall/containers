# Universal Container Build System

[![CI/CD Pipeline](https://github.com/joshjhall/containers/actions/workflows/ci.yml/badge.svg)](https://github.com/joshjhall/containers/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> **v5 development branch** — This is a major rewrite. For the stable v4
> release, see the `main` branch.

A modular, extensible container build system that creates purpose-specific
containers — from minimal agent images to full-featured development
environments — across multiple Linux distributions. Configure with a CLI/TUI,
build with a single Dockerfile, and manage everything from project setup to
runtime with three compiled Rust tools.

## What's New in v5

- **Multi-distro support** — Debian, Alpine, RHEL/UBI, and Ubuntu. More
  planned.
- **No git submodule required** — Install the CLI locally via Homebrew, apt,
  or cargo. Generate and update configs with `stibbons init` /
  `stibbons update`.
- **Manifest-driven installs** — Compiled Rust replaces bash scripts for
  speed, robustness, security, and enterprise auditability at every step.
- **Distro-aware version resolution** — Automatically selects compatible
  tool versions per distro and distro version (e.g., knows biome only
  supports Debian 11 through v2.3.x).
- **Hierarchical configuration** — Define best practices at global, team,
  project, and individual developer levels.
- **Automated dependency updates** — Pin some versions, auto-update others,
  per environment.
- **Enterprise audit trail** — Every install step is logged, checksummed,
  and traceable with minimal integration effort.
- **34 feature modules** — Same broad feature set as v4 (Python, Node.js,
  Rust, Go, Ruby, Java, R, Kotlin, Mojo, Android, cloud tools, databases,
  and more).

---

## Architecture

v5 is built around three compiled Rust executables:

### stibbons — Project Manager

Runs on the **host** and inside **containers**. The primary user-facing tool.

- Interactive TUI wizard and non-interactive CLI
- Project initialization, configuration, and updates
- Worktree and agent management for parallel development
- Installable via Homebrew, apt, cargo, or pre-built binary
- Planned alias: `cbs`

```bash
# Install (examples — packaging not yet available)
brew install joshjhall/tap/stibbons
cargo install stibbons

# Initialize a new project
stibbons init

# Update configuration after changing features
stibbons update
```

### igor — Runtime Manager

Runs **inside containers only**. Manages the runtime environment after the
container is built.

- 1Password secret resolution (`OP_*_REF` → environment variables)
- Post-create and post-start hooks
- Claude Code setup, plugin installation, and auth watcher
- Git identity and SSH key configuration
- Service health checks

### luggage — Build Engine

The **heart of the system**. Not user-facing — called by stibbons and the
Dockerfile during builds.

- Manifest-driven feature installation across the full matrix of distro ×
  distro version × feature × feature version
- Distro-aware version constraints and compatibility checks
- Coarse dependency conflict detection between tools
- Manifest data stored in downloadable per-distro databases (SQLite)
- Full audit logging of every install step
- Checksum verification (4-tier: GPG → pinned → published → calculated)

---

## Quick Start

### Install the CLI

```bash
# Via Homebrew (macOS/Linux) — coming soon
brew install joshjhall/tap/stibbons

# Via cargo
cargo install stibbons

# Or build from source
git clone https://github.com/joshjhall/containers.git
cd containers && cargo build --release
```

### Initialize a Project

```bash
cd your-project
stibbons init
```

The interactive wizard walks you through selecting:

1. Base distro (Debian, Alpine, RHEL/UBI, Ubuntu)
1. Languages and dev tools
1. Cloud providers and infrastructure tools
1. Database clients and utilities

It generates: `docker-compose.yml`, `devcontainer.json`, `.env`,
`.env.example`, and `.stibbons.yml` (project config).

### Build and Run

```bash
# Build using the generated configuration
docker compose build

# Start the development container
docker compose up -d

# Or with VS Code Dev Containers — just reopen in container
```

### Update Configuration

```bash
# Add a feature
stibbons add python --dev

# Regenerate files after config changes
stibbons update

# Check for available tool version updates
stibbons check-versions
```

---

## Available Features

All features are enabled via `INCLUDE_<FEATURE>=true` build arguments or
through the `stibbons` CLI.

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
| **Ruby**       | `INCLUDE_RUBY=true`       | Ruby 4.0+, bundler                              |
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

### Infrastructure and Cloud

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

| Feature       | Build Arg                | What's Included                                            |
| ------------- | ------------------------ | ---------------------------------------------------------- |
| **Dev Tools** | `INCLUDE_DEV_TOOLS=true` | Claude Code CLI, git, gh CLI, lazygit, fzf, ripgrep, bat   |
| **1Password** | `INCLUDE_OP=true`        | 1Password CLI (auto-loads tokens from 1Password)           |
| **Ollama**    | `INCLUDE_OLLAMA=true`    | Local LLM support                                          |
| **Cron**      | `INCLUDE_CRON=true`      | Cron daemon for scheduled tasks (auto with Rust/Dev Tools) |
| **Bindfs**    | `INCLUDE_BINDFS=true`    | FUSE overlay for macOS VirtioFS permission fixes           |

---

## Multi-Distro Support

v5 adds support for multiple base distributions. The `luggage` build engine
automatically adapts package names, install commands, and version constraints
per distro.

| Distro       | Status      | Base Images                                   |
| ------------ | ----------- | --------------------------------------------- |
| **Debian**   | Supported   | `debian:trixie-slim`, `debian:bookworm-slim`  |
| **Alpine**   | In progress | `alpine:3.21`                                 |
| **RHEL/UBI** | In progress | `registry.access.redhat.com/ubi9/ubi-minimal` |
| **Ubuntu**   | In progress | `ubuntu:24.04`                                |
| More planned | Future      | Fedora, openSUSE, Wolfi, etc.                 |

Distro selection is configured via `stibbons init` or the `BASE_IMAGE` build
argument.

---

## Configuration Hierarchy

v5 supports layered configuration that merges settings from multiple levels:

| Level          | Location                | Purpose                               |
| -------------- | ----------------------- | ------------------------------------- |
| **Global**     | `~/.config/stibbons/`   | Personal defaults across all projects |
| **Team**       | Shared repo or registry | Organization-wide standards           |
| **Project**    | `.stibbons.yml`         | Project-specific features and pins    |
| **Individual** | `.stibbons.local.yml`   | Per-developer overrides (gitignored)  |

Each level can pin versions, require features, set tool configurations
(Claude Code, 1Password, etc.), and define update policies.

---

## Testing

v5 improves the testing story with faster, more isolated test execution:

- **Unit tests** — Test individual components without Docker
- **Feature tests** — Test a single feature's installation in isolation
- **Integration tests** — Full container builds with feature combinations
- **Rust tests** — `cargo test --workspace` for all compiled components

Common tasks are wired into the `justfile` — run `just` to list all recipes.

```bash
just test-all                    # everything (requires Docker)
just test                        # unit + rust + lints (no Docker)
just test-feature python-dev     # test one feature in isolation
just test-rust                   # cargo test --workspace
just test-integration            # full integration suite
```

---

## Claude Code Integration

When `INCLUDE_DEV_TOOLS=true`, containers include full Claude Code support:

- **Claude Code CLI** with auto-setup and auth watcher
- **MCP servers** — Filesystem, GitHub/GitLab integration (requires Node.js)
- **LSP plugins** — Language-specific plugins based on enabled features
- **Skills and agents** — 17+ skills and 11 agents for development workflows

Configuration is managed through the configuration hierarchy — set model
preferences, plugins, MCP servers, and skills at any level.

---

## Migrating from v4

v5 replaces the git submodule approach with a standalone CLI:

| v4 (submodule)                     | v5 (CLI)                         |
| ---------------------------------- | -------------------------------- |
| `git submodule add ...`            | `brew install stibbons`          |
| `cd containers && go build igor`   | Already compiled                 |
| `igor init`                        | `stibbons init`                  |
| Update via `git pull` in submodule | `stibbons self-update`           |
| Debian only                        | Debian, Alpine, RHEL/UBI, Ubuntu |
| Bash install scripts               | Compiled manifest-driven engine  |

The Dockerfile and docker-compose.yml formats remain compatible. Existing
`.devcontainer/` setups should work with minimal changes.

---

## Security

v5 maintains all v4 security features and adds enterprise auditability:

- **4-tier checksum verification** — GPG, pinned, published, calculated
- **Non-root execution** — All containers run as non-root by default
- **Audit logging** — Every install step logged with checksums and sources
- **In-memory secrets** — 1Password values written to tmpfs, never touch disk
- **Init system** — tini for proper zombie reaping and signal forwarding

For detailed security guidance, see [docs/security-hardening.md](docs/security-hardening.md).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. The v5 codebase is
primarily Rust — contributions to any of the three crates (stibbons, igor,
luggage) are welcome.

```bash
just build       # cargo build --workspace
just test        # full pre-commit test suite
just lint        # every lefthook pre-commit hook on all files
just install-hooks  # lefthook install (pre-commit + pre-push)
```

**Prose linting**: run `vale sync` once in a dev-tools container to fetch
the styles declared in `.vale.ini`. The pre-commit `vale` hook is
warn-only and skips silently until styles are synced.

---

## License

MIT License — see LICENSE file for details.
