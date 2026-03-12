# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## Container Build System Overview

This is a modular container build system designed to be used as a git submodule
across multiple projects. It provides a universal Dockerfile that creates
purpose-specific containers through build arguments, from minimal environments
to full development containers.

## Architecture

The system follows a modular architecture:

- **Base setup**: Core system configuration and user management
- **Feature scripts**: Individual installations for languages and tools
- **Runtime scripts**: Container initialization and environment setup
- **Caching strategy**: BuildKit cache mounts for efficient rebuilds

Key directories:

- `lib/base/`: System setup, user creation, logging utilities
- `lib/features/`: Optional feature installations (languages, tools)
- `lib/runtime/`: Container runtime initialization
- `bin/`: Version management scripts (check-versions.sh, update-versions.sh,
  release.sh)
- `tests/`: Test framework and test suites
- `examples/`: Docker Compose configurations and environment examples

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
# Run all tests (unit + integration)
./tests/run_all.sh

# Run unit tests only (no Docker required)
./tests/run_unit_tests.sh

# Run integration tests (requires Docker)
./tests/run_integration_tests.sh

# Run specific integration test
./tests/run_integration_tests.sh python_dev

# Quick feature test (for development - tests one feature in isolation)
./tests/test_feature.sh golang
./tests/test_feature.sh python-dev
./tests/test_feature.sh kubernetes
```

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

All features are controlled via `INCLUDE_<FEATURE>=true/false` build arguments:

**Languages**: `PYTHON`, `NODE`, `RUST`, `RUBY`, `R`, `GOLANG`, `JAVA`, `MOJO`,
`KOTLIN`
**Dev Tools**: `PYTHON_DEV`, `NODE_DEV`, `RUST_DEV`, `RUBY_DEV`, `R_DEV`,
`GOLANG_DEV`, `JAVA_DEV`, `MOJO_DEV`, `KOTLIN_DEV`
**Android**: `ANDROID`, `ANDROID_DEV`
**Tools**: `DEV_TOOLS`, `DOCKER`, `OP` (1Password CLI), `CRON`, `BINDFS`
**Cloud**: `KUBERNETES`, `TERRAFORM`, `AWS`, `GCLOUD`, `CLOUDFLARE`
**Database**: `POSTGRES_CLIENT`, `REDIS_CLIENT`, `SQLITE_CLIENT`
**AI/ML**: `OLLAMA` (Local LLM support)

Note: `CRON` auto-triggers when `INCLUDE_RUST_DEV=true`, `INCLUDE_DEV_TOOLS=true`, or `INCLUDE_BINDFS=true`.
Note: `BINDFS` auto-triggers when `INCLUDE_DEV_TOOLS=true`. Auto-triggers `CRON` for periodic `.fuse_hidden*` cleanup. Requires `--cap-add SYS_ADMIN --device /dev/fuse` at runtime.
Note: `KOTLIN` and `ANDROID` features auto-trigger Java installation.

**Security**: `REQUIRE_VERIFIED_DOWNLOADS` — when `true`, blocks Tier 4 TOFU
(Trust On First Use) checksum fallback, enforcing at least Tier 2 pinned
checksums for all downloads. Defaults to the value of `PRODUCTION_MODE`
(which defaults to `false`). Recommended for production builds.

Version control via build arguments:

- `PYTHON_VERSION`, `NODE_VERSION`, `RUST_VERSION`, `GO_VERSION`,
  `RUBY_VERSION`, `JAVA_VERSION`, `R_VERSION`, `KOTLIN_VERSION`
- `ANDROID_CMDLINE_TOOLS_VERSION`, `ANDROID_API_LEVELS`, `ANDROID_NDK_VERSION`

**Flexible version formats** (auto-resolved to latest patch):

| Language | Accepted Formats        | Example                    |
| -------- | ----------------------- | -------------------------- |
| Python   | X, X.Y, X.Y.Z           | `3`, `3.12`, `3.12.7`      |
| Rust     | X.Y, X.Y.Z, stable/beta | `1.84`, `1.82.0`, `stable` |
| Ruby     | X.Y, X.Y.Z              | `3.4`, `3.3.6`             |
| Node.js  | X, X.Y, X.Y.Z           | `22`, `20.18`, `20.18.1`   |
| Go       | X.Y, X.Y.Z              | `1.23`, `1.23.5`           |

Partial versions are resolved to the latest patch with pinned checksums.

## Integration as Git Submodule

This container system is designed to be used as a git submodule:

1. Projects add this repository as a submodule (typically at `containers/`)
1. Build commands reference the Dockerfile from the submodule:
   `-f containers/Dockerfile`
1. The build context is the project root (where you run `docker build .`)
1. The Dockerfile assumes it's in `containers/` and project files are in the
   parent directory
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

15 skills (13 always + 2 conditional) and 11 agents. Key capabilities:
`/codebase-audit` (parallel scanners), `/next-issue` + `/next-issue-ship`
(issue-driven development with auto-labeling and state persistence). Override
defaults via `CLAUDE_SKILLS` and `CLAUDE_AGENTS` (replaces full set). Add
extras via `CLAUDE_EXTRA_SKILLS` and `CLAUDE_EXTRA_AGENTS`. See
`docs/claude-code/skills-and-agents.md` for full details.

### Secrets & Setup Commands

When `INCLUDE_OP=true`, `OP_<NAME>_REF` env vars auto-resolve from 1Password.
`OP_<NAME>_FILE_REF` writes content to `/dev/shm/` and exports the file path.
Three setup commands: `setup-git`, `setup-gh`, `setup-glab`. See
`docs/claude-code/secrets-and-setup.md` for variable tables, docker-compose
examples, and git identity fallback.

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

## Debian Version Compatibility

The build system supports Debian 11 (Bullseye), 12 (Bookworm), and 13 (Trixie)
with automatic version detection and conditional package installation.

### When Writing Feature Scripts

Always use the Debian version detection system from `lib/base/apt-utils.sh`:

```bash
# Source apt utilities in your feature script
source /tmp/build-scripts/base/apt-utils.sh

# Install packages that work on all versions
apt_install common-package-1 common-package-2

# Install packages only on specific Debian versions
# Syntax: apt_install_conditional <min_version> <max_version> <packages...>
apt_install_conditional 11 12 old-package-name

# Check version for conditional logic
if is_debian_version 13; then
    # Trixie-specific code
fi

# Or check command availability (preferred for apt-key, etc.)
if command -v apt-key >/dev/null 2>&1; then
    # Old method (Debian 11/12)
else
    # New method (Debian 13+)
fi
```

### Shell Command Safety: Always Use Full Paths

**NEVER use bare commands** like `ls`, `cat`, `grep`, `sed`, `awk`, `head`,
`tail`, `find`, `sort`, `wc`, `tr`, `cut`, `tee`, or `echo` in scripts and
tests. These commands are often aliased (e.g., `ls` to `ls --color=auto`,
`grep` to `grep --color=auto`) and aliases can change output format, add
unexpected flags, or break parsing.

**Always use the full path** from `command -v` or a known system path:

```bash
# CORRECT - full paths, immune to aliases
/usr/bin/ls /some/dir
/usr/bin/grep -q "pattern" file
/usr/bin/cat /etc/os-release
/usr/bin/find /path -name "*.sh"
/usr/bin/wc -l < file
/usr/bin/sort < file

# ALSO CORRECT - command builtin bypasses aliases
command ls /some/dir
command grep -q "pattern" file

# WRONG - bare commands may be aliased
ls /some/dir
grep -q "pattern" file
cat /etc/os-release
```

**Priority**: This is critical for runtime scripts (`lib/runtime/`) that run
in interactive shells where aliases are loaded. It is also important for build
scripts (`lib/base/`, `lib/features/`) and test scripts (`tests/`) as a
general defensive practice.

### Key Differences by Version

- **Debian 11/12**: Uses legacy `apt-key` for repository GPG keys
- **Debian 13+**: Requires `signed-by` method with keyrings in
  `/usr/share/keyrings/`
- **Package migrations**: Some packages removed/renamed in Trixie (e.g.,
  `lzma-dev` merged into `liblzma-dev`)

### Debian Version Testing

CI automatically tests builds on all three Debian versions. When modifying
feature scripts:

1. Test locally with different base images using `BASE_IMAGE` build arg
1. Check the `debian-version-test` job in GitHub Actions
1. See `docs/troubleshooting.md` for detailed examples and patterns

## Automated Version Updates

Weekly auto-patch runs Sundays at 2am UTC (`auto-patch/YYYYMMDD-HHMMSS`
branches). Don't manually edit `auto-patch/*` branches. Manual check:
`./bin/check-versions.sh` (add `--json` for automation). See
`docs/operations/automated-releases.md`.

## Release Process

**ALWAYS use the release script** — never manually edit the VERSION file.

```bash
./bin/release.sh --non-interactive patch   # bug fix (4.3.2 -> 4.3.3)
./bin/release.sh --non-interactive minor   # new feature (4.3.2 -> 4.4.0)
./bin/release.sh --non-interactive major   # breaking change (4.3.2 -> 5.0.0)
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
