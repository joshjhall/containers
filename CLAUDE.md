# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Container Build System Overview

This is a modular container build system designed to be used as a git submodule across multiple projects. It provides a universal Dockerfile that creates purpose-specific containers through build arguments, from minimal environments to full development containers.

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
- `bin/`: User-facing scripts (test runners, etc.)
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
# Test all installed features
./bin/test-all-features.sh

# Test with verbose output
./bin/test-all-features.sh --all
```

### Running Containers

```bash
# Run interactively
./bin/run-all-features.sh

# Or manually
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
**Dev Tools**: `PYTHON_DEV`, `NODE_DEV`, `RUST_DEV`, `RUBY_DEV`, `R_DEV`, `GOLANG_DEV`, `JAVA_DEV`, `MOJO_DEV`
**Tools**: `DEV_TOOLS`, `DOCKER`, `OP` (1Password CLI)
**Cloud**: `KUBERNETES`, `TERRAFORM`, `AWS`, `GCLOUD`, `CLOUDFLARE`
**Database**: `POSTGRES_CLIENT`, `REDIS_CLIENT`, `SQLITE_CLIENT`
**AI/ML**: `OLLAMA` (Local LLM support)

Version control via build arguments:

- `PYTHON_VERSION`, `NODE_VERSION`, `RUST_VERSION`, `GO_VERSION`, `RUBY_VERSION`, `JAVA_VERSION`, `R_VERSION`

## Integration as Git Submodule

This container system is designed to be used as a git submodule:

1. Projects add this repository as a submodule (typically at `containers/`)
2. Build commands reference the Dockerfile from the submodule: `-f containers/Dockerfile`
3. The build context is the project root (where you run `docker build .`)
4. The Dockerfile assumes it's in `containers/` and project files are in the parent directory
5. Different environments are created by varying the build arguments
6. For standalone testing, use `PROJECT_PATH=.` to indicate no parent project

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
