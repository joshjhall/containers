# Container Environment Variables Reference

This directory contains example environment variable files for each feature available in the container system. These files serve as documentation and templates for configuring your containers.

## Important Notes

### Path Variables
Many examples show paths like `$HOME/.config/...`. These are DEFAULT values that work with any username. In practice:
- Most tools automatically use `$HOME` at runtime
- You typically don't need to set these unless overriding defaults
- If you do set them, use `$HOME` instead of hardcoded paths

### Cache Mount Limitation
If your base image already uses UID 1000, the build system will automatically assign a different UID (e.g., 1001) to avoid conflicts. However, Docker cache mounts still use the original UID from build arguments, which may cause permission issues. See the Dockerfile comments for workarounds.

### Build vs Runtime Variables
- **Build Arguments**: Control which features are installed (`INCLUDE_*` variables)
- **Runtime Variables**: Configure the behavior of installed tools
- Build arguments cannot be changed after the image is built

## Structure

Each `.env` file corresponds to a feature that can be enabled during container build:

- `base.env` - Core container configuration (always applied)
- `python.env` - Python and Poetry configuration
- `python-dev.env` - Python development tools (linters, formatters, Sphinx, etc.)
- `node.env` - Node.js, npm, yarn, pnpm configuration
- `rust.env` - Rust and Cargo configuration
- `go.env` - Go language configuration
- `java.env` - Java, Maven, and Gradle configuration
- `ruby.env` - Ruby and rbenv configuration
- `r.env` - R language and package configuration
- `docker.env` - Docker CLI and compose configuration
- `dev-tools.env` - Development tools (fzf, direnv, lazygit, etc.)
- `aws.env` - AWS CLI configuration
- `gcloud.env` - Google Cloud SDK configuration
- `kubernetes.env` - Kubernetes tools (kubectl, k9s) configuration
- `terraform.env` - Terraform and Terragrunt configuration
- `cloudflare.env` - Cloudflare tools (wrangler, cloudflared) configuration
- `database-clients.env` - PostgreSQL, Redis, SQLite client configuration
- `ollama.env` - Local LLM runtime configuration
- `mojo.env` - Mojo language configuration
- `tree-sitter.env` - Tree-sitter parser configuration
- `op-cli.env` - 1Password CLI configuration

## Usage

### 1. Build Arguments vs Runtime Variables

**IMPORTANT**: The `.env` files in this directory contain ONLY runtime environment variables.

- **Build Arguments**: See [`../BUILD-ARGS.md`](../BUILD-ARGS.md) for the complete list
- **Runtime Environment Variables**: Configured in these `.env` files

Build arguments (like `INCLUDE_PYTHON`, `USERNAME`, etc.) must be set during build time via:
- `docker build --build-arg`
- `docker-compose.yml` under `build: args:`
- NOT in `.env` files

### 2. Creating Your Configuration

```bash
# Copy the examples you need
cp containers/env-examples/base.env .env
cp containers/env-examples/python.env .env.python
cp containers/env-examples/dev-tools.env .env.dev-tools

# Edit them with your values
vim .env
```

### 3. Using During Build

```bash
# Enable features during build
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  -t myproject:dev .

# Or use a build script that reads from env files
export $(cat .env | grep "^INCLUDE_" | xargs)
docker build \
  --build-arg INCLUDE_PYTHON=$INCLUDE_PYTHON \
  --build-arg INCLUDE_NODE=$INCLUDE_NODE \
  -t myproject:dev .
```

### 4. Using at Runtime

```bash
# Pass individual variables
docker run -e AWS_PROFILE=production myproject:dev

# Use env files
docker run --env-file .env --env-file .env.aws myproject:dev

# Docker Compose
# In docker-compose.yml:
services:
  app:
    env_file:
      - .env
      - .env.python
      - .env.aws
```

## Common Patterns

### Development Container
```bash
# Typical development setup
INCLUDE_PYTHON=true
INCLUDE_NODE=true
INCLUDE_DEV_TOOLS=true
INCLUDE_DOCKER=true
INCLUDE_GIT=true
```

### CI/CD Container
```bash
# Minimal CI build
INCLUDE_PYTHON=true
INCLUDE_DOCKER=true
```

### Cloud Development
```bash
# Cloud-focused development
INCLUDE_PYTHON=true
INCLUDE_TERRAFORM=true
INCLUDE_AWS=true
INCLUDE_KUBERNETES=true
```

## Security Notes

1. **Never commit real credentials** - These files show variable names, not values
2. **Use secrets management** - For production, use Docker secrets or vault systems
3. **Minimize exposure** - Only include variables actually needed by your application
4. **Rotate regularly** - Especially for cloud provider credentials

## Feature Dependencies

Some features depend on others:
- `tree-sitter` requires `rust`
- `python-dev` requires `python`
- `poetry` is included with `python`
- Many tools in `dev-tools` benefit from `git` being installed (in base)
- `mdBook` is included with `rust`

## Validation

To check which features are available in a built image:

```bash
# Check installed features
docker run --rm myproject:dev cat /etc/container-features.txt

# Test specific tools
docker run --rm myproject:dev python --version
docker run --rm myproject:dev node --version
docker run --rm myproject:dev go version
```