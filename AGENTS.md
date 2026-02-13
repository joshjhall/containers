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
  --build-arg INCLUDE_PYTHON_DEV=true \
  .

# Build with multiple features
docker build -t projectname:full-dev \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=projectname \
  --build-arg INCLUDE_PYTHON_DEV=true \
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

# ✗ WRONG - arguments after the context
docker build -t test:image -f Dockerfile --build-arg PROJECT_PATH=. --build-arg PROJECT_NAME=test .

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
check-build-logs.sh master-summary

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
**Tools**: `DEV_TOOLS`, `DOCKER`, `OP` (1Password CLI), `CRON`
**Claude Code**: `MCP_SERVERS` (deprecated, kept for backward compatibility)
**Cloud**: `KUBERNETES`, `TERRAFORM`, `AWS`, `GCLOUD`, `CLOUDFLARE`
**Database**: `POSTGRES_CLIENT`, `REDIS_CLIENT`, `SQLITE_CLIENT`
**AI/ML**: `OLLAMA` (Local LLM support)

Note: `MCP_SERVERS` auto-triggers Node.js installation since MCP servers require it.
Note: `CRON` auto-triggers when `INCLUDE_RUST_DEV=true` or `INCLUDE_DEV_TOOLS=true`.
Note: `KOTLIN` and `ANDROID` features auto-trigger Java installation (similar to `MCP_SERVERS` auto-triggering Node.js).

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

Language server protocol servers are installed automatically with their
respective language development features. This enables IDE features like
code completion, go-to-definition, and diagnostics for any IDE (VSCode,
Cursor, Neovim, etc.):

| Feature               | LSP Server                                      |
| --------------------- | ----------------------------------------------- |
| `INCLUDE_PYTHON_DEV`  | `python-lsp-server` with black and ruff plugins |
| `INCLUDE_NODE_DEV`    | `typescript-language-server`                    |
| `INCLUDE_R_DEV`       | `languageserver`                                |
| `INCLUDE_GOLANG_DEV`  | `gopls`                                         |
| `INCLUDE_RUBY_DEV`    | `solargraph`                                    |
| `INCLUDE_RUST_DEV`    | `rust-analyzer`                                 |
| `INCLUDE_KOTLIN_DEV`  | `kotlin-language-server`, `jdtls`               |
| `INCLUDE_JAVA_DEV`    | `jdtls` (Eclipse JDT Language Server)           |
| `INCLUDE_ANDROID_DEV` | `jdtls` (Eclipse JDT Language Server)           |
| `INCLUDE_DEV_TOOLS`\* | `bash-language-server` (requires Node.js)       |

\*`bash-language-server` is installed when both `INCLUDE_DEV_TOOLS=true` and Node.js
is available (`INCLUDE_NODE=true` or `INCLUDE_NODE_DEV=true`).

### Claude Code Plugins and LSP Integration

When `INCLUDE_DEV_TOOLS=true`, Claude Code plugins and LSP support are
automatically configured on first container startup via
`/etc/container/first-startup/30-claude-code-setup.sh`.

**Core plugins** (always installed):

- `commit-commands` - Git commit helpers
- `frontend-design` - Interface design assistance
- `code-simplifier` - Code simplification
- `context7` - Documentation lookup
- `security-guidance` - Security best practices
- `claude-md-management` - CLAUDE.md file management
- `pr-review-toolkit` - Comprehensive PR review tools
- `code-review` - Code review assistance
- `hookify` - Hook creation helpers
- `claude-code-setup` - Project setup assistance
- `feature-dev` - Feature development workflow

**Language-specific LSP plugins** (based on build flags):

| Build Flag           | Claude Code Plugin                          |
| -------------------- | ------------------------------------------- |
| `INCLUDE_RUST_DEV`   | `rust-analyzer-lsp@claude-plugins-official` |
| `INCLUDE_PYTHON_DEV` | `pyright-lsp@claude-plugins-official`       |
| `INCLUDE_NODE_DEV`   | `typescript-lsp@claude-plugins-official`    |
| `INCLUDE_KOTLIN_DEV` | `kotlin-lsp@claude-plugins-official`        |

**Extra plugins**: Use `CLAUDE_EXTRA_PLUGINS` to install additional plugins:

```bash
# At build time
docker build --build-arg CLAUDE_EXTRA_PLUGINS="stripe,posthog,vercel" ...

# At runtime (overrides build-time value)
docker run -e CLAUDE_EXTRA_PLUGINS="stripe,posthog" ...
```

**Extra MCP servers**: Use `CLAUDE_EXTRA_MCPS` to install additional MCP servers:

```bash
# At build time
docker build --build-arg CLAUDE_EXTRA_MCPS="brave-search,memory,fetch" ...

# At runtime (overrides build-time value)
docker run -e CLAUDE_EXTRA_MCPS="brave-search,sentry" -e BRAVE_API_KEY=xxx ...
```

Available MCP servers:

| Short Name            | NPM Package                                        | Required Env Vars             |
| --------------------- | -------------------------------------------------- | ----------------------------- |
| `brave-search`        | `@modelcontextprotocol/server-brave-search`        | `BRAVE_API_KEY`               |
| `fetch`               | `@modelcontextprotocol/server-fetch`               | (none)                        |
| `memory`              | `@modelcontextprotocol/server-memory`              | `MEMORY_FILE_PATH` (optional) |
| `sequential-thinking` | `@modelcontextprotocol/server-sequential-thinking` | (none)                        |
| `git`                 | `@modelcontextprotocol/server-git`                 | (none)                        |
| `sentry`              | `@sentry/mcp-server`                               | `SENTRY_ACCESS_TOKEN`         |
| `perplexity`          | `@perplexity-ai/mcp-server`                        | `PERPLEXITY_API_KEY`          |

**Release channel**: Use `CLAUDE_CHANNEL` to select the Claude Code release channel:

```bash
# Use stable channel (default, recommended)
docker build --build-arg CLAUDE_CHANNEL=stable ...

# Use latest channel (bleeding edge)
docker build --build-arg CLAUDE_CHANNEL=latest ...
```

**Environment variable**: `ENABLE_LSP_TOOL=1` is set in the shell environment.

**Build-time configuration**: Feature flags are persisted to
`/etc/container/config/enabled-features.conf` for use by startup scripts.

**Note**: The startup script is idempotent and will skip plugins that are
already installed. To verify installed plugins, run: `claude plugin list`

### Pre-installed Skills & Agents

When `INCLUDE_DEV_TOOLS=true`, Claude Code skills and agents are automatically
installed to `~/.claude/skills/` and `~/.claude/agents/` on first container
startup via `claude-setup`. Project-level `.claude/` configs merge with these
(union semantics, project wins on name conflicts).

**Skills** (always installed):

| Skill                   | Purpose                                                              |
| ----------------------- | -------------------------------------------------------------------- |
| `container-environment` | Dynamic - describes installed tools, cache paths, container patterns |
| `git-workflow`          | Git commit conventions, branch naming, PR workflow                   |
| `testing-patterns`      | Test-first development, test framework patterns                      |
| `code-quality`          | Linting, formatting, code review checklist                           |

**Conditional skills**:

| Skill                  | Condition                                                                                                         |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `docker-development`   | `INCLUDE_DOCKER=true`                                                                                             |
| `cloud-infrastructure` | Any cloud flag (`INCLUDE_KUBERNETES`, `INCLUDE_TERRAFORM`, `INCLUDE_AWS`, `INCLUDE_GCLOUD`, `INCLUDE_CLOUDFLARE`) |

**Agents** (always installed):

| Agent           | Purpose                                              |
| --------------- | ---------------------------------------------------- |
| `code-reviewer` | Reviews code for bugs, security, performance, style  |
| `test-writer`   | Generates tests for existing code, detects framework |
| `refactorer`    | Refactors code while preserving behavior             |

Templates are staged at build time to `/etc/container/config/claude-templates/`
and installed at runtime by `claude-setup`. All installations are idempotent.

To verify: `ls ~/.claude/skills/` and `ls ~/.claude/agents/`

### MCP Servers (installed by claude-code-setup.sh when Node.js available)

MCP servers are automatically installed by `claude-code-setup.sh` when Node.js
is available (`INCLUDE_NODE=true` or `INCLUDE_NODE_DEV=true`):

- **Filesystem**: `@modelcontextprotocol/server-filesystem` - Enhanced file ops
- **GitHub**: `@modelcontextprotocol/server-github` - GitHub API integration
- **GitLab**: `@modelcontextprotocol/server-gitlab` - GitLab API integration
- **Bash LSP**: `bash-language-server` - Shell script language server

> **Note**: `INCLUDE_MCP_SERVERS` is **deprecated**. It is kept for backward
> compatibility (triggers Node.js installation) but MCP servers are now
> installed automatically with `INCLUDE_DEV_TOOLS=true` when Node.js is present.

MCP configuration is created on first container startup via
`/etc/container/first-startup/30-claude-code-setup.sh`:

- **Always** configures filesystem MCP server for `/workspace`
- **Always** configures Figma desktop MCP (`http://host.docker.internal:3845/mcp`)
- **Detects** GitHub vs GitLab from git remote origin URL
- **Fallback**: Defaults to GitHub MCP only when remote is ambiguous (most common case)
- **Is idempotent** - checks existing config before adding

**Platform selection** (environment variable):

| Value    | Behavior                                     |
| -------- | -------------------------------------------- |
| `github` | Configure GitHub MCP only                    |
| `gitlab` | Configure GitLab MCP only                    |
| `both`   | Configure both GitHub and GitLab MCPs        |
| (unset)  | Auto-detect from git remote, default: GitHub |

```bash
# Override platform detection
docker run -e GIT_PLATFORM=gitlab ...
```

Set the appropriate token at runtime:

- `GITHUB_TOKEN`: GitHub personal access token (when using GitHub)
- `GITLAB_TOKEN`: GitLab personal access token (when using GitLab)

#### Automatic Token Loading from 1Password

When `INCLUDE_OP=true`, you can automatically load `GITHUB_TOKEN` and `GITLAB_TOKEN`
from 1Password using a service account:

| Variable                   | Purpose                         | Example                       |
| -------------------------- | ------------------------------- | ----------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password service account token | `ops_xxx...`                  |
| `OP_GITHUB_TOKEN_REF`      | 1Password ref for GitHub token  | `op://Vault/GitHub-PAT/token` |
| `OP_GITLAB_TOKEN_REF`      | 1Password ref for GitLab token  | `op://Vault/GitLab-PAT/token` |

Example docker-compose.yml:

```yaml
services:
  dev:
    environment:
      - OP_SERVICE_ACCOUNT_TOKEN=${OP_SERVICE_ACCOUNT_TOKEN}
      - OP_GITHUB_TOKEN_REF=op://Development/GitHub-PAT/token
```

Tokens are loaded automatically on shell initialization and container startup.
Existing tokens are preserved (won't overwrite if already set).

### Claude Code Authentication

Plugin installation requires interactive authentication.

**Automatic setup (recommended)**: After running `claude` and authenticating, plugins
and MCP servers are configured automatically within 30-60 seconds by the background
`claude-auth-watcher` process. A marker file (`~/.claude/.container-setup-complete`)
prevents repeated setup runs.

**Manual workflow** (if auto-setup doesn't run):

```bash
# 1. Inside container, run Claude and authenticate when prompted
claude

# 2. Close the Claude client (Ctrl+C or exit)

# 3. Run setup to install plugins
claude-setup

# 4. Restart Claude if needed
```

**Auto-setup configuration**:

| Variable                       | Purpose                     | Default |
| ------------------------------ | --------------------------- | ------- |
| `CLAUDE_AUTH_WATCHER_TIMEOUT`  | Watcher timeout in seconds  | 14400   |
| `CLAUDE_AUTH_WATCHER_INTERVAL` | Polling interval in seconds | 30      |

The watcher uses `inotifywait` for efficient event-driven detection when available,
falling back to polling otherwise.

**Note**: Environment variables (including `ANTHROPIC_API_KEY`) do NOT work with the
Claude Code CLI. You must run `claude` to authenticate interactively.

Verify configuration with:

- `claude plugin list` - See installed plugins
- `claude mcp list` - See configured MCP servers
- `pgrep -f claude-auth-watcher` - Check if watcher is running

## Cache Management

The system uses `/cache` directory with subdirectories for each tool:

- `/cache/pip`, `/cache/npm`, `/cache/cargo`, `/cache/go`, `/cache/bundle`
- Mount as Docker volume for persistence across builds
- Scripts automatically configure tools to use these cache directories

### Cache Permission Handling

Some cache files may be created as root during Docker builds (e.g., npm global
installs). The entrypoint automatically fixes `/cache` permissions on startup:

- **Running as root**: Directly fixes ownership to the container user
- **Running with sudo**: Uses `sudo chown` to fix permissions
- **No sudo available**: Warns user; some package manager operations may fail

To enable automatic permission fixes in sudo-less containers, set
`ENABLE_PASSWORDLESS_SUDO=true` during build.

## Security Considerations

- Non-root user by default (configurable via `USERNAME` build arg)
- Each feature script validates its installation
- Proper file permissions maintained throughout
- SSH/GPG utilities included for secure operations

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

### Case-Sensitive Filesystem Considerations

**Important**: Linux containers expect case-sensitive filesystems, but macOS and
Windows use case-insensitive filesystems by default. This mismatch can cause
issues when mounting host directories.

**Common Issues**:

- Git tracks case changes (`README.md` → `readme.md`) but filesystem doesn't
  reflect them
- Case-sensitive imports fail (Python: `from MyModule` vs `from mymodule`)
- Build tools expecting exact case matches may fail

**Detection**: The container automatically detects case-insensitive mounts at
startup and displays a warning with recommendations.

**Solutions**:

1. **macOS**: Use case-sensitive APFS volume for development
1. **Windows**: Use WSL2 filesystem (not Windows paths)
1. **All platforms**: Use Docker volumes instead of bind mounts
1. **Workaround**: Follow strict naming conventions (always lowercase or always
   PascalCase)

**Disable check**: Set `SKIP_CASE_CHECK=true` to suppress the warning

**Detailed guide**: See `docs/troubleshooting/case-sensitive-filesystems.md`

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

This repository has an automated patch release system that runs weekly:

- **Auto-patch workflow** runs Sundays at 2am UTC
- Creates branches like `auto-patch/YYYYMMDD-HHMMSS`
- Automatically checks for tool version updates
- Runs full CI pipeline and auto-merges on success

**What this means for you:**

- Expect automated commits from the `auto-patch` system
- Don't manually edit `auto-patch/*` branches
- The system uses `check-versions.sh` → `update-versions.sh` → `release.sh`

**Manual version checking:**

```bash
# Check for outdated tool versions
./bin/check-versions.sh

# Output as JSON for automation
./bin/check-versions.sh --json

# Update versions from JSON file
./bin/update-versions.sh versions.json
```

## Release Process

When you're ready to release a new version, **ALWAYS use the release script** -
never manually edit the VERSION file.

### Creating a Release

```bash
# For bug fixes (4.3.2 -> 4.3.3)
echo 'y' | ./bin/release.sh patch

# For new features (4.3.2 -> 4.4.0)
echo 'y' | ./bin/release.sh minor

# For breaking changes (4.3.2 -> 5.0.0)
echo 'y' | ./bin/release.sh major

# For specific version
echo 'y' | ./bin/release.sh 4.5.0
```

The release script automatically:

- Updates VERSION file
- Updates Dockerfile version comment
- Updates test framework version
- Generates CHANGELOG.md using git-cliff

### After Running Release Script

Complete the release by committing and pushing:

```bash
git add -A
git commit -m "chore(release): Release version X.Y.Z"
git tag -a vX.Y.Z -m "Release version X.Y.Z"
git push origin main
git push origin vX.Y.Z
```

The tag push triggers GitHub Actions to:

- Build all container variants on multiple Debian versions
- Run full test suite
- Push images to ghcr.io/joshjhall/containers
- Create GitHub release with automated release notes

## Documentation Resources

Detailed documentation is available in the `docs/` directory:

- `docs/troubleshooting.md` - Common issues and solutions
- `docs/operations/automated-releases.md` - How the auto-patch system works
- `docs/reference/versions.md` - Which tools are pinned vs. latest
- `docs/development/testing.md` - Test framework details

Reference examples are in the `examples/` directory:

- `examples/env/*.env` - Environment variable examples for each feature
- `examples/contexts/` - Docker Compose patterns
