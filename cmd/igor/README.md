# Igor — Devcontainer Setup Wizard

Igor is a TUI wizard that scaffolds complete devcontainer configurations from
the containers submodule. Instead of manually assembling 20+ Docker build
arguments, docker-compose files, and VS Code settings, igor walks you through
an interactive feature selection and generates everything in seconds.

## Installation

### From source (recommended)

Requires Go 1.23+:

```bash
cd containers/cmd/igor
go build -o igor .
```

The binary is at `containers/cmd/igor/igor`. Move it to your PATH or run it
directly.

### From within a dev container

If your container was built with `INCLUDE_GOLANG=true`:

```bash
cd /workspace/project/containers/cmd/igor
go build -o /usr/local/bin/igor .
```

## Quick Start

From your project root (where the `containers/` submodule lives):

```bash
./containers/cmd/igor/igor init
```

The wizard walks through five steps:

1. **Project Configuration** — project name, username, base image, submodule path
1. **Language Selection** — Python, Node.js, Rust, Go, Ruby, Java, R, Mojo, Kotlin, Android
1. **Dev Tools** — LSP servers, linters, formatters for each language
1. **Cloud & Infrastructure** — Kubernetes, Terraform, AWS, GCloud, Cloudflare
1. **Tools & Services** — Dev Tools (Claude Code, fzf, etc.), Docker, 1Password, database clients, Ollama

After selection, igor shows a review screen with:

- Your explicit selections
- Auto-resolved dependencies (e.g., selecting `rust_dev` auto-adds `rust` and `cron`)
- The list of files that will be generated

Confirm to generate all files.

### Example Session

```text
$ ./containers/cmd/igor/igor init

  Project Configuration
  ─────────────────────

  Project name: mywebapp
  Container username: developer
  Base image: Debian Trixie (13) — stable
  Containers submodule path: containers

  Language Selection
  ──────────────────

  > [x] Python — Python runtime
    [x] Node.js — Node.js runtime
    [ ] Rust — Rust toolchain
    ...

  Dev Tools
  ─────────

  > [x] Python Dev — Python development tools (linters, formatters, LSP)
    [x] Node.js Dev — Node.js development tools (LSP, debug)
    ...

  Cloud & Infrastructure
  ──────────────────────

  > [x] AWS CLI — AWS command-line interface
    ...

  Tools & Services
  ────────────────

  > [x] Dev Tools — General development tools (git extras, fzf, Claude Code CLI)
    [x] Docker — Docker CLI tools
    [x] PostgreSQL Client — PostgreSQL client tools (psql)
    ...

  Configuration Review

  Project: mywebapp
  User:    developer
  Base:    debian:trixie-slim
  Path:    containers

  Selected features:
  + Python
  + Python Dev
  + Node.js
  + Node.js Dev
  + AWS CLI
  + Dev Tools
  + Docker
  + PostgreSQL Client

  Auto-resolved dependencies:
  ~ Bindfs
  ~ Cron

  Files to generate:
  .devcontainer/docker-compose.yml
  .devcontainer/devcontainer.json
  .devcontainer/.env
  .env.example
  .igor.yml

  Generate these files? Yes, generate files

Files generated successfully:
  .devcontainer/docker-compose.yml
  .devcontainer/devcontainer.json
  .devcontainer/.env
  .env.example
  .igor.yml

Next steps:
  1. Review the generated files
  2. Commit .igor.yml and .devcontainer/ to your repo
  3. Open in VS Code with Remote-Containers, or run:
     docker compose -f .devcontainer/docker-compose.yml up -d
```

## Non-Interactive Mode

For CI pipelines or scripted setups, use `--non-interactive` with a config file:

```bash
igor init --non-interactive --config .igor.yml
```

This reads all selections from the `.igor.yml` file and generates output
without any prompts. Useful for:

- CI/CD pipelines that regenerate devcontainer config
- Scripted project bootstrapping
- Reproducing a known configuration on a new machine

## `.igor.yml` Reference

The `.igor.yml` file is both the output state file and the input for
non-interactive mode.

```yaml
# Schema version for future migration support
schema_version: 1

# Relative path to the containers submodule
containers_dir: containers

# Project-level settings
project:
  name: myapp             # Used for workspace directory and compose project
  username: developer     # Non-root container user
  base_image: "debian:trixie-slim"  # Debian base image

# Explicitly selected feature IDs (auto-resolved deps are not listed)
features:
  - python
  - python_dev
  - node
  - node_dev
  - dev_tools
  - docker

# Version overrides (optional — defaults come from the feature registry)
versions:
  PYTHON_VERSION: "3.14.0"
  NODE_VERSION: "22.12.0"

# Tracks generated file paths and their SHA-256 hashes (managed by igor)
generated:
  .devcontainer/docker-compose.yml: "sha256:..."
  .devcontainer/devcontainer.json: "sha256:..."
```

### Field Reference

| Field                 | Type              | Description                                                 |
| --------------------- | ----------------- | ----------------------------------------------------------- |
| `schema_version`      | int               | Always `1`. For future migration support.                   |
| `containers_dir`      | string            | Relative path to containers submodule (e.g., `containers`). |
| `containers_ref`      | string            | Optional git ref (tag/commit) of the containers submodule.  |
| `project.name`        | string            | Project name, used for workspace directory.                 |
| `project.username`    | string            | Non-root user inside the container.                         |
| `project.base_image`  | string            | Debian base image for the build.                            |
| `project.working_dir` | string            | Optional workspace directory override.                      |
| `features`            | []string          | List of explicitly selected feature IDs.                    |
| `versions`            | map[string]string | Version arg overrides (e.g., `PYTHON_VERSION: "3.14.0"`).   |
| `generated`           | map[string]string | SHA-256 hashes of generated files (managed by igor).        |

## Feature Reference

<!-- Generated from cmd/igor/internal/feature/registry.go — regenerate with:
     cd cmd/igor && go run ./tools/gen-feature-docs (future)
     For now, keep in sync manually when registry changes. -->

### Languages

| ID            | Display Name | Description                                         | Version Arg      | Default Version | Requires      |
| ------------- | ------------ | --------------------------------------------------- | ---------------- | --------------- | ------------- |
| `python`      | Python       | Python runtime                                      | `PYTHON_VERSION` | 3.14.0          | —             |
| `python_dev`  | Python Dev   | Python development tools (linters, formatters, LSP) | —                | —               | python        |
| `node`        | Node.js      | Node.js runtime                                     | `NODE_VERSION`   | 22.12.0         | —             |
| `node_dev`    | Node.js Dev  | Node.js development tools (LSP, debug)              | —                | —               | node          |
| `rust`        | Rust         | Rust toolchain                                      | `RUST_VERSION`   | 1.83.0          | —             |
| `rust_dev`    | Rust Dev     | Rust development tools (rust-analyzer, clippy)      | —                | —               | rust, cron    |
| `golang`      | Go           | Go toolchain                                        | `GO_VERSION`     | 1.23.4          | —             |
| `golang_dev`  | Go Dev       | Go development tools (gopls, dlv)                   | —                | —               | golang        |
| `ruby`        | Ruby         | Ruby runtime                                        | `RUBY_VERSION`   | 3.4.1           | —             |
| `ruby_dev`    | Ruby Dev     | Ruby development tools (solargraph, rubocop)        | —                | —               | ruby          |
| `java`        | Java         | Java JDK                                            | `JAVA_VERSION`   | 21              | —             |
| `java_dev`    | Java Dev     | Java development tools (jdtls)                      | —                | —               | java          |
| `r`           | R            | R statistical computing                             | `R_VERSION`      | 4.4.2           | —             |
| `r_dev`       | R Dev        | R development tools (languageserver)                | —                | —               | r             |
| `mojo`        | Mojo         | Mojo programming language                           | `MOJO_VERSION`   | 25.4            | —             |
| `mojo_dev`    | Mojo Dev     | Mojo development tools                              | —                | —               | mojo          |
| `kotlin`      | Kotlin       | Kotlin programming language (auto-installs Java)    | `KOTLIN_VERSION` | 2.3.0           | java          |
| `kotlin_dev`  | Kotlin Dev   | Kotlin development tools (kotlin-language-server)   | —                | —               | kotlin, java  |
| `android`     | Android      | Android SDK (auto-installs Java)                    | —                | —               | java          |
| `android_dev` | Android Dev  | Android emulator and system images                  | —                | —               | android, java |

### Tools

| ID          | Display Name  | Description                                                  | Requires | Implied By                  |
| ----------- | ------------- | ------------------------------------------------------------ | -------- | --------------------------- |
| `dev_tools` | Dev Tools     | General development tools (git extras, fzf, Claude Code CLI) | bindfs   | —                           |
| `docker`    | Docker        | Docker CLI tools                                             | —        | —                           |
| `op`        | 1Password CLI | 1Password CLI for secrets management                         | —        | —                           |
| `cron`      | Cron          | Cron daemon (auto-enabled by rust_dev, dev_tools, bindfs)    | —        | rust_dev, dev_tools, bindfs |
| `bindfs`    | Bindfs        | FUSE permission overlay for macOS VirtioFS                   | cron     | dev_tools                   |

### Cloud & Infrastructure

| ID           | Display Name     | Description                            | Requires |
| ------------ | ---------------- | -------------------------------------- | -------- |
| `kubernetes` | Kubernetes       | kubectl, k9s, Helm                     | —        |
| `terraform`  | Terraform        | Terraform and related tools            | —        |
| `aws`        | AWS CLI          | AWS command-line interface             | —        |
| `gcloud`     | Google Cloud SDK | Google Cloud command-line tools        | —        |
| `cloudflare` | Cloudflare       | Cloudflare Wrangler (requires Node.js) | node     |

### Database Clients

| ID                | Display Name      | Description                    |
| ----------------- | ----------------- | ------------------------------ |
| `postgres_client` | PostgreSQL Client | PostgreSQL client tools (psql) |
| `redis_client`    | Redis Client      | Redis client tools (redis-cli) |
| `sqlite_client`   | SQLite Client     | SQLite client tools            |

### AI/ML

| ID       | Display Name | Description       |
| -------- | ------------ | ----------------- |
| `ollama` | Ollama       | Local LLM runtime |

## Feature Dependencies

Dependencies are resolved automatically. When you select a feature, its
`Requires` are added. Features with `ImpliedBy` are auto-added when their
implier is selected.

```text
rust_dev ──Requires──> rust
         ──Requires──> cron

dev_tools ──Requires──> bindfs ──Requires──> cron
                        bindfs <──ImpliedBy── dev_tools
                        cron   <──ImpliedBy── dev_tools
                        cron   <──ImpliedBy── bindfs
                        cron   <──ImpliedBy── rust_dev

kotlin ──Requires──> java
kotlin_dev ──Requires──> kotlin, java

android ──Requires──> java
android_dev ──Requires──> android, java

cloudflare ──Requires──> node
```

In practice: selecting `dev_tools` automatically adds `bindfs` and `cron`.
Selecting `kotlin_dev` automatically adds `kotlin` and `java`.

## Generated Files

Igor generates five files:

| File                               | Purpose                                                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `.devcontainer/docker-compose.yml` | Docker Compose build definition with all selected features as build args, cache volumes, and network config. |
| `.devcontainer/devcontainer.json`  | VS Code devcontainer configuration with workspace folder, extensions, and editor settings.                   |
| `.devcontainer/.env`               | Runtime environment variables for the container (language-specific defaults).                                |
| `.env.example`                     | Documented template of all available env vars (committed to repo as reference).                              |
| `.igor.yml`                        | State file tracking your selections, versions, and generated file hashes.                                    |

Each generated file is wrapped in `=== IGOR:BEGIN ===` / `=== IGOR:END ===`
markers. Content between markers is managed by igor and will be overwritten on
regeneration. Content outside markers is preserved, letting you add custom
configuration that survives `igor update`.

## Worked Examples

### 1. Minimal Python Project

From `testdata/minimal.igor.yml`:

```yaml
schema_version: 1
containers_dir: containers
project:
  name: myapp
  username: developer
  base_image: "debian:trixie-slim"
features:
  - python
  - python_dev
```

This generates a container with Python 3.14, pip, pipx, Poetry, uv, plus dev
tools (black, ruff, mypy, pytest, jupyter). Dependencies auto-resolved: none
(python_dev requires python, which is already explicitly listed).

### 2. Full-Stack Development

From `testdata/fullstack.igor.yml`:

```yaml
schema_version: 1
containers_dir: containers
project:
  name: fullstack
  username: dev
  base_image: "debian:bookworm-slim"
features:
  - python
  - python_dev
  - node
  - node_dev
  - rust
  - rust_dev
  - golang
  - golang_dev
  - dev_tools
  - docker
  - op
  - kubernetes
  - terraform
  - aws
  - postgres_client
  - redis_client
  - ollama
```

Auto-resolved dependencies: `cron` (implied by rust_dev, dev_tools),
`bindfs` (implied by dev_tools), `java` is not added since it's not required
by any selected feature.

### 3. Cloud Operations

```yaml
schema_version: 1
containers_dir: containers
project:
  name: infra
  username: ops
  base_image: "debian:trixie-slim"
features:
  - kubernetes
  - terraform
  - aws
  - gcloud
  - docker
  - dev_tools
```

Auto-resolved dependencies: `bindfs` (implied by dev_tools), `cron` (implied
by dev_tools and bindfs). A cloud-ops container with kubectl, Helm, k9s,
Terraform, AWS CLI, GCloud SDK, Docker, and Claude Code.

## CLI Reference

```text
igor [flags]
igor init [flags]
igor version
```

### Global Flags

| Flag                | Description                                                |
| ------------------- | ---------------------------------------------------------- |
| `-v, --verbose`     | Verbose output                                             |
| `--non-interactive` | Run without interactive prompts (requires `--config`)      |
| `--config <path>`   | Path to `.igor.yml` config file (for non-interactive mode) |

### Commands

| Command   | Description                                                      |
| --------- | ---------------------------------------------------------------- |
| `init`    | Initialize devcontainer configuration with an interactive wizard |
| `version` | Print igor and containers version                                |
