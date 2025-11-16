# Alert: Container Unhealthy

## Overview

- **Alert Name**: ContainerUnhealthy
- **Severity**: Critical
- **Component**: runtime
- **Threshold**: Healthcheck status == 0 for 2 minutes

## Description

The container healthcheck is failing, indicating a critical issue with the container runtime environment. This means core functionality (user, directories, essential commands, or installed features) is not working correctly.

## Impact

### User Impact

- **HIGH**: Users cannot use the container for development or production workloads
- Container may be restarting repeatedly
- Work in progress may be lost if container terminates

### System Impact

- Container orchestration (Kubernetes, Docker Swarm) may kill and restart the container
- Dependent services may fail if they rely on this container
- Metrics and logs may be incomplete due to restart cycles

## Diagnosis

### Quick Checks

1. **Verify container is running**:

   ```bash
   docker ps | grep <container-name>
   # or for Kubernetes
   kubectl get pods | grep <pod-name>
   ```

2. **Run healthcheck manually**:

   ```bash
   # Inside container
   healthcheck --verbose

   # Or from outside
   docker exec <container-id> healthcheck --verbose
   ```

3. **Check recent logs**:

   ```bash
   docker logs <container-id> --tail 100
   # or for Kubernetes
   kubectl logs <pod-name> --tail 100
   ```

### Detailed Investigation

#### 1. Identify Failed Check

```bash
# Run full healthcheck with verbose output
healthcheck --verbose

# Check specific features
healthcheck --feature python
healthcheck --feature node
```

Look for output like:

```text
[CHECK] Checking core container health...
[✓] Container user: vscode
[✗] Container initialized
[✓] Directory exists: /workspace
```

#### 2. Check System Resources

```bash
# Check disk space
df -h

# Check memory (if available)
free -h

# Check running processes
ps aux | head -20
```

#### 3. Check Initialization

```bash
# Verify container initialization file
ls -la ~/.container-initialized

# Check if initialization failed
cat /var/log/container-build/master-summary.log | tail -20
```

#### 4. Check for Missing Dependencies

```bash
# Verify essential commands
which bash sh python3 node go

# Check specific feature installations
check-installed-versions.sh
```

### Common Causes

1. **Incomplete initialization**: Container started before initialization completed
2. **Disk full**: No space left for healthcheck or feature operation
3. **Missing dependencies**: Feature installation failed during build
4. **Corrupted files**: Critical files were deleted or corrupted
5. **Permission issues**: Files/directories have wrong ownership
6. **Resource exhaustion**: Out of memory, file descriptors, etc.

## Resolution

### Quick Fix (Immediate Mitigation)

```bash
# Option 1: Restart container
docker restart <container-id>
# or for Kubernetes
kubectl rollout restart deployment/<deployment-name>

# Option 2: Force recreation
docker-compose up -d --force-recreate <service-name>

# Option 3: Rollback to previous version (Kubernetes)
kubectl rollout undo deployment/<deployment-name>
```

### Permanent Fix

#### If Initialization Failed

```bash
# Remove incomplete initialization marker
rm ~/.container-initialized

# Restart container to re-run initialization
docker restart <container-id>
```

#### If Disk Full

```bash
# Clean cache directories
rm -rf /cache/pip/* /cache/npm/* /cache/cargo/* /cache/go/*

# Clean old logs
find /var/log/container-build -type f -mtime +7 -delete

# Clean temporary files
rm -rf /tmp/*
```

#### If Dependencies Missing

```bash
# Check build logs for the failed feature
check-build-logs.sh <feature-name>

# Rebuild container with verbose logging
docker build --progress=plain --no-cache -t <image> .
```

#### If Permission Issues

```bash
# Fix ownership (run as root)
chown -R vscode:vscode /workspace /cache ~/.container-initialized

# Fix permissions on key directories
chmod 755 /workspace /cache
chmod 644 ~/.container-initialized
```

### Verification

```bash
# 1. Run healthcheck
healthcheck --verbose
# Should show all ✓

# 2. Check metrics
curl http://localhost:9090/metrics | grep container_healthcheck_status
# Should return: container_healthcheck_status 1

# 3. Monitor for 5 minutes
watch -n 10 'healthcheck && echo "HEALTHY"'
```

## Prevention

### Short-term

- **Add retry logic** to critical operations during container startup
- **Increase healthcheck timeout** if legitimate operations take longer than 2 minutes
- **Add resource alerts** to detect disk/memory issues before they cause failures

### Long-term

- **Improve initialization robustness**:

  ```bash
  # In entrypoint.sh, add retry logic
  for i in {1..3}; do
    if initialize_feature; then break; fi
    sleep 5
  done
  ```

- **Add resource quotas** to prevent resource exhaustion
- **Implement graceful degradation** where features fail independently
- **Add pre-healthcheck** that runs before marking container ready
- **Monitor build logs** in CI to catch issues before deployment

### Monitoring Improvements

```yaml
# Add alert for partial healthcheck failures
- alert: ContainerPartialHealthcheckFailure
  expr: healthcheck_failed_checks > 0 and container_healthcheck_status == 1
  for: 5m
```

## Escalation

Escalate if:

- **Issue persists after restart** (more than 2 restart attempts)
- **Multiple containers affected** (indicates systemic issue)
- **Root cause unclear** after 30 minutes of investigation
- **Production impact** affecting end users

Escalate to:

1. **Team Lead** (first escalation)
2. **Platform Team** (if infrastructure related)
3. **On-call Manager** (if production outage)

## Related

- **Related Alerts**:
  - ContainerFlapping (may fire alongside this)
  - ContainerMetricsMissing (may occur if container is down)
- **Related Documentation**:
  - [Healthcheck Documentation](../../healthcheck.md)
  - [Troubleshooting Guide](../../troubleshooting.md)
- **Related Scripts**:
  - `/lib/runtime/healthcheck`
  - `/lib/runtime/entrypoint.sh`

## History

- **First Occurrence**: [Track in incident log]
- **Frequency**: Monitor via Prometheus query: `count_over_time(ALERTS{alertname="ContainerUnhealthy"}[7d])`
- **False Positive Rate**: If high (>20%), adjust healthcheck thresholds

## Post-Incident

After resolution:

1. **Document** root cause in incident report
2. **Update** this runbook with new findings
3. **Implement** preventive measures
4. **Test** similar scenarios in staging
5. **Review** alert thresholds if false positive
