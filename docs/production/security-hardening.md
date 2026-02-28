# Production Security Hardening

This page covers security best practices specific to production container
deployments.

## Disable Passwordless Sudo

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

## Run as Non-Root User

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

## Read-Only Root Filesystem

For maximum security, run with a read-only root filesystem:

```bash
docker run --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \
  --tmpfs /var/tmp:rw,noexec,nosuid,size=100m \
  myapp:prod
```

**Note**: Application must not write to filesystem except designated
volumes/tmpfs.

## Drop Capabilities

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

## Security Scanning

Scan images for vulnerabilities before deployment:

```bash
# Using Trivy
trivy image myapp:prod

# Using Docker Scout
docker scout cves myapp:prod

# Using Snyk
snyk container test myapp:prod
```
