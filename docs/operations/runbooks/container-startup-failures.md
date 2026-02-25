# Container Startup Failures

Debug and resolve container startup failures.

## Symptoms

- Container exits immediately after start
- Container stuck in `CrashLoopBackOff` (Kubernetes)
- Health check never passes
- Container shows as `unhealthy` in `docker ps`

## Quick Checks

```bash
# Check container logs
docker logs <container_id>

# Check exit code
docker inspect <container_id> --format='{{.State.ExitCode}}'

# Check health status
docker inspect <container_id> --format='{{.State.Health.Status}}'

# Kubernetes: Check pod events
kubectl describe pod <pod_name>
```

## Common Causes

### 1. Missing Environment Variables

**Symptom**: Error messages about undefined variables

**Check**:

```bash
docker run --rm <image> env | grep -E "^(PATH|HOME|USER)"
```

**Fix**: Ensure required variables are set in compose or deployment

### 2. Initialization Script Failure

**Symptom**: Exit code 1, errors in logs about first-startup

**Check**:

```bash
# Check if initialization completed
docker run --rm <image> ls -la ~/.container-initialized

# Check build logs
docker run --rm <image> check-build-logs.sh
```

**Fix**: Review initialization script output for specific errors

### 3. Permission Denied

**Symptom**: "Permission denied" errors in logs

**Check**:

```bash
# Check file ownership
docker run --rm <image> ls -la /workspace /cache

# Check user
docker run --rm <image> id
```

**Fix**: See [permission-issues.md](permission-issues.md)

### 4. Missing Dependencies

**Symptom**: "command not found" or "module not found" errors

**Check**:

```bash
# Check installed features
docker run --rm <image> cat /etc/container/features.json

# Check PATH
docker run --rm <image> echo $PATH
```

**Fix**: Rebuild with required features enabled

### 5. Resource Constraints

**Symptom**: OOMKilled or resource limit exceeded

**Check**:

```bash
# Kubernetes
kubectl describe pod <pod_name> | grep -A5 "Last State"

# Docker
docker inspect <container_id> --format='{{.State.OOMKilled}}'
```

**Fix**: Increase resource limits or optimize application memory usage

## Diagnostic Steps

### Step 1: Get Container Logs

```bash
# Full logs
docker logs <container_id>

# Last 100 lines
docker logs --tail 100 <container_id>

# Follow logs
docker logs -f <container_id>

# Kubernetes
kubectl logs <pod_name> --previous
```

### Step 2: Check Exit Code

| Exit Code | Meaning                 | Common Cause             |
| --------- | ----------------------- | ------------------------ |
| 0         | Success                 | Container completed task |
| 1         | General error           | Script/app failure       |
| 126       | Permission problem      | File not executable      |
| 127       | Command not found       | Missing binary/PATH      |
| 137       | SIGKILL (OOM or forced) | Memory limit exceeded    |
| 139       | SIGSEGV                 | Segmentation fault       |
| 143       | SIGTERM                 | Graceful shutdown        |

### Step 3: Interactive Debug

```bash
# Override entrypoint to get shell
docker run -it --rm --entrypoint /bin/bash <image>

# Check environment
env | sort

# Test initialization manually
/usr/local/bin/entrypoint.sh

# Run healthcheck
healthcheck --verbose
```

### Step 4: Check Volumes and Mounts

```bash
# List mounts
docker inspect <container_id> --format='{{json .Mounts}}' | jq

# Check mount permissions
docker run --rm -v /host/path:/container/path <image> ls -la /container/path

# Verify writable
docker run --rm -v /host/path:/container/path <image> touch /container/path/test
```

### Step 5: Verify Image Integrity

```bash
# Pull fresh image
docker pull <image>

# Verify signature
cosign verify \
  --certificate-identity-regexp='^https://github.com/joshjhall/containers' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  <image>
```

## Resolution

### Container Won't Initialize

```bash
# Remove initialization flag to retry
docker run --rm -v <volume>:/home/vscode <image> \
  rm -f /home/vscode/.container-initialized

# Then restart container
docker start <container_id>
```

### Entrypoint Override

```bash
# Skip normal entrypoint for debugging
docker run -it --rm --entrypoint /bin/bash <image>

# Then manually run entrypoint
/usr/local/bin/entrypoint.sh
```

### Kubernetes CrashLoopBackOff

```yaml
# Add debug sleep to keep pod running
spec:
  containers:
    - name: app
      command: ['sleep', 'infinity']
```

Then exec in to debug:

```bash
kubectl exec -it <pod_name> -- /bin/bash
```

## Prevention

1. **Test locally** before deploying to production
1. **Use health checks** to detect startup failures early
1. **Set appropriate resource limits** based on actual usage
1. **Pin image versions** to avoid unexpected changes
1. **Review logs** as part of deployment verification

## Escalation

If the issue persists after following this runbook:

1. Collect all logs and diagnostic output
1. Note the exact error message and exit code
1. Document steps already attempted
1. Open a GitHub issue with the `bug` label
