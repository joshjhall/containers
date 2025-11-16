# Configuration Validation Examples

This directory contains examples of how to use the configuration validation
framework to validate environment variables, detect secrets, and ensure proper
application configuration before container startup.

## Overview

The configuration validation framework provides:

- **Required variable validation** - Ensure critical environment variables are
  set
- **Format validation** - Validate URLs, paths, ports, emails, booleans
- **Secret detection** - Warn about plaintext secrets in environment variables
- **Custom validation rules** - Define application-specific validation logic
- **Clear error messages** - Helpful feedback with remediation steps

## Quick Start

### Enable Validation

Set the `VALIDATE_CONFIG` environment variable to enable validation:

````yaml
# docker-compose.yml
services:
  app:
    environment:
      - VALIDATE_CONFIG=true
```text

### Basic Usage

The validation framework automatically validates common patterns:

```bash
# Example environment variables
export DATABASE_URL="postgresql://user:pass@localhost:5432/mydb"
export REDIS_URL="redis://localhost:6379/0"
export PORT=3000

# Run container with validation enabled
docker run -e VALIDATE_CONFIG=true \
  -e DATABASE_URL="$DATABASE_URL" \
  -e REDIS_URL="$REDIS_URL" \
  -e PORT="$PORT" \
  myapp:latest
```text

## Configuration Options

| Variable                 | Default | Description                          |
| ------------------------ | ------- | ------------------------------------ |
| `VALIDATE_CONFIG`        | `false` | Enable configuration validation      |
| `VALIDATE_CONFIG_STRICT` | `false` | Treat warnings as errors             |
| `VALIDATE_CONFIG_RULES`  | -       | Path to custom validation rules file |
| `VALIDATE_CONFIG_QUIET`  | `false` | Suppress informational messages      |

## Custom Validation Rules

Create a custom validation rules file to define application-specific
validations:

```bash
# validation-rules.sh
cv_custom_validations() {
    # Require specific environment variables
    cv_require_var DATABASE_URL "Database connection string" \
        "Set DATABASE_URL to your PostgreSQL connection string"

    cv_require_var API_KEY "Application API key" \
        "Obtain an API key from the admin panel"

    # Validate URL formats
    cv_validate_url DATABASE_URL "postgresql"
    cv_validate_url REDIS_URL "redis"

    # Validate port numbers
    cv_validate_port PORT
    cv_validate_port METRICS_PORT

    # Validate paths
    cv_validate_path DATA_DIR true true  # Must exist and be a directory

    # Validate email addresses
    cv_validate_email ADMIN_EMAIL

    # Custom validation logic
    if [ "${ENABLE_FEATURE_X:-false}" = "true" ]; then
        cv_require_var FEATURE_X_CONFIG "Feature X configuration" \
            "Set FEATURE_X_CONFIG when ENABLE_FEATURE_X is true"
    fi
}
```text

Then use it in your container:

```yaml
# docker-compose.yml
services:
  app:
    environment:
      - VALIDATE_CONFIG=true
      - VALIDATE_CONFIG_RULES=/app/config/validation-rules.sh
    volumes:
      - ./validation-rules.sh:/app/config/validation-rules.sh:ro
```text

## Examples

### Example 1: Web Application

See `web-app-validation.sh` for a complete web application validation example:

- Database URL validation
- Redis URL validation
- Port validation
- Secret detection
- Required environment variables

```bash
docker-compose -f docker-compose.web-app.yml up
```text

### Example 2: API Service

See `api-service-validation.sh` for an API service validation example:

- Multiple database connections
- API key validation
- Rate limiting configuration
- Feature flags

```bash
docker-compose -f docker-compose.api-service.yml up
```text

### Example 3: Worker Service

See `worker-validation.sh` for a background worker validation example:

- Queue URL validation
- Concurrency settings
- Resource limits

```bash
docker-compose -f docker-compose.worker.yml up
```text

## Validation Functions

The framework provides these validation functions:

### Required Variables

```bash
cv_require_var VAR_NAME "Description" "Remediation hint"
```text

### URL Validation

```bash
# Any URL
cv_validate_url DATABASE_URL

# Specific scheme
cv_validate_url DATABASE_URL "postgresql"
cv_validate_url REDIS_URL "redis"
cv_validate_url API_ENDPOINT "https"
```text

### Path Validation

```bash
# Any path
cv_validate_path CONFIG_FILE

# Must exist
cv_validate_path DATA_DIR true

# Must exist and be a directory
cv_validate_path LOG_DIR true true
```text

### Port Validation

```bash
cv_validate_port PORT
cv_validate_port REDIS_PORT
```text

### Email Validation

```bash
cv_validate_email ADMIN_EMAIL
cv_validate_email SUPPORT_EMAIL
```text

### Boolean Validation

```bash
cv_validate_boolean ENABLE_DEBUG
cv_validate_boolean USE_SSL
```text

### Secret Detection

```bash
cv_detect_secrets API_KEY
cv_detect_secrets DATABASE_PASSWORD
```text

## Error Handling

When validation fails, the container will not start and will display:

```text
================================================================
  Configuration Validation
================================================================

✗ Required: Database connection string
  Variable: DATABASE_URL
  Fix: Set DATABASE_URL to your PostgreSQL connection string

✗ Invalid URL scheme: REDIS_URL
  Value: http://localhost:6379
  Expected scheme: redis

⚠ Potential plaintext secret detected: API_KEY
  Length: 32 characters
  Recommendation: Use environment variable references or secret management

================================================================
  Validation Summary
================================================================
✗ Errors: 2
⚠ Warnings: 1

Configuration validation failed. Please fix the errors above.
```text

## Best Practices

1. **Enable validation in development and staging** to catch configuration
   issues early
1. **Use strict mode in production** to enforce all validation rules:
   `VALIDATE_CONFIG_STRICT=true`
1. **Define custom rules** specific to your application's requirements
1. **Use secret management** instead of plaintext secrets in environment
   variables
1. **Validate URLs with schemes** to catch incorrect connection strings early
1. **Document validation rules** in your custom rules file for team clarity

## Secret Management Recommendations

Instead of plaintext secrets, use:

1. **Docker secrets** (Swarm mode):

   ```yaml
   services:
     app:
       secrets:
         - api_key
   secrets:
     api_key:
       external: true
````

1. **Kubernetes secrets**:

   ```yaml
   env:
     - name: API_KEY
       valueFrom:
         secretKeyRef:
           name: app-secrets
           key: api-key
   ```

1. **HashiCorp Vault**:

   ```bash
   export API_KEY=$(vault kv get -field=value secret/app/api-key)
   ```

1. **AWS Secrets Manager**:

   ```bash
   export API_KEY=$(aws secretsmanager get-secret-value --secret-id app/api-key --query SecretString --output text)
   ```

1. **Environment variable references**:

   ```bash
   # Store secret in file
   echo "secret-value" > /run/secrets/api-key

   # Reference in validation
   export API_KEY_FILE=/run/secrets/api-key
   ```

## Troubleshooting

### Validation passes but application fails

The validation framework checks basic format and presence, but cannot validate:

- Actual connectivity to services
- Authentication credentials correctness
- Service availability

Use application health checks and readiness probes for runtime validation.

### False positive secret warnings

If you get warnings for legitimate non-secret values:

````bash
# Add to custom validation rules
cv_custom_validations() {
    # Skip secret detection for specific variables
    if [ -n "${MY_VAR:-}" ]; then
        cv_success "Variable set: MY_VAR (secret check skipped)"
    fi
}
```text

### Disable validation temporarily

For debugging or emergencies:

```bash
# Disable validation
docker run -e VALIDATE_CONFIG=false myapp:latest

# Or override entrypoint
docker run --entrypoint /bin/bash myapp:latest
```text

## See Also

- [Configuration Validation Framework Source](../../lib/runtime/validate-config.sh)
- [Runtime Configuration Guide](../../docs/configuration.md)
- [Secret Management Guide](../../docs/security/secret-management.md)
- [Production Deployment Guide](../production/README.md)
````
