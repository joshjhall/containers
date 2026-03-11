# Alert: Container Metrics Stale

## Overview

- **Alert Name**: ContainerMetricsStale
- **Severity**: Warning
- **Component**: metrics
- **Threshold**: `time() - container_metrics_scrape_timestamp_seconds > 120` for 5 minutes

## Description

Metrics for a container have not been updated in over 2 minutes. The metrics
exporter may have stopped, or Prometheus scraping may be failing.

## Impact

### User Impact

- **LOW**: No direct user impact, but monitoring blind spot means issues won't be detected

### System Impact

- Alerting is compromised (alerts based on stale data may not fire)
- Dashboards show outdated information
- SLO tracking is inaccurate during the gap

## Diagnosis

### Quick Checks

1. **Check if the metrics endpoint is responding:**

   ```bash
   curl -s http://<container>:9090/metrics | head -5
   ```

1. **Check Prometheus targets:**

   ```bash
   curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {instance: .labels.instance, health: .health, lastScrape: .lastScrape}'
   ```

1. **Check if the metrics exporter process is running:**

   ```bash
   docker exec <container> ps aux | grep metrics
   ```

### Common Causes

1. **Metrics exporter crashed**: Process died or is hung
1. **Network connectivity**: Prometheus cannot reach the container
1. **Port conflict**: Another process took the metrics port
1. **Container restarting**: Metrics unavailable during restart window
1. **Prometheus misconfiguration**: Scrape target removed or incorrect

## Resolution

### Quick Fix

```bash
# Restart the metrics exporter inside the container
docker exec <container> bash -c "kill -HUP \$(pgrep -f metrics-exporter)"

# Or restart the container
docker restart <container>
```

### Permanent Fix

1. **Add process supervision** to restart the metrics exporter if it crashes
1. **Check Prometheus scrape configuration** in `prometheus.yml`
1. **Verify network policies** allow Prometheus to reach the container
1. **Add a liveness probe** for the metrics exporter process

### Verification

```bash
# Verify metrics are flowing
curl -s http://<container>:9090/metrics | grep container_uptime_seconds

# Check Prometheus target health
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health=="up")'
```

## Escalation

- **First responder**: Platform engineering team
- **Escalation**: Infrastructure team if network related

## Related

- **Related Alerts**: [metrics-missing.md](metrics-missing.md)
