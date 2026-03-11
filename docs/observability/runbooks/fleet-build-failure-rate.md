# Alert: Container Fleet Build Failure Rate

## Overview

- **Alert Name**: ContainerFleetBuildFailureRate
- **Severity**: Warning
- **Component**: fleet
- **Threshold**: More than 50% of containers have build errors for 10 minutes

## Description

A majority of containers in the fleet have build errors. This indicates a
systemic problem with the build process, shared dependencies, or base images
rather than an isolated failure.

## Impact

### User Impact

- **HIGH**: Many containers are missing features or have broken installations
- Developers across the organization may be affected

### System Impact

- CI/CD pipelines may be blocked fleet-wide
- Container image registry may contain many broken images
- Automated builds are failing at scale

## Diagnosis

### Quick Checks

1. **Check the failure ratio:**

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=sum(container_build_errors_total>0)/count(container_build_errors_total)' | jq .
   ```

1. **Identify common failing features:**

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=container_build_errors_total>0' | jq '.data.result[] | .metric.feature'
   ```

1. **Check for recent changes:**

   ```bash
   git log --oneline --since="2 hours ago" -- lib/ Dockerfile
   ```

### Common Causes

1. **Upstream dependency failure**: Package registry outage (PyPI, npm, crates.io)
1. **Base image update**: Broken or incompatible base image change
1. **Auto-patch regression**: Weekly auto-update introduced a breaking change
1. **Network infrastructure**: DNS or proxy issues affecting downloads
1. **Shared feature script bug**: Common feature script has a regression
1. **Version resolution failure**: A pinned version was yanked or removed

## Resolution

### Quick Fix

```bash
# Check external dependency status
curl -s https://status.npmjs.org/ | head -5
curl -s https://status.python.org/ | head -5

# If auto-patch, check the branch
git log --oneline auto-patch/ | head -5

# Pin to known-good base image
docker build --build-arg BASE_IMAGE=debian:bookworm-20240101 ...
```

### Permanent Fix

1. **If upstream outage**: Wait for resolution, add package mirrors
1. **If base image regression**: Pin base image to specific digest
1. **If auto-patch**: Revert the auto-patch branch, fix the update script
1. **If feature script bug**: Fix and test with `./tests/run_integration_tests.sh`

### Verification

```bash
# Rebuild a test container
./tests/run_integration_tests.sh

# Check fleet failure rate is declining
curl -s 'http://localhost:9090/api/v1/query?query=sum(container_build_errors_total>0)/count(container_build_errors_total)' | jq .
# Should be below 0.5
```

## Escalation

- **First responder**: Platform engineering team
- **Escalation**: Release engineering if auto-patch related
- **External**: Check upstream package registry status pages

## Related

- **Related Alerts**: [build-failed.md](build-failed.md), [build-error-trend.md](build-error-trend.md)
- **Related Runbooks**: [fleet-unhealthy-rate.md](fleet-unhealthy-rate.md)
