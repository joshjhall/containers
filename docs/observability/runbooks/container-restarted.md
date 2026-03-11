# ContainerRestarted

## Alert Details

- **Severity:** warning
- **Component:** runtime
- **Threshold:** `container_uptime_seconds < 300` (up for less than 5 minutes)

## Symptoms

- Container recently restarted
- Possible loss of in-memory state
- Brief service interruption during restart

## Diagnosis

1. **Check why the container restarted:**

   ```bash
   docker inspect --format='{{json .State}}' <container> | jq .
   docker events --since 30m --filter container=<container>
   ```

1. **Check for OOM kills:**

   ```bash
   docker inspect --format='{{.State.OOMKilled}}' <container>
   # Check system logs for OOM events
   dmesg | grep -i "oom\|killed"
   ```

1. **Review container logs from before the restart:**

   ```bash
   docker logs --tail 200 <container>
   ```

1. **Check Docker daemon events:**

   ```bash
   docker events --since 1h --filter event=die --filter event=kill
   ```

## Resolution

### Immediate

- If OOM-killed, increase memory limits
- If crash, review logs for the root cause error
- Verify the container is healthy after restart

### Short-term

- Add proper signal handling if the container isn't shutting down cleanly
- Review entrypoint script for initialization race conditions
- Check for resource leaks that build up over time

### Long-term

- Implement graceful shutdown handlers
- Add pre-stop hooks for cleanup
- Set up persistent state for crash recovery
- Ensure tini is configured as PID 1 for proper signal handling

## Escalation

- **First responder:** Platform engineering team
- **Escalation:** Application team if crash is in application code
