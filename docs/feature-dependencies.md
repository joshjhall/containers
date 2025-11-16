# Feature Dependencies

This document describes dependencies between features and how to resolve them
when building containers.

## Overview

Some features depend on other features being installed first. For example,
`python-dev` requires `python` to be installed. The build system does not
automatically enable dependent features - you must explicitly enable them.

## Dependency Graph

```
python-dev → python
node-dev → node
rust-dev → rust
ruby-dev → ruby
r-dev → r
golang-dev → golang
java-dev → java
mojo-dev → mojo
cloudflare → node (wrangler requires Node.js)
```

## Feature Dependencies Reference

### Language Development Tools

All `-dev` features require their base language:

| Dev Feature  | Requires | Build Args                                          |
| ------------ | -------- | --------------------------------------------------- |
| `python-dev` | `python` | `INCLUDE_PYTHON=true`<br/>`INCLUDE_PYTHON_DEV=true` |
| `node-dev`   | `node`   | `INCLUDE_NODE=true`<br/>`INCLUDE_NODE_DEV=true`     |
| `rust-dev`   | `rust`   | `INCLUDE_RUST=true`<br/>`INCLUDE_RUST_DEV=true`     |
| `ruby-dev`   | `ruby`   | `INCLUDE_RUBY=true`<br/>`INCLUDE_RUBY_DEV=true`     |
| `r-dev`      | `r`      | `INCLUDE_R=true`<br/>`INCLUDE_R_DEV=true`           |
| `golang-dev` | `golang` | `INCLUDE_GOLANG=true`<br/>`INCLUDE_GOLANG_DEV=true` |
| `java-dev`   | `java`   | `INCLUDE_JAVA=true`<br/>`INCLUDE_JAVA_DEV=true`     |
| `mojo-dev`   | `mojo`   | `INCLUDE_MOJO=true`<br/>`INCLUDE_MOJO_DEV=true`     |

### Cloud Tools

| Feature      | Requires | Notes                      |
| ------------ | -------- | -------------------------- |
| `cloudflare` | `node`   | Wrangler is an npm package |

### Standalone Features

These features have no dependencies and can be installed independently:

- `dev-tools` - General development tools
- `docker` - Docker CLI tools
- `op-cli` - 1Password CLI
- `aws` - AWS CLI
- `gcloud` - Google Cloud SDK
- `kubernetes` - kubectl, k9s, helm
- `terraform` - Terraform and related tools
- `postgres-client` - PostgreSQL client
- `redis-client` - Redis client
- `sqlite-client` - SQLite client
- `ollama` - Local LLM runtime

## Common Build Patterns

### Installing a Language with Dev Tools

**Always enable both the base language AND the dev tools**:

```bash
# ✅ Correct: Both features enabled
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  -t myproject:python-dev .

# ❌ Wrong: Only dev tools (will fail)
docker build \
  --build-arg INCLUDE_PYTHON_DEV=true \
  -t myproject:python-dev .
```

### Multiple Languages with Dev Tools

```bash
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_RUST=true \
  --build-arg INCLUDE_RUST_DEV=true \
  -t myproject:polyglot .
```

### Production: Languages Without Dev Tools

For production, omit dev tools:

```bash
# Only runtime, no dev tools
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_NODE=true \
  -t myproject:prod .
```

### Cloudflare Development

Requires Node.js for wrangler:

```bash
docker build \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_CLOUDFLARE=true \
  -t myproject:cloudflare .
```

## Troubleshooting Dependency Issues

### Error: Command not found after installing dev tools

**Symptom**: Installed `python-dev` but `python3` command not found.

**Cause**: Forgot to enable the base `python` feature.

**Solution**:

```bash
# Enable both features
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  -t myproject:fixed .
```

### Error: Module not found when running dev tools

**Symptom**: Commands like `pytest` or `eslint` fail with import errors.

**Cause**: Base language not installed, so Python/Node packages can't run.

**Solution**: Enable base language feature.

### Checking What's Installed

Use the built-in verification tools:

```bash
# List all installed features and versions
docker run --rm myproject:dev check-installed-versions.sh

# Test specific feature
docker run --rm myproject:dev test-python
docker run --rm myproject:dev test-node
```

### Using list-features.sh

Check dependencies before building:

```bash
# List all features with dependencies
bin/list-features.sh

# Get JSON with dependency info
bin/list-features.sh --json | jq '.features[] | select(.dependencies | length > 0)'
```

## Automatic Dependency Resolution (Future Enhancement)

**Current behavior**: Dependencies are NOT automatically resolved. You must
explicitly enable all required features.

**Future enhancement**: See
[docs/planned/improvements-roadmap.md](planned/improvements-roadmap.md) for
planned automatic dependency resolution.

**Example of planned behavior**:

```bash
# Future: Automatically enables INCLUDE_PYTHON=true
docker build --build-arg INCLUDE_PYTHON_DEV=true .
```

## Feature Compatibility Matrix

### Language Combinations

All language features are compatible and can be installed together:

```bash
# Install all languages
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_RUST=true \
  --build-arg INCLUDE_RUBY=true \
  --build-arg INCLUDE_GOLANG=true \
  --build-arg INCLUDE_JAVA=true \
  --build-arg INCLUDE_R=true \
  -t myproject:polyglot .
```

### Tool Combinations

All tool features are compatible:

```bash
# Install all cloud tools
docker build \
  --build-arg INCLUDE_AWS=true \
  --build-arg INCLUDE_GCLOUD=true \
  --build-arg INCLUDE_KUBERNETES=true \
  --build-arg INCLUDE_TERRAFORM=true \
  --build-arg INCLUDE_CLOUDFLARE=true \
  --build-arg INCLUDE_NODE=true \
  -t myproject:cloud .
```

### Database Clients

All database clients are compatible:

```bash
# Install all database clients
docker build \
  --build-arg INCLUDE_POSTGRES_CLIENT=true \
  --build-arg INCLUDE_REDIS_CLIENT=true \
  --build-arg INCLUDE_SQLITE_CLIENT=true \
  -t myproject:databases .
```

## Recommended Combinations

### Full-Stack Web Development

```bash
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_POSTGRES_CLIENT=true \
  --build-arg INCLUDE_REDIS_CLIENT=true \
  --build-arg INCLUDE_DOCKER=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  -t myproject:fullstack .
```

### Data Science

```bash
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_R=true \
  --build-arg INCLUDE_R_DEV=true \
  --build-arg INCLUDE_POSTGRES_CLIENT=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  -t myproject:datascience .
```

### Systems Programming

```bash
docker build \
  --build-arg INCLUDE_RUST=true \
  --build-arg INCLUDE_RUST_DEV=true \
  --build-arg INCLUDE_GOLANG=true \
  --build-arg INCLUDE_GOLANG_DEV=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  -t myproject:systems .
```

### Cloud-Native Development

```bash
docker build \
  --build-arg INCLUDE_GOLANG=true \
  --build-arg INCLUDE_GOLANG_DEV=true \
  --build-arg INCLUDE_DOCKER=true \
  --build-arg INCLUDE_KUBERNETES=true \
  --build-arg INCLUDE_TERRAFORM=true \
  --build-arg INCLUDE_AWS=true \
  --build-arg INCLUDE_GCLOUD=true \
  -t myproject:cloudnative .
```

## Environment Variable Examples

See complete examples in [examples/env/](../examples/env/) directory:

- `python-dev.env` - Python development setup
- `node-dev.env` - Node.js development setup
- `fullstack.env` - Full-stack web development
- `cloudflare.env` - Cloudflare Workers development

## Scripting Build Configurations

### Using Environment Files

Create environment files for different configurations:

```bash
# dev.env
INCLUDE_PYTHON=true
INCLUDE_PYTHON_DEV=true
INCLUDE_NODE=true
INCLUDE_NODE_DEV=true
INCLUDE_DOCKER=true
INCLUDE_DEV_TOOLS=true

# Build using env file
set -a
source dev.env
set +a

docker build \
  $(env | grep '^INCLUDE_' | sed 's/^/--build-arg /') \
  -t myproject:dev .
```

### Build Script Example

```bash
#!/bin/bash
# build-dev.sh - Build development image with all tools

set -euo pipefail

# Define features
FEATURES=(
    "PYTHON:true"
    "PYTHON_DEV:true"
    "NODE:true"
    "NODE_DEV:true"
    "DEV_TOOLS:true"
    "DOCKER:true"
)

# Build docker command
BUILD_ARGS=""
for feature in "${FEATURES[@]}"; do
    IFS=':' read -r name value <<< "$feature"
    BUILD_ARGS+="--build-arg INCLUDE_${name}=${value} "
done

# Execute build
docker build $BUILD_ARGS -t myproject:dev .
```

## Testing Dependencies

### Verify All Dependencies Met

```bash
# After build, verify all expected tools are available
docker run --rm myproject:dev bash -c '
  python3 --version &&
  pytest --version &&
  node --version &&
  npm --version &&
  echo "All dependencies satisfied!"
'
```

### Integration Tests

Use the test framework to verify feature combinations:

```bash
# Run integration tests for specific build
./tests/run_integration_tests.sh python_dev
./tests/run_integration_tests.sh node_dev
./tests/run_integration_tests.sh fullstack
```

## Related Documentation

- [environment-variables.md](environment-variables.md) - Complete variable
  reference
- [CLAUDE.md](../CLAUDE.md) - Build system overview and examples
- [troubleshooting.md](troubleshooting.md) - Common dependency issues
- [examples/env/](../examples/env/) - Environment file examples
- [planned/improvements-roadmap.md](planned/improvements-roadmap.md) - Future
  enhancements
