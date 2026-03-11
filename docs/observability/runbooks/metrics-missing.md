# Alert: Container Metrics Missing

## Overview

- **Alert Name**: ContainerMetricsMissing
- **Severity**: Warning
- **Component**: metrics
- **Threshold**: `absent(container_uptime_seconds) == 1` for 5 minutes

## Description

No metrics are being received from the container at all. This is more severe
than stale metrics — it means the metric time series does not exist in
Prometheus, indicating the container was never scraped or has been down for
long enough that the time series expired.

## Impact

### User Impact

- **MEDIUM**: Complete monitoring blind spot for the container

### System Impact

- All alerts for this container are ineffective
- SLO calculations are skewed
- Dashboards show no data

## Diagnosis

### Quick Checks

1. **Check if the container is running:**

   ```bash
   docker ps | grep <container>
   ```

1. **Check Prometheus target status:**

   ```bash
   curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="containers")'
   ```

1. **Check if metrics endpoint exists:**

   ```bash
   curl -sv http://<container>:9090/metrics 2>&1 | head -20
   ```

### Common Causes

1. **Container is down**: Container not running or not reachable
1. **Metrics exporter not installed**: `METRICS_ENABLED` not set to true
1. **Wrong scrape target**: Prometheus configured with wrong host/port
1. **Firewall/network**: Container network not accessible from Prometheus
1. **Service discovery failure**: Docker/Kubernetes SD not finding the container

## Resolution

### Quick Fix

```bash
# Start the container if it's not running
docker start <container>

# Verify metrics are enabled
docker exec <container> env | grep METRICS

# Check Prometheus config
cat /etc/prometheus/prometheus.yml | grep -A5 containers
```

### Permanent Fix

1. **Ensure `METRICS_ENABLED=true`** in container environment
1. **Verify Prometheus scrape config** has the correct target
1. **Check network connectivity** between Prometheus and the container
1. **Add container to service discovery** if using Docker/Kubernetes SD

### Verification

```bash
# Wait for next scrape interval, then check
curl -s 'http://localhost:9090/api/v1/query?query=container_uptime_seconds' | jq .
# Should return a non-empty result
```

## Escalation

- **First responder**: Platform engineering team
- **Escalation**: Infrastructure team if networking issue

## Related

- **Related Alerts**: [metrics-stale.md](metrics-stale.md)
