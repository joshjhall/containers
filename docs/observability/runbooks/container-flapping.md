# Alert: Container Flapping

## Overview

- **Alert Name**: ContainerFlapping
- **Severity**: Critical
- **Component**: runtime
- **Threshold**: `changes(container_uptime_seconds[30m]) > 3` for 5 minutes

## Description

The container is restarting frequently (more than 3 times in 30 minutes),
indicating a severe stability issue. This is often caused by crash loops,
OOM kills, or configuration errors that prevent the container from staying
healthy.

## Impact

### User Impact

- **HIGH**: Container is effectively unavailable due to constant restarts
- Work in progress is lost on each restart
- Development environment is unusable

### System Impact

- Container orchestrator is spending resources on constant restarts
- Metrics may be incomplete due to gaps between restarts
- Log volume increases significantly from repeated startup sequences
- Dependent services may cascade fail

## Diagnosis

### Quick Checks

1. **Check restart count and reason:**

   ```bash
   docker inspect --format='{{json .RestartCount}}' <container>
   docker inspect --format='{{json .State}}' <container> | jq .
   ```

1. **Check for OOM kills:**

   ```bash
   docker inspect --format='{{.State.OOMKilled}}' <container>
   dmesg | grep -i "oom\|killed"
   ```

1. **Review container logs across restarts:**

   ```bash
   docker logs --tail 500 <container> 2>&1 | grep -i "error\|fatal\|panic\|kill"
   ```

### Detailed Investigation

#### Check Docker events timeline

```bash
docker events --since 1h --filter container=<container> \
  --filter event=start --filter event=die --filter event=kill --filter event=oom
```

#### Check exit codes

```bash
docker inspect --format='{{.State.ExitCode}}' <container>
# Exit codes: 0=normal, 1=error, 137=SIGKILL/OOM, 139=SIGSEGV, 143=SIGTERM
```

#### Check resource limits

```bash
docker inspect --format='{{json .HostConfig.Memory}}' <container>
docker stats --no-stream <container>
```

### Common Causes

1. **OOM Kill Loop**: Container exceeds memory limit, gets killed, restarts, repeats
1. **Configuration Error**: Bad environment variable or missing volume mount
1. **Dependency Failure**: Required service (database, API) is unreachable
1. **Entrypoint Crash**: Bug in entrypoint script causes immediate exit
1. **Health Check Failure**: Orchestrator kills container due to failed health checks
1. **Resource Starvation**: Host system under heavy load

## Resolution

### Quick Fix

```bash
# Stop the restart loop temporarily
docker update --restart=no <container>

# Investigate without restarts
docker logs <container>

# If OOM, increase memory limit
docker update --memory=4g --memory-swap=8g <container>
```

### Permanent Fix

1. **If OOM kills**: Increase memory limits or optimize application memory usage
1. **If entrypoint crash**: Fix the entrypoint script, test with `docker run --entrypoint bash`
1. **If dependency failure**: Add dependency health checks, retry logic, or circuit breakers
1. **If configuration error**: Verify all environment variables and volume mounts

### Verification

```bash
# Monitor container stability for 10 minutes
watch -n 30 'docker inspect --format="{{.State.Status}} uptime={{.State.StartedAt}}" <container>'

# Check metrics show stable uptime
curl -s 'http://localhost:9090/api/v1/query?query=container_uptime_seconds' | jq .
```

## Escalation

Escalate if:

- **Root cause is unclear** after 30 minutes
- **Multiple containers** are flapping simultaneously
- **Infrastructure issue** suspected (host resources, networking)

Escalate to:

1. **Team Lead** (first escalation)
1. **Platform Team** (if infrastructure related)
1. **On-call Manager** (if production impact)

## Related

- **Related Alerts**: ContainerUnhealthy, ContainerRestarted
- **Related Runbooks**: [container-unhealthy.md](container-unhealthy.md), [container-restarted.md](container-restarted.md)
