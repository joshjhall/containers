# Observability Runbooks

Operational runbooks for container platform alerts. Each runbook corresponds
to an alert rule defined in
[`examples/observability/prometheus/alerts.yml`](../../../examples/observability/prometheus/alerts.yml).

## Build Alerts

| Alert                    | Severity | Runbook                                      |
| ------------------------ | -------- | -------------------------------------------- |
| ContainerBuildFailed     | warning  | [build-failed.md](build-failed.md)           |
| ContainerBuildSlow       | info     | [build-slow.md](build-slow.md)               |
| ContainerBuildWarnings   | info     | [build-warnings.md](build-warnings.md)       |
| ContainerBuildErrorTrend | warning  | [build-error-trend.md](build-error-trend.md) |

## Runtime Health Alerts

| Alert                    | Severity | Runbook                                          |
| ------------------------ | -------- | ------------------------------------------------ |
| ContainerUnhealthy       | critical | [container-unhealthy.md](container-unhealthy.md) |
| ContainerHealthcheckSlow | warning  | [healthcheck-slow.md](healthcheck-slow.md)       |
| ContainerRestarted       | warning  | [container-restarted.md](container-restarted.md) |
| ContainerFlapping        | critical | [container-flapping.md](container-flapping.md)   |

## Resource Alerts

| Alert                           | Severity | Runbook                                                      |
| ------------------------------- | -------- | ------------------------------------------------------------ |
| ContainerDiskUsageHigh          | warning  | [disk-usage-high.md](disk-usage-high.md)                     |
| ContainerLogsDiskUsageHigh      | warning  | [logs-disk-usage-high.md](logs-disk-usage-high.md)           |
| ContainerWorkspaceDiskUsageHigh | info     | [workspace-disk-usage-high.md](workspace-disk-usage-high.md) |

## Metrics Collection Alerts

| Alert                   | Severity | Runbook                                  |
| ----------------------- | -------- | ---------------------------------------- |
| ContainerMetricsStale   | warning  | [metrics-stale.md](metrics-stale.md)     |
| ContainerMetricsMissing | warning  | [metrics-missing.md](metrics-missing.md) |

## Fleet Alerts

| Alert                          | Severity | Runbook                                                    |
| ------------------------------ | -------- | ---------------------------------------------------------- |
| ContainerFleetUnhealthyRate    | critical | [fleet-unhealthy-rate.md](fleet-unhealthy-rate.md)         |
| ContainerFleetBuildFailureRate | warning  | [fleet-build-failure-rate.md](fleet-build-failure-rate.md) |

## Production Alerts

| Alert                   | Severity | Runbook                                          |
| ----------------------- | -------- | ------------------------------------------------ |
| ContainerOOMKilled      | critical | [container-unhealthy.md](container-unhealthy.md) |
| HighContainerErrorRate  | critical | [container-unhealthy.md](container-unhealthy.md) |
| HighAuthFailureRate     | critical | [container-unhealthy.md](container-unhealthy.md) |
| SecurityPolicyViolation | critical | [container-unhealthy.md](container-unhealthy.md) |
| CertificateExpiringSoon | warning  | [container-unhealthy.md](container-unhealthy.md) |
| HighRequestLatencyP95   | warning  | [healthcheck-slow.md](healthcheck-slow.md)       |

## Severity Levels

### Critical

- **Response Time**: Immediate (within 15 minutes)
- **Notification**: PagerDuty + Slack
- **Examples**: Container unhealthy, container flapping, fleet unhealthy, OOM kills

### Warning

- **Response Time**: Within 1-2 hours
- **Notification**: Slack
- **Examples**: Build failed, healthcheck slow, disk usage high, metrics stale

### Info

- **Response Time**: Within 1 business day
- **Notification**: Email digest
- **Examples**: Build slow, build warnings, workspace disk usage

## Escalation Path

1. **On-Call Engineer**: First responder for all alerts
1. **Team Lead**: Escalate if issue persists after 1 hour
1. **Platform Team**: Escalate for infrastructure issues
1. **Security Team**: Escalate for security-related incidents

## Quick Reference

```bash
# Check container health
healthcheck --verbose

# View build logs
check-build-logs.sh <feature>

# View metrics
curl http://localhost:9090/metrics

# Check disk usage
df -h
du -sh /cache /workspace /var/log/container-build

# View recent errors
tail -100 /var/log/container-build/master-summary.log
```
