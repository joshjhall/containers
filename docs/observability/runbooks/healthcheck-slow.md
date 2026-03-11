# ContainerHealthcheckSlow

## Alert Details

- **Severity:** warning
- **Component:** runtime
- **Threshold:** `container_healthcheck_duration_seconds > 5` for 5 minutes
- **SLO Impact:** Counts against the 99% healthcheck latency SLO

## Symptoms

- Healthcheck taking longer than 5 seconds to complete
- Container may be under heavy load
- Potential precursor to a full unhealthy state

## Diagnosis

1. **Check current healthcheck duration:**

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=container_healthcheck_duration_seconds' | jq .
   ```

1. **Check container resource usage:**

   ```bash
   docker stats --no-stream <container>
   ```

1. **Check for high I/O or CPU contention:**

   ```bash
   docker exec <container> top -bn1 | head -20
   docker exec <container> iostat -x 1 3
   ```

1. **Check what the healthcheck does:**

   ```bash
   docker inspect --format='{{json .Config.Healthcheck}}' <container> | jq .
   ```

## Resolution

### Immediate

- Identify and terminate any runaway processes in the container
- Check if a large build or compilation is consuming resources

### Short-term

- Increase container resource limits if consistently near capacity
- Optimize healthcheck script to reduce overhead
- Check for lock contention or disk I/O bottlenecks

### Long-term

- Add resource requests/limits to container configurations
- Implement lightweight healthcheck endpoints
- Monitor resource usage trends to right-size containers

## Escalation

- **First responder:** Platform engineering team
- **Escalation:** Infrastructure team if host resources are constrained
