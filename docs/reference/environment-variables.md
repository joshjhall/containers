# Environment Variables Reference

This document lists all environment variables used in the container build
system, organized by category.

## Table of Contents

- [Build Arguments](#build-arguments)
- [User Configuration](#user-configuration)
- [Language Versions](#language-versions)
- [Cache Directories](#cache-directories)
- [Feature-Specific Variables](#feature-specific-variables)
- [Runtime Configuration](#runtime-configuration)

______________________________________________________________________

## Build Arguments

Build arguments are passed during `docker build` and control what gets
installed. They are converted to environment variables during the build process.

### Base Configuration

| Variable       | Default                      | Description                                           |
| -------------- | ---------------------------- | ----------------------------------------------------- |
| `BASE_IMAGE`   | `debian:trixie-slim`         | Base Docker image to use                              |
| `PROJECT_PATH` | `..`                         | Path to project root relative to containers directory |
| `PROJECT_NAME` | `project`                    | Name of the project (used in paths)                   |
| `WORKING_DIR`  | `/workspace/${PROJECT_NAME}` | Working directory inside container                    |

### User Configuration

| Variable                   | Default     | Description                                    |
| -------------------------- | ----------- | ---------------------------------------------- |
| `USERNAME`                 | `developer` | Non-root username to create                    |
| `USER_UID`                 | `1000`      | User ID for the non-root user                  |
| `USER_GID`                 | `1000`      | Group ID for the non-root user                 |
| `ENABLE_PASSWORDLESS_SUDO` | `true`      | Allow passwordless sudo (for dev environments) |

### Build Output Configuration

| Variable    | Default | Description                                    |
| ----------- | ------- | ---------------------------------------------- |
| `LOG_LEVEL` | `INFO`  | Build log verbosity (ERROR, WARN, INFO, DEBUG) |

**Log Levels:**

- `ERROR` (0): Only errors - minimal output for CI/CD
- `WARN` (1): Errors and warnings
- `INFO` (2): Normal verbosity (default)
- `DEBUG` (3): Full verbosity for troubleshooting

**Example - Quiet build for CI:**

```bash
docker build --build-arg LOG_LEVEL=ERROR -t myimage .
```

**Example - Verbose build for debugging:**

```bash
docker build --build-arg LOG_LEVEL=DEBUG -t myimage .
```

### Feature Flags

All features are disabled by default. Set to `true` to enable:

**Languages:** | Variable | Description | |----------|-------------| |
`INCLUDE_PYTHON` | Install Python runtime | | `INCLUDE_NODE` | Install Node.js
runtime | | `INCLUDE_RUST` | Install Rust runtime | | `INCLUDE_RUBY` | Install
Ruby runtime | | `INCLUDE_R` | Install R statistical environment | |
`INCLUDE_GOLANG` | Install Go runtime | | `INCLUDE_JAVA` | Install Java JDK | |
`INCLUDE_MOJO` | Install Mojo language |

**Development Tools:** | Variable | Description | |----------|-------------| |
`INCLUDE_PYTHON_DEV` | Install Python dev tools (pytest, black, mypy, etc.) | |
`INCLUDE_NODE_DEV` | Install Node.js dev tools (TypeScript, Jest, etc.) | |
`INCLUDE_RUST_DEV` | Install Rust dev tools (rust-analyzer, clippy, etc.) | |
`INCLUDE_RUBY_DEV` | Install Ruby dev tools (rubocop, pry, etc.) | |
`INCLUDE_R_DEV` | Install R dev tools (devtools, tidyverse, etc.) | |
`INCLUDE_GOLANG_DEV` | Install Go dev tools (gopls, delve, etc.) | |
`INCLUDE_JAVA_DEV` | Install Java dev tools (Spring, JBang, etc.) | |
`INCLUDE_MOJO_DEV` | Install Mojo dev tools | | `INCLUDE_DEV_TOOLS` | Install
general dev tools (gh, lazygit, fzf, etc.) |

**Cloud & Infrastructure:** | Variable | Description |
|----------|-------------| | `INCLUDE_AWS` | Install AWS CLI and tools | |
`INCLUDE_GCLOUD` | Install Google Cloud SDK | | `INCLUDE_CLOUDFLARE` | Install
Cloudflare tools (wrangler) | | `INCLUDE_KUBERNETES` | Install kubectl, k9s,
helm | | `INCLUDE_TERRAFORM` | Install Terraform and related tools |

**Database Clients:** | Variable | Description | |----------|-------------| |
`INCLUDE_POSTGRES_CLIENT` | Install PostgreSQL client (psql) | |
`INCLUDE_REDIS_CLIENT` | Install Redis client (redis-cli) | |
`INCLUDE_SQLITE_CLIENT` | Install SQLite client (sqlite3) |

**Other Tools:** | Variable | Description | |----------|-------------| |
`INCLUDE_DOCKER` | Install Docker CLI tools | | `INCLUDE_OP_CLI` | Install
1Password CLI | | `INCLUDE_OLLAMA` | Install Ollama for local LLMs | |
`INCLUDE_BINDFS` | Install bindfs FUSE overlay for VirtioFS permission fixes |

______________________________________________________________________

## Language Versions

Control which version of each language to install:

| Variable         | Default  | Description                             |
| ---------------- | -------- | --------------------------------------- |
| `PYTHON_VERSION` | `3.14.0` | Python version to install from source   |
| `NODE_VERSION`   | `22`     | Node.js major version (from NodeSource) |
| `RUST_VERSION`   | `1.91.0` | Rust toolchain version                  |
| `RUBY_VERSION`   | `3.3.6`  | Ruby version to install from source     |
| `R_VERSION`      | `4.4`    | R version from CRAN repositories        |
| `GOLANG_VERSION` | `1.24.0` | Go version to install                   |
| `JAVA_VERSION`   | `21`     | Java JDK version (Temurin)              |
| `MOJO_VERSION`   | `24.6.0` | Mojo version via pixi                   |

______________________________________________________________________

## Cache Directories

All cache directories are located under `/cache` for persistence across builds:

### Python

| Variable             | Default              | Description                     |
| -------------------- | -------------------- | ------------------------------- |
| `PIP_CACHE_DIR`      | `/cache/pip`         | pip package cache               |
| `POETRY_CACHE_DIR`   | `/cache/poetry`      | Poetry package cache            |
| `PIPX_HOME`          | `/opt/pipx`          | pipx installation directory     |
| `PIPX_BIN_DIR`       | `/opt/pipx/bin`      | pipx binary directory           |
| `IPYTHONDIR`         | `$HOME/.ipython`     | IPython configuration directory |
| `JUPYTER_CONFIG_DIR` | `$HOME/.jupyter`     | Jupyter configuration directory |
| `BLACK_CACHE_DIR`    | `$HOME/.cache/black` | Black formatter cache           |

### Node.js

| Variable         | Default             | Description         |
| ---------------- | ------------------- | ------------------- |
| `NPM_CACHE_DIR`  | `/cache/npm`        | npm package cache   |
| `YARN_CACHE_DIR` | `/cache/yarn`       | Yarn package cache  |
| `PNPM_STORE_DIR` | `/cache/pnpm`       | pnpm package store  |
| `NPM_GLOBAL_DIR` | `/cache/npm-global` | Global npm packages |

### Rust

| Variable      | Default        | Description                 |
| ------------- | -------------- | --------------------------- |
| `CARGO_HOME`  | `/cache/cargo` | Cargo packages and registry |
| `RUSTUP_HOME` | `/opt/rustup`  | Rustup installation         |

### Go

| Variable     | Default           | Description               |
| ------------ | ----------------- | ------------------------- |
| `GOPATH`     | `/cache/go`       | Go workspace              |
| `GOMODCACHE` | `/cache/go-mod`   | Go module cache           |
| `GOCACHE`    | `/cache/go-build` | Go build cache            |
| `GOROOT`     | `/usr/local/go`   | Go installation directory |

### Ruby

| Variable      | Default              | Description               |
| ------------- | -------------------- | ------------------------- |
| `GEM_HOME`    | `/cache/ruby/gems`   | Ruby gems installation    |
| `GEM_PATH`    | `/cache/ruby/gems`   | Ruby gems search path     |
| `BUNDLE_PATH` | `/cache/ruby/bundle` | Bundler installation path |

### Java

| Variable           | Default                           | Description               |
| ------------------ | --------------------------------- | ------------------------- |
| `JAVA_HOME`        | `/usr/lib/jvm/default-java`       | Java JDK installation     |
| `GRADLE_USER_HOME` | `/cache/gradle`                   | Gradle cache and config   |
| `MAVEN_OPTS`       | `-Dmaven.repo.local=/cache/maven` | Maven repository location |

### R

| Variable      | Default            | Description       |
| ------------- | ------------------ | ----------------- |
| `R_LIBS_USER` | `/cache/R/library` | R package library |

### Docker

| Variable                  | Default                     | Description              |
| ------------------------- | --------------------------- | ------------------------ |
| `DOCKER_CONFIG`           | `/cache/docker`             | Docker CLI configuration |
| `DOCKER_CLI_PLUGINS_PATH` | `/cache/docker/cli-plugins` | Docker CLI plugins       |

### Development Tools

| Variable           | Default                         | Description                |
| ------------------ | ------------------------------- | -------------------------- |
| `DEV_TOOLS_CACHE`  | `/cache/dev-tools`              | General dev tools cache    |
| `CAROOT`           | `/cache/dev-tools/mkcert-ca`    | mkcert CA certificates     |
| `DIRENV_ALLOW_DIR` | `/cache/dev-tools/direnv-allow` | direnv allowed directories |

______________________________________________________________________

## Feature-Specific Variables

### Go Configuration

| Variable      | Default                           | Description          |
| ------------- | --------------------------------- | -------------------- |
| `GO111MODULE` | `on`                              | Enable Go modules    |
| `GOPROXY`     | `https://proxy.golang.org,direct` | Go module proxy      |
| `GOSUMDB`     | `sum.golang.org`                  | Go checksum database |

### Java Configuration

| Variable      | Default                               | Description                   |
| ------------- | ------------------------------------- | ----------------------------- |
| `GRADLE_HOME` | `/usr/share/gradle`                   | Gradle installation directory |
| `GRADLE_OPTS` | `-Xmx1024m -XX:MaxMetaspaceSize=512m` | Gradle JVM options            |

### Python Configuration

| Variable                | Default | Description                                   |
| ----------------------- | ------- | --------------------------------------------- |
| `JUPYTER_PLATFORM_DIRS` | `1`     | Use platform-specific directories for Jupyter |

### Ruby Configuration

| Variable                         | Default | Description                        |
| -------------------------------- | ------- | ---------------------------------- |
| `BUNDLE_AUDIT_UPDATE_ON_INSTALL` | `true`  | Update vulnerability DB on install |

### Bindfs Configuration

| Variable            | Default | Description                                                         |
| ------------------- | ------- | ------------------------------------------------------------------- |
| `BINDFS_ENABLED`    | `auto`  | `auto`: probe + apply if broken; `true`: always apply; `false`: off |
| `BINDFS_SKIP_PATHS` | (empty) | Comma-separated paths to exclude (e.g., `/workspace/.git`)          |

Bindfs requires `--cap-add SYS_ADMIN` and `--device /dev/fuse` at runtime.
In `auto` mode (default), the entrypoint probes permissions on bind mounts
under `/workspace` and only applies overlays when permissions are broken
(common on macOS VirtioFS). On Linux hosts, this is a safe no-op.

______________________________________________________________________

## Runtime Configuration

These variables can be set when running containers (via `docker run -e`):

### GitHub Integration

| Variable       | Description                                              |
| -------------- | -------------------------------------------------------- |
| `GITHUB_TOKEN` | GitHub personal access token for API rate limit increase |

### 1Password Integration

| Variable                   | Description                                          |
| -------------------------- | ---------------------------------------------------- |
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password service account token for automated access |

### Retry Configuration

| Variable              | Default | Description                                   |
| --------------------- | ------- | --------------------------------------------- |
| `RETRY_MAX_ATTEMPTS`  | `3`     | Maximum retry attempts for network operations |
| `RETRY_INITIAL_DELAY` | `2`     | Initial delay between retries (seconds)       |
| `RETRY_MAX_DELAY`     | `30`    | Maximum delay between retries (seconds)       |

### Logging

| Variable           | Default                                                                | Description                                 |
| ------------------ | ---------------------------------------------------------------------- | ------------------------------------------- |
| `BUILD_LOG_DIR`    | `/var/log/container-build` (root) or `/tmp/container-build` (non-root) | Build log directory with automatic fallback |
| `CURRENT_FEATURE`  | -                                                                      | Name of currently installing feature        |
| `CURRENT_LOG_FILE` | -                                                                      | Path to current feature's log file          |

**Note on BUILD_LOG_DIR:** The logging system automatically handles permission
issues:

- If explicitly set, that directory is used
- If running as root or with proper permissions, uses `/var/log/container-build`
- If permissions are restricted (e.g., rootless containers, CI), falls back to
  `/tmp/container-build`
- Fails with clear error message if neither location is writable

### Configuration Validation

| Variable                 | Default | Description                                                 |
| ------------------------ | ------- | ----------------------------------------------------------- |
| `VALIDATE_CONFIG`        | `false` | Enable runtime configuration validation (opt-in)            |
| `VALIDATE_CONFIG_STRICT` | `false` | Treat warnings as errors (fails on warnings)                |
| `VALIDATE_CONFIG_RULES`  | -       | Path to custom validation rules file                        |
| `VALIDATE_CONFIG_QUIET`  | `false` | Suppress informational messages (show only errors/warnings) |

**Example Usage**:

```bash
# Enable validation with default rules
docker run -e VALIDATE_CONFIG=true myapp:prod

# Enable strict mode (warnings become errors)
docker run \
  -e VALIDATE_CONFIG=true \
  -e VALIDATE_CONFIG_STRICT=true \
  myapp:prod

# Use custom validation rules
docker run \
  -e VALIDATE_CONFIG=true \
  -e VALIDATE_CONFIG_RULES=/app/config/validation-rules.sh \
  -v ./my-validation.sh:/app/config/validation-rules.sh:ro \
  myapp:prod
```

See [examples/validation/](../examples/validation/) for complete examples
including web apps, API services, and background workers.

______________________________________________________________________

## Usage Examples

### Build Time

```bash
# Build with specific Python version
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg PYTHON_VERSION=3.12.0 \
  -t myproject:python312 .

# Build with multiple features
docker build \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DOCKER=true \
  -t myproject:full-dev .

# Build without passwordless sudo (production)
docker build \
  --build-arg ENABLE_PASSWORDLESS_SUDO=false \
  -t myproject:prod .
```

### Runtime

```bash
# Run with GitHub token for higher API limits
docker run -e GITHUB_TOKEN="your_token_here" myproject:dev

# Run with 1Password service account
docker run -e OP_SERVICE_ACCOUNT_TOKEN="your_token_here" myproject:dev

# Run with custom retry configuration
docker run \
  -e RETRY_MAX_ATTEMPTS=5 \
  -e RETRY_INITIAL_DELAY=1 \
  myproject:dev
```

### Persistent Cache Volumes

```bash
# Create named volumes for caches
docker volume create project-pip-cache
docker volume create project-npm-cache
docker volume create project-cargo-cache

# Mount caches
docker run \
  -v project-pip-cache:/cache/pip \
  -v project-npm-cache:/cache/npm \
  -v project-cargo-cache:/cache/cargo \
  myproject:dev
```

______________________________________________________________________

## Finding Variables in Your Container

### Check What's Set

```bash
# List all exported environment variables
env | grep -E "(CACHE|HOME|PATH)" | sort

# Check specific feature variables
env | grep -i python
env | grep -i node
env | grep -i rust
```

### View Build Configuration

```bash
# Check which features are installed
check-installed-versions.sh

# View build logs for a feature
check-build-logs.sh python
check-build-logs.sh node-dev
```

### Use list-features Script

```bash
# List all available features
list-features.sh

# Get JSON output with build args
list-features.sh --json

# Filter by category
list-features.sh --filter language
list-features.sh --filter dev-tools
```

______________________________________________________________________

## Related Documentation

- [CLAUDE.md](../CLAUDE.md) - Build arguments and common commands
- [Dockerfile](../Dockerfile) - Complete list of build arguments with defaults
- [Troubleshooting](troubleshooting.md) - Common issues with environment
  variables
- [Testing Framework](../development/testing.md) - Test environment
  configuration

______________________________________________________________________

## Contributing

When adding new features or environment variables:

1. Update this documentation
1. Add to the feature's `log_feature_summary` call
1. Include in the feature's test verification script
1. Document in the feature script's header comments
