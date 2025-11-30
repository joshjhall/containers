# Production Container Examples

This directory contains examples for building production-optimized containers
using the main Dockerfile with production-focused build arguments.

## Key Principle: One Universal Dockerfile

This project uses a **single universal Dockerfile** configured via build
arguments for all environments (development, staging, production, CI). You do
NOT need separate Dockerfiles for production - instead, you configure the main
Dockerfile with different build arguments.

## Production vs Development Configuration

The key differences between production and development builds:

| Aspect            | Development                   | Production                              |
| ----------------- | ----------------------------- | --------------------------------------- |
| Base Image        | `debian:trixie` (full)        | `debian:trixie-slim`                    |
| Passwordless Sudo | `true` (convenience)          | `false` (security)                      |
| Dev Tools         | Included (editors, debuggers) | Excluded                                |
| Language Runtimes | Often with `-dev` packages    | Runtime-only packages                   |
| Image Size        | Larger (~600-800MB+)          | Smaller (~200-500MB)                    |
| Attack Surface    | Larger (dev tools)            | Minimal (runtime only)                  |
| Security Options  | Relaxed                       | Hardened (read-only, no-new-privileges) |

## Build Argument Strategy

### Core Production Arguments

```dockerfile
# Use lightweight base
BASE_IMAGE: "debian:trixie-slim"

# Disable passwordless sudo for security
ENABLE_PASSWORDLESS_SUDO: "false"

# Disable dev tools
INCLUDE_DEV_TOOLS: "false"
```

### Language Runtime Arguments

For each language, there are two sets of build arguments:

1. **`INCLUDE_<LANG>`**: Installs the runtime
2. **`INCLUDE_<LANG>_DEV`**: Installs development tools

**Production pattern**: Set `INCLUDE_<LANG>=true` but `INCLUDE_<LANG>_DEV=false`

```dockerfile
# Python runtime: YES runtime, NO dev tools
INCLUDE_PYTHON: "true"
INCLUDE_PYTHON_DEV: "false"  # No pip-tools, ipython, black, mypy, pytest

# Node runtime: YES runtime, NO dev tools
INCLUDE_NODE: "true"
INCLUDE_NODE_DEV: "false"  # No typescript, eslint, prettier, nodemon

# Rust runtime: YES runtime, NO dev tools
INCLUDE_RUST: "true"
INCLUDE_RUST_DEV: "false"  # No clippy, rustfmt, cargo-watch
```

## Example Configurations

### 1. Minimal Production Base

The absolute minimum container with no language runtimes:

```yaml
# docker-compose.minimal.yml
services:
  minimal-prod:
    build:
      context: ../..
      dockerfile: Dockerfile
      args:
        BASE_IMAGE: 'debian:trixie-slim'
        ENABLE_PASSWORDLESS_SUDO: 'false'
        INCLUDE_PYTHON: 'false'
        INCLUDE_NODE: 'false'
        INCLUDE_DEV_TOOLS: 'false'
```

**Use case**: Base images, utility containers, sidecar containers

**Expected size**: ~200-300MB

### 2. Python Production Runtime

Python runtime without development tools:

```yaml
# docker-compose.python.yml
services:
  python-prod:
    build:
      context: ../..
      dockerfile: Dockerfile
      args:
        BASE_IMAGE: 'debian:trixie-slim'
        ENABLE_PASSWORDLESS_SUDO: 'false'
        INCLUDE_PYTHON: 'true'
        INCLUDE_PYTHON_DEV: 'false'
        PYTHON_VERSION: '3.12'
        INCLUDE_DEV_TOOLS: 'false'
```

**Includes**: python3, pip, essential libraries **Excludes**: pip-tools,
ipython, black, mypy, pytest

**Expected size**: ~400-500MB

### 3. Node.js Production Runtime

Node.js runtime without development tools:

```yaml
# docker-compose.node.yml
services:
  node-prod:
    build:
      context: ../..
      dockerfile: Dockerfile
      args:
        BASE_IMAGE: 'debian:trixie-slim'
        ENABLE_PASSWORDLESS_SUDO: 'false'
        INCLUDE_NODE: 'true'
        INCLUDE_NODE_DEV: 'false'
        NODE_VERSION: '20'
        INCLUDE_DEV_TOOLS: 'false'
```

**Includes**: node, npm, yarn **Excludes**: typescript, eslint, prettier,
nodemon, ts-node

**Expected size**: ~400-500MB

## Usage

### Using Docker Compose (Recommended)

From your project root (where containers is a submodule):

```bash
# Build and run minimal production base
docker compose -f containers/examples/production/docker-compose.minimal.yml up -d

# Build and run Python production runtime
docker compose -f containers/examples/production/docker-compose.python.yml up -d

# Build and run Node production runtime
docker compose -f containers/examples/production/docker-compose.node.yml up -d
```

From the containers directory (standalone):

```bash
# Build and run minimal production base
docker compose -f examples/production/docker-compose.minimal.yml up -d
```

### Using Docker CLI

From your project root:

```bash
# Build minimal production base
docker build \
  -f containers/Dockerfile \
  -t myproject:minimal-prod \
  --build-arg BASE_IMAGE="debian:trixie-slim" \
  --build-arg ENABLE_PASSWORDLESS_SUDO="false" \
  --build-arg INCLUDE_DEV_TOOLS="false" \
  --build-arg INCLUDE_PYTHON="false" \
  --build-arg INCLUDE_NODE="false" \
  .

# Build Python production runtime
docker build \
  -f containers/Dockerfile \
  -t myproject:python-prod \
  --build-arg BASE_IMAGE="debian:trixie-slim" \
  --build-arg ENABLE_PASSWORDLESS_SUDO="false" \
  --build-arg INCLUDE_PYTHON="true" \
  --build-arg INCLUDE_PYTHON_DEV="false" \
  --build-arg PYTHON_VERSION="3.12" \
  --build-arg INCLUDE_DEV_TOOLS="false" \
  .
```

## Production Security Hardening

The example docker-compose files include production security best practices:

```yaml
# Read-only root filesystem
read_only: true

# Drop all Linux capabilities
cap_drop:
  - ALL

# Prevent privilege escalation
security_opt:
  - no-new-privileges:true

# Mount application code as read-only
volumes:
  - ./:/workspace/myproject:ro
  - app-cache:/cache # Writable cache only

# Built-in healthcheck
healthcheck:
  test: ['/usr/local/bin/healthcheck', '--quick']
  interval: 30s
  timeout: 10s
  retries: 3

# Auto-restart on failure
restart: unless-stopped
```

## Multi-Runtime Production Containers

You can include multiple language runtimes in production if needed:

```yaml
services:
  fullstack-prod:
    build:
      context: ../..
      dockerfile: Dockerfile
      args:
        BASE_IMAGE: 'debian:trixie-slim'
        ENABLE_PASSWORDLESS_SUDO: 'false'

        # Multiple runtimes
        INCLUDE_PYTHON: 'true'
        INCLUDE_PYTHON_DEV: 'false'
        INCLUDE_NODE: 'true'
        INCLUDE_NODE_DEV: 'false'

        # Still no dev tools
        INCLUDE_DEV_TOOLS: 'false'
```

**Expected size**: ~600-800MB (vs 1GB+ with dev tools)

## Adding Cloud/Infrastructure Tools

For production deployments that need cloud CLI tools:

```yaml
args:
  # ... base configuration ...

  # Add cloud tools as needed
  INCLUDE_DOCKER: 'true' # For Docker-in-Docker or CI
  INCLUDE_KUBERNETES: 'true' # For kubectl access
  INCLUDE_TERRAFORM: 'false' # Usually not needed in runtime
```

Note: Only include tools that are actually needed at runtime. Build/deploy tools
should typically live in CI containers, not runtime containers.

## Best Practices

1. **Start Minimal**: Begin with the minimal base and add only what you need
2. **Separate Build/Runtime**: Consider multi-stage builds where build tools are
   in build stage only
3. **Pin Versions**: Use specific version build args for reproducibility
4. **Test Locally**: Build and test production images locally before deploying
5. **Scan Images**: Run security scanners (trivy, grype) on production images
6. **Monitor Size**: Keep track of image sizes and investigate unexpected growth
7. **Use Cache Mounts**: BuildKit cache mounts speed up rebuilds significantly
8. **Read-Only Filesystem**: Use `read_only: true` when possible for security
9. **Minimal Capabilities**: Drop all capabilities and add back only what's
   needed
10. **Health Checks**: Always define proper health checks for runtime containers

## Environment-Specific Configurations

### Development

- Full base image
- Dev tools included
- Passwordless sudo enabled
- Relaxed security
- Focus on convenience

### Staging

- Slim base image
- Runtime-only packages
- No dev tools
- Some security hardening
- Closer to production

### Production

- Slim base image
- Runtime-only packages
- No dev tools
- Full security hardening
- Minimal attack surface

## Troubleshooting

### Image Size Larger Than Expected

Check what's actually installed:

```bash
# Run container
docker run -it --rm myproject:prod /bin/bash

# Check installed packages
dpkg -l | wc -l

# Check large directories
du -sh /usr/* | sort -h | tail -20
```

### Missing Dependencies at Runtime

Your application might need runtime libraries that aren't included in the slim
base:

```yaml
args:
  # Add common runtime libraries if needed
  BASE_IMAGE: 'debian:trixie-slim'
  # Then manually install additional libs via DEBIAN_PACKAGES build arg
```

### Permission Issues

Make sure UID/GID match your deployment environment:

```yaml
args:
  USER_UID: 1000 # Match your deployment environment
  USER_GID: 1000
```

## Additional Resources

- Main Dockerfile: `../../Dockerfile`
- Development examples: `../dev/`
- CI examples: `../ci/`
- Environment templates: `../env/`
- Build argument reference: `../../CLAUDE.md`
