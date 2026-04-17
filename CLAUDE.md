# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Container Build System Overview

This is a modular container build system that creates purpose-specific
containers — from minimal agent images to full development environments —
across multiple Linux distributions. v5 is a major rewrite replacing the
git-submodule + bash-script approach with three compiled Rust executables
and manifest-driven installs.

## Architecture

v5 is built around three compiled Rust executables in a Cargo workspace:

### Three Executables

- **stibbons** (`crates/stibbons/`) — Host + container CLI/TUI for project
  setup, configuration, worktree/agent management. The primary user-facing
  tool. Installable via Homebrew, apt, cargo. Planned alias: `cbs`.
- **igor** (`crates/igor/` — planned) — Container-only runtime manager.
  Handles 1Password secret resolution, post-create/post-start hooks,
  Claude Code setup, git identity, and service health checks.
- **luggage** (`crates/luggage/` — planned) — Build engine. Manifest-driven
  feature installation across the matrix of distro x distro version x
  feature x feature version. Not user-facing.

### Shared Crate

- **containers-common** (`crates/containers-common/`) — Shared types:
  feature registry, dependency resolution, configuration schema, version
  types. Used by all three executables.

### Legacy Code (being ported)

- `lib/base/` — System setup, user creation, logging utilities
- `lib/features/` — Bash feature installation scripts (being replaced by
  luggage manifests)
- `lib/runtime/` — Container runtime initialization (being replaced by igor)

### Other Key Directories

- `bin/` — Version management scripts (check-versions.sh, release.sh)
- `tests/` — Test framework and test suites
- `examples/` — Docker Compose configurations and environment examples
- `docs/` — Documentation

## Common commands

All common tasks are wired into the `justfile`. Run `just` to list recipes.
Prefer these over direct cargo/shell invocations — they stay in sync with CI.

```bash
just               # list recipes
just test          # full pre-commit test suite (no Docker)
just test-all      # test + integration (requires Docker)
just lint          # run every lefthook pre-commit hook on all files
just fmt           # cargo fmt --all
just build         # cargo build --workspace
just check-versions
just install-hooks # lefthook install
```

The raw commands these wrap — useful when debugging or when `just` isn't available:
`cargo build --workspace`, `cargo test --workspace`,
`cargo clippy --workspace -- -D warnings`, `cargo fmt --all`.

### Adding a New Feature

1. Add Feature struct to `crates/containers-common/src/feature/registry.rs`
1. Set `requires` / `implied_by` if needed
1. Add template conditionals (when template system is ported)
1. Update golden files if applicable

## Common Commands

### Building Containers

```bash
# Build from project root (standard usage)
docker build -t projectname:python-dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=projectname \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  .

# Build with multiple features
docker build -t projectname:full-dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=projectname \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DOCKER=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  .

# Testing containers standalone (no parent project)
cd containers
docker build -t test:minimal \
  --build-arg PROJECT_PATH=. \
  --build-arg PROJECT_NAME=test \
  .
```

### Testing

```bash
just test-all                          # unit + integration
just test                              # unit only (no Docker)
just test-integration                  # integration only (requires Docker)
just test-integration-one python_dev   # single integration test
just test-feature golang               # quick single-feature test in isolation
just test-feature python-dev
just test-feature kubernetes
```

Underlying scripts (for reference): `./tests/run_all.sh`,
`./tests/run_unit_tests.sh`, `./tests/run_integration_tests.sh`,
`./tests/test_feature.sh`.

#### IMPORTANT: Testing Docker Builds Manually

When testing Docker builds manually, **DO NOT run `docker build` commands
directly** because Docker may be configured with buildx as the default builder,
which has different argument handling.

**ALWAYS use the integration test framework** which handles Docker configuration
correctly:

```bash
# Use the test framework - this is the CORRECT way
./tests/run_integration_tests.sh

# Create a new integration test if needed for your feature
# See tests/integration/builds/test_*.sh for examples
```

**Docker Build Command Syntax** (if you MUST run manually):

The build context (`.`) **MUST** come at the very end:

```bash
# ✓ CORRECT - context at the end
docker build -f Dockerfile --build-arg PROJECT_PATH=. --build-arg PROJECT_NAME=test -t test:image .

# ✗ WRONG - context before flags (buildx may misinterpret)
docker build . -f Dockerfile --build-arg PROJECT_PATH=. --build-arg PROJECT_NAME=test -t test:image

# ✗ WRONG - using buildx explicitly may fail
docker buildx build -t test:image -f Dockerfile --build-arg ARG=value .
```

**Why the test framework is preferred:**

- Handles Docker/buildx configuration automatically
- Provides proper assertions and error handling
- Cleans up test containers/images
- Works consistently across environments
- See `tests/framework/assertions/docker.sh` for implementation

### Running Containers

```bash
# Run built container interactively
docker run -it --rm \
  -v "$(pwd):/workspace/project" \
  -v "project-cache:/cache" \
  projectname:full-dev
```

### Debugging

```bash
# Inside container - check build logs
check-build-logs.sh python-dev
check-build-logs.sh

# Check installed versions
check-installed-versions.sh
```

## Feature Build Arguments

All features are controlled via `INCLUDE_<FEATURE>=true/false` build arguments.
See `docs/reference/features.md` for the full dependency graph and
`docs/reference/environment-variables.md` for all build args, version pins,
and cache paths.

## Project Integration

### v5 approach (CLI-based)

Projects use the `stibbons` CLI to generate and manage container configuration.
No git submodule required:

1. Install stibbons via Homebrew, apt, or cargo
1. Run `stibbons init` in the project root
1. Build with the generated docker-compose.yml
1. Update with `stibbons update` when features or versions change

### v4 approach (git submodule — still supported)

Projects can still add this repository as a submodule at `containers/`:

1. Build commands reference the Dockerfile: `-f containers/Dockerfile`
1. The build context is the project root
1. Different environments are created by varying the build arguments
1. For standalone testing, use `PROJECT_PATH=.` to indicate no parent project

## Claude Code Integrations

When `INCLUDE_DEV_TOOLS=true`, the container installs Claude Code CLI.

### LSP Servers (installed with `*_dev` features)

Each `INCLUDE_*_DEV` feature auto-installs its LSP server: Python→`python-lsp-server`+`pyright`,
Node→`typescript-language-server`, R→`languageserver`, Go→`gopls`, Ruby→`solargraph`,
Rust→`rust-analyzer`, Kotlin→`kotlin-language-server`+`jdtls`, Java/Android→`jdtls`.
`bash-language-server` is added when `DEV_TOOLS=true` and Node.js is available.

### Plugins & MCP Servers

11 core plugins and language-specific LSP plugins are auto-installed on first
startup. Override defaults via `CLAUDE_PLUGINS` (replaces core set) or add
extras via `CLAUDE_EXTRA_PLUGINS`. MCPs configurable via `CLAUDE_MCPS`
(replaces defaults) or `CLAUDE_EXTRA_MCPS`. See
`docs/claude-code/plugins-and-mcps.md` for the full plugin list, MCP server
registry (10 short names), entry formats, HTTP auth, release channel, and
model selection.

### Skills & Agents

39 skills (37 always + 2 conditional) and 17 agents. Key capabilities:
`/codebase-audit` (parallel scanners), `/next-issue` + `/next-issue-ship`
(issue-driven development with auto-labeling and state persistence). Override
defaults via `CLAUDE_SKILLS` and `CLAUDE_AGENTS` (replaces full set). Add
extras via `CLAUDE_EXTRA_SKILLS` and `CLAUDE_EXTRA_AGENTS`. See
`docs/claude-code/skills-and-agents.md` for full details.

### Memory System

Two-tier memory under `.claude/memory/`:

- Long-term (committed): `.claude/memory/*.md` — team knowledge, architecture decisions
- Short-term (gitignored): `.claude/memory/tmp/` — ephemeral session state

See `docs/claude-code/memory-system.md` for conventions.

### Secrets & Setup Commands

When `INCLUDE_OP=true`, `OP_<NAME>_REF` env vars are read from 1Password via
`op read` on every container create/start and exported as `<NAME>` (e.g.,
`OP_GITHUB_TOKEN_REF` → `GITHUB_TOKEN`). `OP_<NAME>_FILE_REF` writes content
to `/dev/shm/` (in-memory tmpfs) and exports the file path. Secrets never
touch disk and are re-fetched from the vault each startup. Three setup
commands: `setup-git`, `setup-gh`, `setup-glab`. See
`docs/claude-code/secrets-and-setup.md` for the full convention, variable
tables, caching, docker-compose examples, and git identity fallback.

### Authentication & Environment

Auth via **Interactive OAuth** or **Token-based** (`ANTHROPIC_AUTH_TOKEN`).
`claude-auth-watcher` auto-configures plugins; manual fallback: `claude-setup`.
`ENABLE_LSP_TOOL=1` is set in the shell. Feature flags persist to
`/etc/container/config/enabled-features.conf`.

## Cache Management

All caches live under `/cache` (`pip`, `npm`, `cargo`, `go`, `bundle`, etc.).
Mount as a Docker volume for persistence. The entrypoint auto-fixes `/cache`
permissions on startup. See `docs/architecture/caching.md` for details and
`docs/reference/environment-variables.md` for per-tool cache paths.

## Security Considerations

Non-root user by default (`USERNAME` build arg), validated feature installs,
proper file permissions. See `docs/security-hardening.md` for full details.

## Init System (Zombie Process Reaping)

The container uses **tini** as PID 1 to properly reap zombie processes and
forward signals. This is critical for long-running development containers where
child processes (pre-commit hooks, git operations, test runners) may become
orphaned.

- **Dockerfile**: Uses `ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]`
- **Docker Compose**: All examples include `init: true` as belt-and-suspenders

When writing docker-compose files, always include `init: true`:

```yaml
services:
  myservice:
    init: true  # Ensures proper zombie reaping
    command: ["sleep", "infinity"]
```

## Cross-Platform Development

Auto-detects case-insensitive mounts (suppress with `SKIP_CASE_CHECK=true`).
Bindfs auto-applies FUSE permission overlay on macOS/VirtioFS — requires
`--cap-add SYS_ADMIN --device /dev/fuse`. Add `.fuse_hidden*` to `.gitignore`.
See `docs/troubleshooting/case-sensitive-filesystems.md` and
`docs/troubleshooting/docker-mac-case-sensitivity.md`.

## Multi-Distro Support

v5 targets multiple distributions: Debian (11/12/13), Alpine, RHEL/UBI, and
Ubuntu, with more planned. The `luggage` build engine adapts package names,
install commands, and version constraints per distro automatically.

### Debian Version Compatibility (current)

Supports Debian 11 (Bullseye), 12 (Bookworm), and 13 (Trixie) with automatic
detection. See `docs/troubleshooting/debian-compatibility.md` for version
detection APIs (`apt_install`, `apt_install_conditional`, `is_debian_version`),
key differences by version, and testing guidance.

## Shell Command Safety: Always Use Full Paths

**NEVER use bare commands** like `ls`, `cat`, `grep`, `sed`, `awk`, `head`,
`tail`, `find`, `sort`, `wc`, `tr`, `cut`, `tee`, or `echo` in scripts and
tests. Aliases can change output format or break parsing.

**Always use full paths** (`/usr/bin/grep`) or the `command` builtin
(`command grep`):

```bash
/usr/bin/grep -q "pattern" file   # CORRECT - full path
command grep -q "pattern" file     # CORRECT - command builtin
grep -q "pattern" file             # WRONG - may be aliased
```

Critical for runtime scripts (`lib/runtime/`); important for all scripts and
tests as a general defensive practice.

## Automated Version Updates

Weekly auto-patch runs Sundays at 2am UTC (`auto-patch/YYYYMMDD-HHMMSS`
branches). Don't manually edit `auto-patch/*` branches. Manual check:
`just check-versions` (underlying script: `./bin/check-versions.sh`; add
`--json` for automation). See `docs/operations/automated-releases.md`.

## Release Process

**ALWAYS use the release script** — never manually edit the VERSION file.

```bash
just release-patch   # bug fix (4.3.2 -> 4.3.3)
just release-minor   # new feature (4.3.2 -> 4.4.0)
just release-major   # breaking change (4.3.2 -> 5.0.0)
```

The script updates VERSION, Dockerfile, test framework version, and generates
CHANGELOG.md. Then commit, tag (`vX.Y.Z`), and push — the tag triggers CI to
build, test, and publish. See `docs/development/releasing.md` for full details.

## Documentation Resources

Detailed docs in `docs/`: `claude-code/` (plugins, MCPs, skills, agents,
secrets), `architecture/caching.md`, `security-hardening.md`,
`troubleshooting.md`, `development/` (releasing, testing), `reference/`
(versions, environment variables), `operations/automated-releases.md`.
Examples in `examples/env/*.env` and `examples/contexts/`.
