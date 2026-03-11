# Alert: Container Fleet Unhealthy Rate

## Overview

- **Alert Name**: ContainerFleetUnhealthyRate
- **Severity**: Critical
- **Component**: fleet
- **Threshold**: More than 30% of containers are unhealthy for 5 minutes

## Description

A significant portion of the container fleet is failing health checks. This
indicates a systemic issue rather than an isolated container problem.

## Impact

### User Impact

- **CRITICAL**: Multiple developers or services affected simultaneously
- Widespread inability to use development containers

### System Impact

- Infrastructure may be under stress
- Orchestrator may be thrashing trying to restart containers
- Cascading failures across dependent services

## Diagnosis

### Quick Checks

1. **Check which containers are unhealthy:**

   ```bash
   docker ps --filter health=unhealthy
   ```

1. **Check the ratio in Prometheus:**

   ```bash
   curl -s 'http://localhost:9090/api/v1/query?query=sum(container_healthcheck_status==0)/count(container_healthcheck_status)' | jq .
   ```

1. **Check for common patterns across unhealthy containers:**

   ```bash
   # Are they all on the same host?
   # Were they all started recently?
   # Do they share a common base image version?
   docker ps --filter health=unhealthy --format '{{.Image}} {{.CreatedAt}}'
   ```

### Common Causes

1. **Shared dependency failure**: Database, network, or DNS outage
1. **Base image regression**: Bad base image update affecting all containers
1. **Host resource exhaustion**: Host out of memory, CPU, or disk
1. **Network partition**: Containers cannot reach required services
1. **Shared volume failure**: Mounted volume becomes unavailable
1. **Infrastructure change**: Recent deployment, config change, or maintenance

## Resolution

### Quick Fix

```bash
# Check host resources first
docker stats --no-stream
df -h
free -h

# If resource exhaustion, identify the top consumers
docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemPerc}}' | sort -k3 -rn
```

### Permanent Fix

1. **If shared dependency**: Fix the dependency, add circuit breakers
1. **If base image issue**: Roll back to the previous known-good image
1. **If host resources**: Scale the infrastructure or redistribute containers
1. **If network**: Work with infrastructure team to resolve network issues

### Verification

```bash
# Monitor recovery
watch -n 15 'docker ps --filter health=unhealthy --format "{{.Names}}" | wc -l'

# Check fleet health ratio in Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=sum(container_healthcheck_status==0)/count(container_healthcheck_status)' | jq .
# Should be below 0.3
```

## Escalation

- **First responder**: Platform engineering on-call
- **Escalation**: Infrastructure team immediately (systemic issue)
- **Page**: Yes - this is a critical fleet-wide alert

## Related

- **Related Alerts**: [container-unhealthy.md](container-unhealthy.md), [container-flapping.md](container-flapping.md)
- **Related Runbooks**: [fleet-build-failure-rate.md](fleet-build-failure-rate.md)
