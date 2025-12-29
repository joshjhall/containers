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

**Languages**: `PYTHON`, `NODE`, `RUST`, `RUBY`, `R`, `GOLANG`, `JAVA`, `MOJO`
**Dev Tools**: `PYTHON_DEV`, `NODE_DEV`, `RUST_DEV`, `RUBY_DEV`, `R_DEV`,
`GOLANG_DEV`, `JAVA_DEV`, `MOJO_DEV`
**Tools**: `DEV_TOOLS`, `DOCKER`, `OP` (1Password CLI)
**Claude Code**: `CLAUDE_INTEGRATIONS` (LSP servers), `MCP_SERVERS` (MCP servers)
**Cloud**: `KUBERNETES`, `TERRAFORM`, `AWS`, `GCLOUD`, `CLOUDFLARE`
**Database**: `POSTGRES_CLIENT`, `REDIS_CLIENT`, `SQLITE_CLIENT`
**AI/ML**: `OLLAMA` (Local LLM support)

Note: `MCP_SERVERS` auto-triggers Node.js installation since MCP servers require it.

Version control via build arguments:

- `PYTHON_VERSION`, `NODE_VERSION`, `RUST_VERSION`, `GO_VERSION`,
  `RUBY_VERSION`, `JAVA_VERSION`, `R_VERSION`

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

When `INCLUDE_DEV_TOOLS=true`, the container installs Claude Code CLI. Additional
integrations can enhance Claude Code's capabilities:

### LSP Servers (`INCLUDE_CLAUDE_INTEGRATIONS=true`, default: true)

Installs language server protocol servers based on detected languages:

- **Python**: `python-lsp-server` with black and ruff plugins
- **Node/TypeScript**: `typescript-language-server`
- **R**: `languageserver`

Note: Go (gopls), Ruby (solargraph), and Rust (rust-analyzer) are already
installed by their respective `*-dev` scripts.

### MCP Servers (`INCLUDE_MCP_SERVERS=false`, default: false)

Installs Model Context Protocol servers for enhanced Claude Code capabilities:

- **Filesystem**: `@modelcontextprotocol/server-filesystem` - Enhanced file ops
- **GitHub**: `@modelcontextprotocol/server-github` - GitHub API integration
- **GitLab**: `@modelcontextprotocol/server-gitlab` - GitLab API integration

MCP configuration is created on first container startup via
`/etc/container/first-startup/30-claude-mcp-setup.sh`, which ensures it works
correctly with mounted home directories.

Set these environment variables at runtime for GitHub/GitLab integration:

- `GITHUB_TOKEN`: GitHub personal access token
- `GITLAB_TOKEN`: GitLab personal access token
- `GITLAB_API_URL`: GitLab API URL (defaults to `https://gitlab.com/api/v4`)

## Cache Management

The system uses `/cache` directory with subdirectories for each tool:

- `/cache/pip`, `/cache/npm`, `/cache/cargo`, `/cache/go`, `/cache/bundle`
- Mount as Docker volume for persistence across builds
- Scripts automatically configure tools to use these cache directories

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
