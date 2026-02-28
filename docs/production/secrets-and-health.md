# Secrets Management and Health Checks

This page covers secrets management best practices and health check
configuration for production containers.

## Secrets Management

### Never Store Secrets in Images

**Don't do this**:

- Build args containing secrets
- ENV variables with secrets in Dockerfile
- Secrets committed to code
- Secrets in .env files in image

### Use Secret Management Systems

**Docker Secrets** (Swarm/Compose):

```bash
# Create secret
echo "my-db-password" | docker secret create db_password -

# Use in service
docker service create \
  --secret db_password \
  --env DB_PASSWORD_FILE=/run/secrets/db_password \
  myapp:prod
```

**Kubernetes Secrets**:

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

**1Password Service Accounts**:

```bash
# Using OP_SERVICE_ACCOUNT_TOKEN at runtime
docker run \
  -e OP_SERVICE_ACCOUNT_TOKEN="your_token" \
  myapp:prod \
  sh -c 'my-app'
```

**HashiCorp Vault**:

```bash
docker run \
  -e VAULT_ADDR="https://vault.example.com" \
  -e VAULT_TOKEN="..." \
  myapp:prod
```

______________________________________________________________________

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
