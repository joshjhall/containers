# Development vs Production Configuration Comparison

This document provides detailed comparison tables showing the differences
between development and production container configurations.

## Build Arguments Comparison

### Core Configuration

| Build Argument             | Development              | Production             | Impact                                  |
| -------------------------- | ------------------------ | ---------------------- | --------------------------------------- |
| `BASE_IMAGE`               | `debian:bookworm` (full) | `debian:bookworm-slim` | ~100MB size reduction                   |
| `ENABLE_PASSWORDLESS_SUDO` | `true`                   | `false`                | Security: prevents privilege escalation |
| `INCLUDE_DEV_TOOLS`        | `true`                   | `false`                | ~50-100MB size reduction                |

### Python Configuration

| Build Argument       | Development | Production | What's Different           |
| -------------------- | ----------- | ---------- | -------------------------- |
| `INCLUDE_PYTHON`     | `true`      | `true`     | Same: runtime needed       |
| `INCLUDE_PYTHON_DEV` | `true`      | `false`    | Dev tools excluded         |
| `PYTHON_VERSION`     | `3.12`      | `3.12`     | Same: use specific version |

**What `INCLUDE_PYTHON_DEV=true` includes (excluded in production):**

- pip-tools (pip-compile, pip-sync)
- ipython (enhanced REPL)
- black (code formatter)
- mypy (type checker)
- pytest (testing framework)
- build tools (gcc, python3-dev)

**Size impact**: ~200-300MB reduction

### Node.js Configuration

| Build Argument     | Development | Production | What's Different      |
| ------------------ | ----------- | ---------- | --------------------- |
| `INCLUDE_NODE`     | `true`      | `true`     | Same: runtime needed  |
| `INCLUDE_NODE_DEV` | `true`      | `false`    | Dev tools excluded    |
| `NODE_VERSION`     | `20`        | `20`       | Same: use LTS version |

**What `INCLUDE_NODE_DEV=true` includes (excluded in production):**

- typescript (TypeScript compiler)
- eslint (linter)
- prettier (code formatter)
- nodemon (auto-reloader)
- ts-node (TypeScript execution)
- Build tools

**Size impact**: ~200-300MB reduction

### Other Languages

Similar patterns apply for other languages:

| Language | Runtime Arg      | Dev Tools Arg        | Dev Tools Included                 |
| -------- | ---------------- | -------------------- | ---------------------------------- |
| Rust     | `INCLUDE_RUST`   | `INCLUDE_RUST_DEV`   | clippy, rustfmt, cargo-watch       |
| Go       | `INCLUDE_GOLANG` | `INCLUDE_GOLANG_DEV` | gopls, delve, golangci-lint        |
| Ruby     | `INCLUDE_RUBY`   | `INCLUDE_RUBY_DEV`   | bundler-audit, rubocop, solargraph |
| Java     | `INCLUDE_JAVA`   | `INCLUDE_JAVA_DEV`   | maven, gradle, jdtls               |
| R        | `INCLUDE_R`      | `INCLUDE_R_DEV`      | devtools, testthat, lintr          |

## Docker Compose Security Options

### Development Configuration

```yaml
services:
  app-dev:
    build:
      args:
        BASE_IMAGE: 'debian:bookworm'
        ENABLE_PASSWORDLESS_SUDO: 'true'
        INCLUDE_DEV_TOOLS: 'true'

    # Relaxed security for convenience
    volumes:
      - ./:/workspace/project:rw # Read-write
      - dev-cache:/cache

    # No security restrictions
    privileged: false # Usually not needed even in dev
    # No cap_drop (all capabilities available)
    # No security_opt restrictions
```

### Production Configuration

```yaml
services:
  app-prod:
    build:
      args:
        BASE_IMAGE: 'debian:bookworm-slim'
        ENABLE_PASSWORDLESS_SUDO: 'false'
        INCLUDE_DEV_TOOLS: 'false'

    # Hardened security
    read_only: true # Read-only root filesystem
    volumes:
      - ./:/workspace/project:ro # Read-only code
      - prod-cache:/cache # Writable cache only

    security_opt:
      - no-new-privileges:true # Prevent privilege escalation
    cap_drop:
      - ALL # Drop all Linux capabilities

    # Health monitoring
    healthcheck:
      test: ['/usr/local/bin/healthcheck', '--quick']
      interval: 30s
      timeout: 10s
      retries: 3

    # Auto-restart
    restart: unless-stopped
```

## Image Size Comparison

Expected image sizes for different configurations:

| Configuration                     | Development Size | Production Size | Savings         |
| --------------------------------- | ---------------- | --------------- | --------------- |
| Minimal Base                      | ~300-400MB       | ~200-300MB      | ~100MB (25-30%) |
| Python Runtime                    | ~600-700MB       | ~400-500MB      | ~200MB (30-35%) |
| Node Runtime                      | ~600-700MB       | ~400-500MB      | ~200MB (30-35%) |
| Python + Node                     | ~900MB-1.1GB     | ~600-800MB      | ~300MB (30-35%) |
| Full Stack (Python + Node + Rust) | ~1.5-1.8GB       | ~1.0-1.2GB      | ~500MB (30-35%) |

**Note**: Actual sizes vary based on specific versions and dependencies.

## Runtime Environment Variables

### Development Environment

```yaml
environment:
  # Development mode
  - NODE_ENV=development
  - FLASK_ENV=development
  - DJANGO_DEBUG=true

  # Verbose logging
  - PYTHONUNBUFFERED=1
  - DEBUG=*

  # Development tools
  - PYTHONDONTWRITEBYTECODE=0 # Allow .pyc files
```

### Production Environment

```yaml
environment:
  # Production mode
  - NODE_ENV=production
  - FLASK_ENV=production
  - DJANGO_DEBUG=false

  # Optimized logging
  - PYTHONUNBUFFERED=1
  - PYTHONDONTWRITEBYTECODE=1 # No .pyc files

  # Security
  - PIP_NO_CACHE_DIR=1
  - NPM_CONFIG_LOGLEVEL=warn
```

## Development Tools Included

### When `INCLUDE_DEV_TOOLS=true` (Development Only)

The following tools are installed:

**Editors & IDEs:**

- vim, neovim
- emacs
- nano

**Version Control:**

- git (with enhanced configuration)
- git-lfs (Large File Storage)
- gh (GitHub CLI)

**Shell & Terminal:**

- tmux (terminal multiplexer)
- zsh (with oh-my-zsh)
- fish (friendly shell)
- starship (shell prompt)

**Utilities:**

- curl, wget
- jq (JSON processor)
- ripgrep (fast search)
- fd (fast find)
- bat (cat with syntax highlighting)
- fzf (fuzzy finder)
- htop (process viewer)

**Build Tools:**

- make
- cmake
- build-essential (gcc, g++, make)

**Size impact**: ~50-100MB

## Cloud/Infrastructure Tools

These are typically excluded in production runtime containers but may be
included in CI/deployment containers:

| Tool       | Build Arg            | When to Include           | Size Impact |
| ---------- | -------------------- | ------------------------- | ----------- |
| Docker     | `INCLUDE_DOCKER`     | CI, orchestration         | ~50-100MB   |
| Kubernetes | `INCLUDE_KUBERNETES` | Cluster management        | ~50-100MB   |
| Terraform  | `INCLUDE_TERRAFORM`  | Infrastructure deployment | ~50-100MB   |
| AWS CLI    | `INCLUDE_AWS`        | AWS deployments           | ~100-150MB  |
| gcloud CLI | `INCLUDE_GCLOUD`     | GCP deployments           | ~100-200MB  |

**Production guidance**: Only include these if the application needs to manage
infrastructure at runtime (e.g., operator patterns, auto-scaling logic).

## Resource Requirements

### Development

```yaml
# Generous resources for development
deploy:
  resources:
    limits:
      cpus: '4'
      memory: 8G
    reservations:
      cpus: '2'
      memory: 4G
```

### Production

```yaml
# Right-sized for application needs
deploy:
  resources:
    limits:
      cpus: '2'
      memory: 2G
    reservations:
      cpus: '1'
      memory: 1G
```

## Best Practices Summary

### Development Priorities

1. **Developer Experience**: Tools and utilities for productivity
2. **Debugging**: Enhanced error messages and stack traces
3. **Fast Iteration**: Hot reload, auto-restart tools
4. **Flexibility**: Passwordless sudo, relaxed security
5. **Completeness**: Include everything that might be useful

### Production Priorities

1. **Security**: Minimal attack surface, hardened configuration
2. **Size**: Smaller images = faster deployments
3. **Performance**: Runtime-only packages, optimized settings
4. **Reliability**: Health checks, auto-restart policies
5. **Immutability**: Read-only filesystems, declarative configuration

## Migration Checklist

When moving from development to production configuration:

- [ ] Change base image to `debian:bookworm-slim`
- [ ] Set `ENABLE_PASSWORDLESS_SUDO=false`
- [ ] Set `INCLUDE_DEV_TOOLS=false`
- [ ] For each language: Set `INCLUDE_<LANG>_DEV=false`
- [ ] Add `read_only: true` to compose file
- [ ] Add `security_opt: [no-new-privileges:true]`
- [ ] Add `cap_drop: [ALL]`
- [ ] Change volume mounts to read-only (`:ro`)
- [ ] Add health check configuration
- [ ] Set production environment variables
- [ ] Add resource limits
- [ ] Configure restart policy
- [ ] Test with `./compare-sizes.sh` to verify size reduction
- [ ] Run security scan (trivy, grype, docker scan)
- [ ] Test application functionality in production-like container

## Testing Your Configuration

Use the provided helper scripts to validate your production configuration:

```bash
# Build production image
./build-prod.sh python myapp

# Compare dev vs prod sizes
./compare-sizes.sh python

# Expected output:
# Dev:  ~650MB
# Prod: ~450MB
# Savings: ~200MB (30%)
```

## Additional Resources

- Production examples: `docker-compose.*.yml` files in this directory
- Build helper: `build-prod.sh`
- Size comparison: `compare-sizes.sh`
- Main documentation: `README.md`
- Main Dockerfile: `../../Dockerfile`
