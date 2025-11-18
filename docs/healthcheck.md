# Container Health Checks

The container build system includes a comprehensive healthcheck script that
verifies container initialization and feature availability.

## Table of Contents

- [Overview](#overview)
- [Usage](#usage)
- [Docker Integration](#docker-integration)
- [Docker Compose Examples](#docker-compose-examples)
- [Monitoring](#monitoring)
- [Troubleshooting](#troubleshooting)

---

## Overview

The `healthcheck` script provides automated health monitoring for containers
with multiple modes:

- **Quick mode** (`--quick`): Core checks only (default for HEALTHCHECK)
- **Full mode**: Auto-detects and checks all installed features
- **Feature-specific** (`--feature`): Check individual features
- **Verbose mode** (`--verbose`): Detailed output for debugging

### What It Checks

**Core (Always):**

- Container user exists (UID 1000)
- Container initialized (`~/.container-initialized`)
- Essential directories (`/workspace`, `/cache`, `/etc/container`)
- Basic commands (`bash`, `sh`)

**Features (Auto-detected):**

- **Python**: python3, pip, cache directory
- **Node.js**: node, npm, cache directory
- **Rust**: rustc, cargo, cache directory
- **Go**: go, cache directories
- **Ruby**: ruby, gem, cache directory
- **R**: R, Rscript, cache directory
- **Java**: java, build tool caches
- **Docker**: docker CLI, daemon connectivity
- **Kubernetes**: kubectl, helm

---

## Usage

### Manual Execution

```bash
# Quick check (core only)
healthcheck --quick

# Full check (all installed features)
healthcheck

# Verbose output
healthcheck --verbose

# Check specific feature
healthcheck --feature python
healthcheck --feature node
healthcheck --feature go
```

### Exit Codes

- `0` - Container is healthy
- `1` - Container has health issues

### Example Output

```bash
$ healthcheck --verbose
[CHECK] Checking core container health...
[✓] Container user: vscode
[✓] Container initialized
[✓] Directory exists: /workspace
[✓] Directory exists: /cache
[✓] Directory exists: /etc/container
[✓] Command available: bash
[✓] Command available: sh
[CHECK] Checking Python...
[✓] Python installed: 3.13.1
[✓] pip available
[✓] Python cache configured
[CHECK] Checking Node.js...
[✓] Node.js installed: v22.12.0
[✓] npm available
[✓] Node cache configured
✓ Container is healthy
```

---

## Docker Integration

### Dockerfile HEALTHCHECK

The Dockerfile includes a built-in HEALTHCHECK instruction:

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
    CMD ["/usr/local/bin/healthcheck", "--quick"]
```

**Configuration:**

- **Interval**: 30 seconds between checks
- **Timeout**: 10 seconds per check
- **Retries**: 3 consecutive failures before unhealthy
- **Start Period**: 60 seconds grace period after container start

### Checking Container Health

```bash
# View health status
docker ps

# Inspect health check details
docker inspect <container_id> | jq '.[0].State.Health'

# View health check logs
docker inspect <container_id> | jq '.[0].State.Health.Log'

# Filter for unhealthy containers
docker ps --filter "health=unhealthy"
```

### Disabling Health Check

If needed, disable the healthcheck:

```bash
# In docker run
docker run --no-healthcheck myimage

# In Dockerfile
HEALTHCHECK NONE
```

---

## Docker Compose Examples

### Basic Health Check (Inherits from Dockerfile)

```yaml
services:
  app:
    build:
      context: .
      dockerfile: containers/Dockerfile
    # Healthcheck inherited from Dockerfile
    # No explicit configuration needed
```

### Custom Health Check Configuration

```yaml
services:
  app:
    build:
      context: .
      dockerfile: containers/Dockerfile
    healthcheck:
      test: ['CMD', 'healthcheck', '--verbose']
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
```

### Feature-Specific Health Check

```yaml
services:
  python-api:
    build:
      context: .
      dockerfile: containers/Dockerfile
      args:
        INCLUDE_PYTHON_DEV: 'true'
    healthcheck:
      test: ['CMD', 'healthcheck', '--feature', 'python']
      interval: 20s
      timeout: 5s
      retries: 3
```

### Dependent Services (Wait for Healthy)

```yaml
services:
  database:
    image: postgres:17-alpine
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U user']
      interval: 10s
      timeout: 5s
      retries: 5

  api:
    build:
      context: .
      dockerfile: containers/Dockerfile
    depends_on:
      database:
        condition: service_healthy # Wait for database
    healthcheck:
      test: ['CMD', 'healthcheck', '--quick']
      interval: 30s
      timeout: 10s
      retries: 3
```

### Quick vs. Full Checks

```yaml
services:
  # Production: Quick checks for minimal overhead
  production:
    healthcheck:
      test: ['CMD', 'healthcheck', '--quick']
      interval: 30s

  # Development: Full checks for comprehensive validation
  development:
    healthcheck:
      test: ['CMD', 'healthcheck', '--verbose']
      interval: 60s
```

---

## Monitoring

### Prometheus Integration

Export health status as Prometheus metrics:

```bash
#!/bin/bash
# healthcheck-exporter.sh
while true; do
    if healthcheck --quick; then
        echo "container_health{status=\"healthy\"} 1"
    else
        echo "container_health{status=\"healthy\"} 0"
    fi
    sleep 30
done
```

### Docker Events

Monitor health status changes:

```bash
# Watch health events
docker events --filter 'type=container' --filter 'event=health_status'

# Log unhealthy events
docker events --filter 'event=health_status: unhealthy' \
    --format '{{.Time}} {{.Actor.Attributes.name}}: {{.Status}}'
```

### Automated Restart

Docker automatically restarts unhealthy containers with
`restart: unless-stopped`:

```yaml
services:
  app:
    restart: unless-stopped # Restart on failure
    healthcheck:
      test: ['CMD', 'healthcheck']
      interval: 30s
      retries: 3
```

---

## Troubleshooting

### Common Issues

#### Container Marked Unhealthy

**Symptom**: Container shows as `unhealthy` in `docker ps`

**Diagnosis**:

```bash
# Check health logs
docker inspect <container_id> | jq '.[0].State.Health.Log[-1]'

# Run healthcheck manually
docker exec <container_id> healthcheck --verbose
```

**Common Causes**:

- Container not fully initialized (check `/home/<user>/.container-initialized`)
- Missing directories or permissions
- Feature installed but not functional

#### Healthcheck Timeout

**Symptom**: Healthcheck fails with timeout

**Solutions**:

- Increase timeout: `--timeout=20s`
- Use quick mode: `--quick`
- Check for slow disk I/O or resource constraints

#### False Negatives

**Symptom**: Healthcheck passes but container not working

**Diagnosis**:

```bash
# Run full healthcheck
docker exec <container_id> healthcheck --verbose

# Check specific feature
docker exec <container_id> healthcheck --feature python
```

**Solutions**:

- Use feature-specific checks instead of `--quick`
- Add custom application health check
- Verify environment variables and configuration

### Debugging

```bash
# Enable verbose output
docker exec <container_id> healthcheck --verbose

# Check specific feature
docker exec <container_id> healthcheck --feature node

# Check health check exit code
docker exec <container_id> healthcheck; echo $?

# View health check command
docker inspect <container_id> | jq '.[0].Config.Healthcheck'
```

### Custom Health Checks

The healthcheck system supports modular custom checks. Place executable scripts
in `/etc/healthcheck.d/` and they will be run automatically during full health
checks.

#### Custom Check Directory

```bash
# Directory structure
/etc/healthcheck.d/
├── 10-database.sh      # Check database connectivity
├── 20-redis.sh         # Check Redis connectivity
└── 30-external-api.sh  # Check external API

# Scripts run in sorted order (use numeric prefixes)
```

#### Example Custom Check Script

```bash
#!/bin/bash
# /etc/healthcheck.d/10-database.sh
# Check PostgreSQL connectivity

if ! pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
    echo "Database not ready"
    exit 1
fi

exit 0
```

#### Running Custom Checks Only

```bash
# Run only custom checks
healthcheck --feature custom

# Run full check (includes custom)
healthcheck --verbose
```

#### Custom Check Directory Override

Override the default directory with an environment variable:

```bash
# In docker-compose.yml
environment:
  HEALTHCHECK_CUSTOM_DIR: /app/health-checks

# Or at runtime
docker run -e HEALTHCHECK_CUSTOM_DIR=/app/checks myimage
```

#### Mounting Custom Checks at Runtime

```yaml
# docker-compose.yml
services:
  app:
    volumes:
      - ./my-checks:/etc/healthcheck.d:ro
    healthcheck:
      test: ['CMD', 'healthcheck', '--verbose']
```

#### Alternative: Wrapper Script

For application-specific health, combine with your own checks:

```bash
#!/bin/bash
# custom-healthcheck.sh

# Run built-in healthcheck
if ! healthcheck --quick; then
    exit 1
fi

# Check application endpoint
if ! curl -f http://localhost:8080/health; then
    exit 1
fi

exit 0
```

Then use in docker-compose:

```yaml
healthcheck:
  test: ['CMD', '/app/custom-healthcheck.sh']
```

---

## Best Practices

### Production

1. **Use quick mode** for minimal overhead
2. **Set reasonable intervals** (30s-60s)
3. **Allow adequate start period** for initialization
4. **Monitor health status** in orchestration platform
5. **Log health events** for debugging

### Development

1. **Use verbose mode** for detailed feedback
2. **Enable feature-specific checks** for debugging
3. **Reduce interval** for faster feedback (10s-20s)
4. **Test healthcheck manually** before deployment

### CI/CD

1. **Verify healthcheck passes** in integration tests
2. **Test health recovery** (stop/start services)
3. **Validate dependent services** wait for health
4. **Check health in deployment pipelines**

---

## See Also

- [Docker HEALTHCHECK reference](https://docs.docker.com/engine/reference/builder/#healthcheck)
- [Docker Compose healthcheck](https://docs.docker.com/compose/compose-file/compose-file-v3/#healthcheck)
- [examples/contexts/healthcheck-example.yml](../examples/contexts/healthcheck-example.yml)
