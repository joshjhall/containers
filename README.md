# Universal Container Build System

A modular, extensible container build system designed to be shared across projects as a git submodule. Build everything from minimal agent containers to full-featured development environments using a single, configurable Dockerfile.

## Features

- 🔧 **Modular Architecture**: Enable only the tools you need via build arguments
- 🚀 **Efficient Caching**: BuildKit cache mounts for faster rebuilds
- 🔒 **Security First**: Non-root users, proper permissions, validated installations
- 🌍 **Multi-Purpose**: Development, CI/CD, production, and agent containers
- 📦 **20+ Languages & Tools**: Python, Node.js, Rust, Go, Ruby, Java, R, and more
- ☁️ **Cloud Ready**: AWS, GCP, Kubernetes, Terraform integrations

## Quick Start

### For New Projects

1. Add as a git submodule:
```bash
git submodule add https://github.com/yourusername/containers.git containers
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

### For Existing Projects

1. Add the submodule:
```bash
git submodule add https://github.com/yourusername/containers.git containers
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

## VS Code Dev Container Integration

### Basic Setup

1. Create `.devcontainer/devcontainer.json`:
```json
{
  "name": "My Project Development",
  "dockerComposeFile": "docker-compose.yml",
  "service": "devcontainer",
  "workspaceFolder": "/workspace/${localWorkspaceFolderBasename}",
  
  "customizations": {
    "vscode": {
      "extensions": [
        "ms-python.python",
        "ms-python.vscode-pylance",
        "rust-lang.rust-analyzer",
        "golang.go"
      ],
      "settings": {
        "python.defaultInterpreterPath": "/usr/local/bin/python",
        "python.linting.enabled": true,
        "python.formatting.provider": "black",
        "editor.formatOnSave": true
      }
    }
  },
  
  "remoteUser": "vscode"
}
```

2. Create `.devcontainer/docker-compose.yml`:
```yaml
services:
  devcontainer:
    build:
      context: ..  # Project root
      dockerfile: containers/Dockerfile  # Use the shared Dockerfile
      args:
        BASE_IMAGE: mcr.microsoft.com/devcontainers/base:bookworm
        PROJECT_NAME: myproject
        USERNAME: vscode
        WORKING_DIR: /workspace/myproject
        INCLUDE_PYTHON_DEV: "true"
        INCLUDE_NODE_DEV: "true"
        INCLUDE_DEV_TOOLS: "true"
        INCLUDE_DOCKER: "true"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ..:/workspace/myproject
    command: sleep infinity
```

### Advanced Configuration

For more complex setups with databases and services, see `examples/devcontainer/` for complete examples including:
- PostgreSQL and Redis integration
- Environment variable management
- 1Password integration
- Post-create and post-start scripts

## Available Features

### Programming Languages
- **Python**: 3.11+ with pyenv support (`INCLUDE_PYTHON=true`)
- **Node.js**: 22 LTS with npm, yarn, pnpm (`INCLUDE_NODE=true`)
- **Rust**: Latest stable with cargo (`INCLUDE_RUST=true`)
- **Go**: Latest version with module support (`INCLUDE_GOLANG=true`)
- **Ruby**: 3.3+ with bundler (`INCLUDE_RUBY=true`)
- **Java**: OpenJDK 21 with Maven/Gradle (`INCLUDE_JAVA=true`)
- **R**: Statistical computing environment (`INCLUDE_R=true`)

### Development Tools
Add `_DEV` to any language to include development tools:
- `INCLUDE_PYTHON_DEV`: black, ruff, mypy, pytest, poetry, jupyter
- `INCLUDE_NODE_DEV`: TypeScript, ESLint, Jest, Vite, webpack
- `INCLUDE_RUST_DEV`: clippy, rustfmt, cargo-watch, bacon
- And more...

### Infrastructure Tools
- `INCLUDE_DOCKER`: Docker CLI, compose, lazydocker
- `INCLUDE_KUBERNETES`: kubectl, helm, k9s
- `INCLUDE_TERRAFORM`: terraform, terragrunt, tf-docs
- `INCLUDE_AWS`: AWS CLI v2
- `INCLUDE_GCLOUD`: Google Cloud SDK

### Other Tools
- `INCLUDE_DEV_TOOLS`: git, gh CLI, fzf, ripgrep, bat, delta
- `INCLUDE_OP`: 1Password CLI
- `INCLUDE_OLLAMA`: Local LLM support

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

## Updating the Submodule

To update to the latest version:
```bash
cd containers
git pull origin main
cd ..
git add containers
git commit -m "Update container build system"
```

## Version Management

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

Configure GitLab CI to automatically check for updates weekly with Pushover notifications:
1. Add `PUSHOVER_USER_KEY` and `PUSHOVER_APP_TOKEN` to CI/CD variables
2. Create a pipeline schedule for weekly runs
3. Receive notifications when updates are available

See [docs/scheduled-version-checks.md](docs/scheduled-version-checks.md) for detailed setup instructions.

### Updating Versions
When updates are available, edit the appropriate files:
- Language versions: Update `ARG *_VERSION` in `Dockerfile`
- Tool versions: Update version variables in `lib/features/*.sh`

## Testing

### Unit Tests

The project includes a comprehensive unit test framework that tests bash scripts directly without requiring Docker builds:

```bash
# Run all unit tests
./tests/run_unit_tests.sh

# Run specific test suite
./tests/unit/version_checker.sh
./tests/unit/base/logging.sh
./tests/unit/features/python.sh
```

**Test Coverage:**
- ✅ Version checking and management (10 tests)
- ✅ Release scripts (12 tests)
- ✅ Logging framework (11 tests)
- ✅ User management (13 tests)
- ✅ Python features (15 tests)
- ✅ Base system setup (15 tests)

**Current Status:** 76 tests passing, 1 skipped on macOS

### Quick Test
To quickly verify your container builds:
```bash
# From your project root (where containers/ is a subdirectory)
./containers/bin/test-all-features.sh

# Show all tools (including not installed)
./containers/bin/test-all-features.sh --all
```

### Comprehensive Testing
For full test suite including build tests:
```bash
# From within containers directory
cd containers
./tests/run_all.sh

# Run specific test
./tests/run_test.sh integration/builds/test_minimal.sh
```

## Best Practices

1. **Choose the right base image**:
   - `debian:bookworm-slim`: Minimal size, good compatibility
   - `ubuntu:24.04`: More packages available, larger size
   - `mcr.microsoft.com/devcontainers/base:bookworm`: VS Code optimized

2. **Optimize build times**:
   - Only include features you actually need
   - Use BuildKit cache mounts (already configured)
   - Layer expensive operations early in the Dockerfile

3. **Security considerations**:
   - Always use non-root users in production
   - Mount secrets at runtime, don't bake them in
   - Regularly update the submodule for security patches

4. **Version pinning**:
   - Pin the submodule to specific commits for stability
   - Use version build arguments for reproducible builds
   - Document version requirements in your project

5. **Build context**:
   - The build context should be your project root (where you run `docker build .`)
   - The Dockerfile path is `-f containers/Dockerfile`
   - Your project files are available for COPY commands during build

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