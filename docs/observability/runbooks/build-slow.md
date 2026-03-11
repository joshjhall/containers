# ContainerBuildSlow

## Alert Details

- **Severity:** info
- **Component:** build
- **Threshold:** `container_build_duration_seconds > 600` (10 minutes) for 1 minute

## Symptoms

- Container builds take longer than expected
- CI/CD pipelines show increased build times
- Developer feedback loops are slower

## Diagnosis

1. **Identify which feature is slow:**

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=container_build_duration_seconds>600' | jq .
   check-build-logs.sh
   ```

1. **Check if cache is being used:**

   ```bash
   # Verify cache volume is mounted
   docker inspect <container> | jq '.[0].Mounts[] | select(.Destination=="/cache")'

   # Check cache directory sizes
   du -sh /cache/*/
   ```

1. **Check network throughput:**

   ```bash
   # Test download speed from within build environment
   curl -o /dev/null -w "%{speed_download}" https://pypi.org/simple/
   ```

1. **Look for resource contention:**

   ```bash
   # Check host system resources during build
   docker stats --no-stream
   ```

## Resolution

### Immediate

- Ensure Docker BuildKit cache mounts are configured
- Verify the `/cache` volume is mounted and persistent across builds
- Check network connectivity and DNS resolution speed

### Short-term

- Review the slow feature script for optimization opportunities
- Enable BuildKit parallel stage execution
- Pre-warm caches with common dependencies

### Long-term

- Set up a local package mirror for frequently used packages
- Split large feature installs into cacheable layers
- Consider multi-stage builds to parallelize independent features

## Escalation

- **First responder:** Platform engineering team
- **Escalation:** Infrastructure team if resource or network related
