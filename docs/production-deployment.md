# Production Deployment Guide

This guide covers best practices and considerations for deploying containers
built with this system to production environments.

## Table of Contents

- [Overview](#overview)
- [Security Hardening](#security-hardening)
- [Image Optimization](#image-optimization)
- [Runtime Configuration](#runtime-configuration)
- [Secrets Management](#secrets-management)
- [Health Checks](#health-checks)
- [Logging and Monitoring](#logging-and-monitoring)
- [Resource Limits](#resource-limits)
- [Multi-Stage Builds for Production](#multi-stage-builds-for-production)
- [Container Registries](#container-registries)
- [Deployment Platforms](#deployment-platforms)
- [Checklist](#production-readiness-checklist)

---

## Overview

**Important**: This container build system is designed primarily for
**development environments**. For production deployments, additional hardening
and optimization is required.

### Development vs Production

| Aspect            | Development                 | Production                    |
| ----------------- | --------------------------- | ----------------------------- |
| **User**          | Non-root with sudo          | Non-root, NO sudo             |
| **Secrets**       | Can be in env vars          | Must use secrets management   |
| **Image Size**    | Larger (includes dev tools) | Minimized (only runtime deps) |
| **Updates**       | Frequent                    | Controlled, tested            |
| **Logging**       | Verbose                     | Structured, minimal           |
| **Health Checks** | Optional                    | Required                      |

---

## Security Hardening

### Disable Passwordless Sudo

**Critical**: Never enable passwordless sudo in production.

```bash
# Build for production WITHOUT sudo
docker build \
  --build-arg ENABLE_PASSWORDLESS_SUDO=false \
  -t myapp:prod .
```

**Verification**:

```bash
docker run --rm myapp:prod sudo whoami 2>&1 | grep -q "sudo: a password is required"
```

### Run as Non-Root User

Containers should run as a non-root user by default. This is handled
automatically.

```dockerfile
# Verify USER directive in your derived Dockerfile
USER ${USERNAME}
```

**Runtime verification**:

```bash
docker run --rm myapp:prod whoami
# Should output: developer (or your USERNAME)

docker run --rm myapp:prod id
# Should show uid=1000 (not root/0)
```

### Read-Only Root Filesystem

For maximum security, run with a read-only root filesystem:

```bash
docker run --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \
  --tmpfs /var/tmp:rw,noexec,nosuid,size=100m \
  myapp:prod
```

**Note**: Application must not write to filesystem except designated
volumes/tmpfs.

### Drop Capabilities

Remove unnecessary Linux capabilities:

```bash
docker run \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  myapp:prod
```

**Common capabilities needed**:

- `NET_BIND_SERVICE`: Bind to ports < 1024
- `CHOWN`: Change file ownership (usually not needed)
- `SETUID/SETGID`: Change user/group (usually not needed)

### Security Scanning

Scan images for vulnerabilities before deployment:

```bash
# Using Trivy
trivy image myapp:prod

# Using Docker Scout
docker scout cves myapp:prod

# Using Snyk
snyk container test myapp:prod
```

---

## Image Optimization

### Minimize Image Size

Only include necessary features for production:

```bash
# ❌ DON'T: Include all dev tools in production
docker build \
  --build-arg INCLUDE_PYTHON_DEV=true \
  --build-arg INCLUDE_NODE_DEV=true \
  --build-arg INCLUDE_DEV_TOOLS=true \
  -t myapp:prod .

# ✅ DO: Only runtime dependencies
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_NODE=true \
  -t myapp:prod .
```

### Multi-Stage Builds

Create optimized production images:

```dockerfile
# Build stage - includes dev tools
FROM ghcr.io/joshjhall/containers:full-dev AS builder

WORKDIR /build
COPY . .

# Build your application
RUN pip install --no-cache-dir -r requirements.txt && \
    python setup.py build

# Production stage - minimal runtime
FROM ghcr.io/joshjhall/containers:python-runtime AS production

WORKDIR /app
COPY --from=builder /build/dist ./dist
COPY --from=builder /build/app ./app

USER developer
CMD ["python", "app/main.py"]
```

### Layer Optimization

Minimize layer count and size:

```dockerfile
# ❌ Bad: Many layers, cache busting
RUN apt-get update
RUN apt-get install -y package1
RUN apt-get install -y package2
RUN rm -rf /var/lib/apt/lists/*

# ✅ Good: Single layer, clean cache
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      package1 \
      package2 && \
    rm -rf /var/lib/apt/lists/*
```

---

## Runtime Configuration

### Environment Variables

Use environment variables for configuration, NOT build arguments:

```bash
# ❌ DON'T: Secrets in build args (visible in image history)
docker build --build-arg API_KEY=secret123 .

# ✅ DO: Secrets at runtime
docker run -e API_KEY=secret123 myapp:prod
```

See [environment-variables.md](reference/environment-variables.md) for available
variables.

### Configuration Validation

**Production Best Practice**: Enable runtime configuration validation to catch
misconfiguration issues before they cause failures.

The validation framework validates environment variables, checks formats (URLs,
ports, emails, etc.), and detects potential plaintext secrets:

```bash
# Enable validation in production
docker run \
  -e VALIDATE_CONFIG=true \
  -e VALIDATE_CONFIG_STRICT=true \
  -e DATABASE_URL=postgresql://... \
  -e REDIS_URL=redis://... \
  myapp:prod
```

**Key Features**:

- Required environment variable validation
- Format validation (URLs, ports, emails, booleans, paths)
- Secret detection with warnings for plaintext passwords/keys
- Custom validation rules support
- Strict mode (treat warnings as errors)

**Example custom validation rules**:

```bash
# custom-validation.sh
cv_custom_validations() {
    # Validate required variables
    cv_require_var DATABASE_URL "PostgreSQL connection string" "Set DATABASE_URL"
    cv_require_var SECRET_KEY "Application secret key" "Set SECRET_KEY"

    # Validate formats
    cv_validate_url DATABASE_URL "postgresql"
    cv_validate_port API_PORT
    cv_validate_email ADMIN_EMAIL

    # Detect plaintext secrets
    cv_detect_secrets SECRET_KEY
    cv_detect_secrets JWT_SECRET
}
```

```bash
# Run with custom validation
docker run \
  -e VALIDATE_CONFIG=true \
  -e VALIDATE_CONFIG_RULES=/app/config/validation.sh \
  -v ./custom-validation.sh:/app/config/validation.sh:ro \
  myapp:prod
```

**Complete Examples**: See [examples/validation/](../examples/validation/) for
production-ready examples including:

- Web applications with databases
- API services with multiple backends
- Background workers with queues

### Resource Limits

Always set resource limits in production:

```bash
docker run \
  --memory="512m" \
  --memory-swap="1g" \
  --cpus="1.0" \
  --pids-limit=100 \
  myapp:prod
```

**Kubernetes example**:

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: myapp
      image: myapp:prod
      resources:
        requests:
          memory: '256Mi'
          cpu: '250m'
        limits:
          memory: '512Mi'
          cpu: '500m'
```

---

## Secrets Management

### Never Store Secrets in Images

**❌ Don't do this**:

- Build args containing secrets
- ENV variables with secrets in Dockerfile
- Secrets committed to code
- Secrets in .env files in image

### Use Secret Management Systems

**✅ Docker Secrets** (Swarm/Compose):

```bash
# Create secret
echo "my-db-password" | docker secret create db_password -

# Use in service
docker service create \
  --secret db_password \
  --env DB_PASSWORD_FILE=/run/secrets/db_password \
  myapp:prod
```

**✅ Kubernetes Secrets**:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
type: Opaque
stringData:
  database-url: 'postgresql://...'
---
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: myapp
      envFrom:
        - secretRef:
            name: app-secrets
```

**✅ 1Password Service Accounts**:

```bash
# Using OP_SERVICE_ACCOUNT_TOKEN at runtime
docker run \
  -e OP_SERVICE_ACCOUNT_TOKEN="your_token" \
  myapp:prod \
  sh -c 'eval $(op signin) && my-app'
```

**✅ HashiCorp Vault**:

```bash
docker run \
  -e VAULT_ADDR="https://vault.example.com" \
  -e VAULT_TOKEN="..." \
  myapp:prod
```

---

## Health Checks

### Container Health Checks

Define health checks for orchestrators:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1
```

**Or at runtime**:

```bash
docker run \
  --health-cmd="curl -f http://localhost:8080/health || exit 1" \
  --health-interval=30s \
  --health-timeout=3s \
  --health-retries=3 \
  myapp:prod
```

### Kubernetes Probes

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: myapp
      livenessProbe:
        httpGet:
          path: /health
          port: 8080
        initialDelaySeconds: 5
        periodSeconds: 10
      readinessProbe:
        httpGet:
          path: /ready
          port: 8080
        initialDelaySeconds: 3
        periodSeconds: 5
```

### Using Built-in Health Scripts

This system includes health check scripts:

```dockerfile
# Use the included health check script
HEALTHCHECK --interval=30s CMD /usr/local/bin/container-health-check.sh
```

---

## Logging and Monitoring

### Structured Logging

Use structured logging format (JSON) for production:

```python
import logging
import json

logging.basicConfig(
    format='%(message)s',
    level=logging.INFO
)

# Log as JSON
logging.info(json.dumps({
    "level": "info",
    "message": "Request processed",
    "duration_ms": 42,
    "user_id": 123
}))
```

### Log to STDOUT/STDERR

Always log to stdout/stderr, not files:

```bash
# ✅ Good: Logs go to container logs
python app.py

# ❌ Bad: Logs go to file (not collected)
python app.py > /var/log/app.log 2>&1
```

### Centralized Logging

Forward logs to centralized system:

- **Docker**: Use log drivers

  ```bash
  docker run \
    --log-driver=fluentd \
    --log-opt fluentd-address=localhost:24224 \
    myapp:prod
  ```

- **Kubernetes**: Use DaemonSet log collectors (Fluentd, Filebeat)

### Metrics and Monitoring

Expose metrics for Prometheus/monitoring:

```python
from prometheus_client import Counter, start_http_server

requests_total = Counter('http_requests_total', 'Total HTTP requests')

# Start metrics server on :9090
start_http_server(9090)
```

---

## Resource Limits

### Memory Limits

Set appropriate memory limits:

```bash
# Development: Generous limits
docker run --memory="2g" myapp:dev

# Production: Tight limits based on profiling
docker run --memory="512m" --memory-reservation="256m" myapp:prod
```

**OOM Handling**:

```bash
# Get notified when OOM occurs
docker run \
  --memory="512m" \
  --oom-kill-disable=false \
  myapp:prod
```

### CPU Limits

Control CPU usage:

```bash
# Limit to 50% of one CPU
docker run --cpus="0.5" myapp:prod

# CPU shares (relative weight)
docker run --cpu-shares=512 myapp:prod
```

### Disk I/O Limits

Limit disk I/O to prevent resource exhaustion:

```bash
docker run \
  --device-read-bps /dev/sda:10mb \
  --device-write-bps /dev/sda:10mb \
  myapp:prod
```

---

## Multi-Stage Builds for Production

### Pattern: Build + Runtime Stages

```dockerfile
# Stage 1: Build environment with dev tools
FROM myproject:full-dev AS builder

WORKDIR /build
COPY requirements.txt pyproject.toml ./
RUN pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir build

COPY src/ ./src/
RUN python -m build

# Stage 2: Minimal runtime image
FROM myproject:python-runtime AS production

# Copy only built artifacts
COPY --from=builder /build/dist/*.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl && \
    rm /tmp/*.whl

# Copy application
COPY app/ /app/
WORKDIR /app

# Run as non-root
USER developer

# Health check
HEALTHCHECK CMD curl -f http://localhost:8080/health || exit 1

CMD ["python", "-m", "app"]
```

---

## Container Registries

### Push to Production Registry

```bash
# Tag for registry
docker tag myapp:prod registry.example.com/myapp:1.0.0
docker tag myapp:prod registry.example.com/myapp:latest

# Push
docker push registry.example.com/myapp:1.0.0
docker push registry.example.com/myapp:latest
```

### Image Signing (Content Trust)

Enable Docker Content Trust:

```bash
# Enable DCT
export DOCKER_CONTENT_TRUST=1

# Sign and push
docker push registry.example.com/myapp:1.0.0
```

### Image Scanning in Registry

Configure automatic scanning:

**Docker Hub**:

- Enable automatic vulnerability scanning in repository settings

**AWS ECR**:

```bash
aws ecr put-image-scanning-configuration \
  --repository-name myapp \
  --image-scanning-configuration scanOnPush=true
```

**Google Artifact Registry**:

- Enable vulnerability scanning in registry settings

---

## Deployment Platforms

### Docker Compose (Simple Production)

```yaml
version: '3.8'

services:
  app:
    image: registry.example.com/myapp:1.0.0
    restart: unless-stopped
    environment:
      - NODE_ENV=production
    env_file:
      - .env.production
    secrets:
      - db_password
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:8080/health']
      interval: 30s
      timeout: 3s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '10m'
        max-file: '3'
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.5'
          memory: 256M

secrets:
  db_password:
    external: true
```

### Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
        - name: myapp
          image: registry.example.com/myapp:1.0.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          env:
            - name: NODE_ENV
              value: 'production'
          envFrom:
            - secretRef:
                name: myapp-secrets
          resources:
            requests:
              memory: '256Mi'
              cpu: '250m'
            limits:
              memory: '512Mi'
              cpu: '500m'
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
```

### AWS ECS/Fargate

```json
{
  "family": "myapp",
  "taskRoleArn": "arn:aws:iam::123456789:role/myapp-task",
  "executionRoleArn": "arn:aws:iam::123456789:role/myapp-execution",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "myapp",
      "image": "registry.example.com/myapp:1.0.0",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:8080/health || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/myapp",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "secrets": [
        {
          "name": "DATABASE_URL",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789:secret:myapp-db"
        }
      ]
    }
  ]
}
```

---

## Production Readiness Checklist

### Security

- [ ] Passwordless sudo disabled (`ENABLE_PASSWORDLESS_SUDO=false`)
- [ ] Running as non-root user
- [ ] No secrets in build arguments or ENV in Dockerfile
- [ ] Secrets management system in place
- [ ] Image scanned for vulnerabilities
- [ ] Security updates applied
- [ ] Read-only root filesystem (if applicable)
- [ ] Capabilities dropped to minimum required

### Optimization

- [ ] Only necessary features included (no dev tools)
- [ ] Multi-stage build for minimal size
- [ ] Layers optimized
- [ ] Base image regularly updated
- [ ] Image tagged with version, not just `latest`

### Reliability

- [ ] Health check endpoint implemented
- [ ] Liveness and readiness probes configured
- [ ] Resource limits set (memory, CPU)
- [ ] Restart policy configured
- [ ] Graceful shutdown handling
- [ ] Logging to stdout/stderr
- [ ] Structured logging format

### Monitoring

- [ ] Metrics exposed (Prometheus format)
- [ ] Centralized logging configured
- [ ] Alerts configured for critical metrics
- [ ] APM/tracing integrated (optional)

### Deployment

- [ ] CI/CD pipeline for builds
- [ ] Automated testing before deployment
- [ ] Blue-green or canary deployment strategy
- [ ] Rollback procedure documented
- [ ] Image pushed to production registry
- [ ] Image signing enabled (optional)

### Documentation

- [ ] Production configuration documented
- [ ] Runbook for common issues
- [ ] Secrets management documented
- [ ] Deployment procedure documented

---

## Related Documentation

- [Security Best Practices](security-hardening.md) - Comprehensive security
  guide
- [Environment Variables](reference/environment-variables.md) - Configuration
  reference
- [Troubleshooting](troubleshooting.md) - Common issues and solutions
- [CLAUDE.md](../CLAUDE.md) - Build system overview

---

## Getting Help

For production deployment assistance:

1. Review this guide thoroughly
2. Check [troubleshooting.md](troubleshooting.md) for common issues
3. Review security hardening documentation
4. Open an issue on GitHub for specific questions
