# Runtime Configuration and Resource Limits

This page covers runtime configuration best practices and how to set resource
limits for production containers.

## Runtime Configuration

### Environment Variables

Use environment variables for configuration, NOT build arguments:

```bash
# DON'T: Secrets in build args (visible in image history)
docker build --build-arg API_KEY=secret123 .

# DO: Secrets at runtime
docker run -e API_KEY=secret123 myapp:prod
```

See [environment-variables.md](../reference/environment-variables.md) for available
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

**Complete Examples**: See [examples/validation/](../../examples/validation/) for
production-ready examples including:

- Web applications with databases
- API services with multiple backends
- Background workers with queues

## Resource Limits

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
