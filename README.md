# Universal Container Build System

[![CI/CD Pipeline](https://github.com/joshjhall/containers/actions/workflows/ci.yml/badge.svg)](https://github.com/joshjhall/containers/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/License-MIT%20OR%20Apache--2.0-blue.svg)](#license)

A modular, extensible container build system that creates purpose-specific
containers — from minimal agent images to full-featured development
environments — from a single Dockerfile. Enable features with
`INCLUDE_<FEATURE>=true` build arguments; mix and match languages, cloud
tooling, database clients, and utilities for exactly the image you need.

## Highlights

- **Single Dockerfile, many contexts** — devcontainers, CI/CD images, agent
  containers, and production runtimes all build from the same source.
- **36 feature modules** — Python, Node.js, Rust, Go, Ruby, Java, R, Kotlin,
  Mojo, Android, Docker, Kubernetes, Terraform, AWS, GCloud, Cloudflare,
  database clients, Ollama, 1Password, and more.
- **Deep Claude Code integration** — Claude Code CLI, language-aware LSP
  plugins, MCP servers, skills, and agents auto-install with `DEV_TOOLS`.
- **1Password-backed secrets** — `OP_*_REF` env vars resolve on every
  container start; file secrets land in tmpfs and never touch disk.
- **Cache-aware** — `/cache` volume mount persists `pip`, `npm`, `cargo`,
  `go`, and more across rebuilds.
- **macOS-friendly** — Optional bindfs FUSE overlay fixes VirtioFS
  permission quirks for cross-platform teams.
- **Security by default** — Non-root users, tini as PID 1, checksum
  verification on downloads, hardened install scripts.

---

## Quick Start

The system is designed to live in a project as a git submodule at
`containers/`. The Dockerfile is driven entirely by build arguments.

### Add to an Existing Project

```bash
git submodule add https://github.com/joshjhall/containers.git containers
```

### Build an Image

```bash
# Minimal Python dev image
docker build -t myproject:python-dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  .

# Full-stack dev image
docker build -t myproject:full-dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myproject \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DOCKER=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  .
```

The build context (`.`) must come **last**, after all flags — buildx
misinterprets it otherwise.

### Run It

```bash
docker run -it --rm \
  -v "$(pwd):/workspace/project" \
  -v "myproject-cache:/cache" \
  myproject:full-dev
```

### Docker Compose

See `examples/contexts/devcontainer/docker-compose.yml` and
`examples/contexts/agents/docker-compose.yml` for complete compose
configurations, and `examples/env/*.env` for per-feature env file snippets
you can compose together.

---

## Available Features

All features are enabled with `INCLUDE_<FEATURE>=true` build arguments.
Full dependency graph and version pins live in `docs/reference/features.md`
and `docs/reference/environment-variables.md`.

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

## Base Image

The default base is `debian:trixie-slim`. Debian 11 (Bullseye), 12
(Bookworm), and 13 (Trixie) are auto-detected and supported. Override with
`--build-arg BASE_IMAGE=debian:bookworm-slim` if you need an older base.

See `docs/troubleshooting/debian-compatibility.md` for the version
detection API and known differences.

---

## Testing

All common tasks are wired into the `justfile`. Run `just` to list recipes.

```bash
just test-all                          # unit + integration (requires Docker)
just test                              # unit + lint (no Docker)
just test-integration                  # integration only
just test-integration-one python_dev   # single integration test
just test-feature python-dev           # quick single-feature test in isolation
just lint                              # run every lefthook hook on all files
just db-validate                       # validate sibling containers-db schemas + fixtures
```

When testing Docker builds manually, **always use the integration test
framework** — `./tests/run_integration_tests.sh`. Direct `docker build`
invocations can behave unexpectedly when buildx is the default builder.
See `tests/framework/assertions/docker.sh`.

---

## Claude Code Integration

When `INCLUDE_DEV_TOOLS=true`, the container installs Claude Code CLI and
a curated baseline of plugins, MCP servers, skills, and agents.

- **LSP plugins** — Language-specific LSP servers auto-install alongside
  each `*_DEV` feature (Python → pyright + python-lsp-server, Node →
  typescript-language-server, Rust → rust-analyzer, Go → gopls, etc.)
- **MCP servers** — Filesystem, GitHub/GitLab, Context7, Playwright, and
  others. Override with `CLAUDE_MCPS` or extend with `CLAUDE_EXTRA_MCPS`.
- **Plugins** — 11 core plugins plus language-specific LSP plugins.
  Override with `CLAUDE_PLUGINS` / `CLAUDE_EXTRA_PLUGINS`.
- **Skills and agents** — 39 skills and 17 agents out of the box,
  including `/codebase-audit`, `/next-issue`, and `/next-issue-ship`.
  Override with `CLAUDE_SKILLS` / `CLAUDE_AGENTS` or extend with
  `CLAUDE_EXTRA_*`.
- **Memory system** — Two-tier `.claude/memory/` (committed long-term
  knowledge + gitignored `tmp/` for session state).

Full details in `docs/claude-code/`.

---

## Secrets & Setup

When `INCLUDE_OP=true`, the container resolves secrets from 1Password at
startup:

- `OP_<NAME>_REF=op://vault/item/field` → exports `<NAME>=<value>`
- `OP_<NAME>_FILE_REF=op://...` → writes content to `/dev/shm/` tmpfs and
  exports `<NAME>=<path>`

Values are re-fetched every container start and never touch disk. Three
setup commands are available inside dev-tools containers: `setup-git`,
`setup-gh`, `setup-glab`. Full convention, caching rules, and compose
examples in `docs/claude-code/secrets-and-setup.md`.

---

## Caching

All tool caches live under `/cache` (`pip`, `npm`, `cargo`, `go`,
`bundle`, etc.). Mount as a Docker volume to persist across rebuilds:

```yaml
services:
  dev:
    volumes:
      - myproject-cache:/cache
```

The entrypoint fixes `/cache` permissions on every start. Per-tool cache
paths are listed in `docs/reference/environment-variables.md`.

---

## Security

- **Non-root by default** — `USERNAME` / `USER_UID` / `USER_GID` build args.
- **Checksum verification** on downloaded artifacts.
- **tini as PID 1** — Proper zombie reaping and signal forwarding for
  long-running dev containers. Always set `init: true` in compose files
  as belt-and-suspenders.
- **In-memory secrets** — 1Password file secrets live in tmpfs only.
- **Hardened install scripts** — `set -euo pipefail`, full paths for
  critical commands, no `|| true` on cargo installs.

See `docs/security-hardening.md` for full details.

---

## Cross-Platform Notes

- **macOS / VirtioFS** — Enable `INCLUDE_BINDFS=true` and pass
  `--cap-add SYS_ADMIN --device /dev/fuse` to work around ownership
  mismatches on bind-mounted project directories. Add `.fuse_hidden*` to
  `.gitignore`.
- **Case-insensitive filesystems** — Auto-detected; suppress the warning
  with `SKIP_CASE_CHECK=true`. See
  `docs/troubleshooting/case-sensitive-filesystems.md`.

---

## Release Process

Always use the release script — never hand-edit VERSION.

```bash
just release-patch   # bug fix (4.3.2 -> 4.3.3)
just release-minor   # new feature (4.3.2 -> 4.4.0)
just release-major   # breaking change (4.3.2 -> 5.0.0)
```

The script updates VERSION, Dockerfile, test framework version, and
generates CHANGELOG.md. Then commit, tag (`vX.Y.Z`), and push — the tag
triggers CI to build, test, and publish. See
`docs/development/releasing.md`.

Weekly auto-patches run Sundays at 02:00 UTC on `auto-patch/*` branches;
don't hand-edit those. Full details in
`docs/operations/automated-releases.md`.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for feature-script conventions,
testing requirements, and PR guidelines.

```bash
just install-hooks   # lefthook install (pre-commit + pre-push)
just lint            # run every pre-commit hook
just test            # pre-commit test suite (no Docker)
```

**Prose linting**: run `vale sync` once in a dev-tools container to fetch
styles declared in `.vale.ini`. The pre-commit `vale` hook is warn-only
and skips silently until styles are synced.

---

## What's Next: v5

We're starting to lay the foundation for v5, a major rewrite that
migrates most of the bash install logic into three compiled Rust
executables:

- **stibbons** — Host + container CLI/TUI. Replaces the git-submodule
  workflow with a locally installed binary (Homebrew, apt, cargo) that
  handles `init`, `update`, and worktree/agent management.
- **igor** — Container-only runtime manager. Takes over secret
  resolution, post-create/post-start hooks, Claude Code setup, and git
  identity configuration from the current bash entrypoint.
- **luggage** — Manifest-driven build engine. Replaces
  `lib/features/*.sh` with a compiled installer that's distro-aware,
  version-aware, audit-logged, and checksum-verified end-to-end.

Goals of the rewrite:

- Drop the git-submodule complexity in favor of a CLI you install once.
- Simplify the common path — `stibbons init` should cover 95% of
  projects without ceremony.
- Give the remaining 5% far more granular control via hierarchical
  configuration (global / team / project / individual) and per-distro
  version constraints.
- Improve robustness, security, and enterprise auditability by replacing
  bash with a compiled engine that logs every install step.

v5 work is in-progress in `crates/` (the `stibbons` crate is the first
piece landing). The v4 system documented above remains the supported,
stable target and will continue to ship updates until the cutover is
complete.

---

## License

Dual-licensed under either of:

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
  <https://www.apache.org/licenses/LICENSE-2.0>)
- MIT license ([LICENSE-MIT](LICENSE-MIT) or
  <https://opensource.org/licenses/MIT>)

at your option. This is the standard dual-license used across the Rust
ecosystem; it matches the license of [octarine](https://github.com/joshjhall/octarine),
the foundation crate v5 is built on.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
