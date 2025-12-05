# Alert Runbooks

Operational runbooks for responding to container observability alerts.

## Purpose

Runbooks provide step-by-step guidance for diagnosing and resolving alerts. Each
runbook follows a consistent structure to ensure quick and effective incident
response.

## Runbook Structure

Each runbook includes:

1. **Alert Information**: Name, severity, description
1. **Impact**: What this alert means for users/systems
1. **Diagnosis**: Steps to investigate the root cause
1. **Resolution**: How to fix the issue
1. **Prevention**: How to prevent recurrence
1. **Escalation**: When and how to escalate

## Available Runbooks

### Critical Alerts (Immediate Action Required)

- [container-unhealthy.md](./container-unhealthy.md) - Container healthcheck
  failing
- [container-flapping.md](./container-flapping.md) - Container restarting
  frequently

### Warning Alerts (Action Needed Soon)

- [build-failed.md](./build-failed.md) - Container build has errors
- [healthcheck-slow.md](./healthcheck-slow.md) - Healthchecks taking too long
- [disk-usage-high.md](./disk-usage-high.md) - Disk space running low
- [metrics-stale.md](./metrics-stale.md) - Metrics not being updated

### Info Alerts (Informational)

- [build-slow.md](./build-slow.md) - Build process is slower than expected
- [build-warnings.md](./build-warnings.md) - Build has many warnings

## Quick Reference

### Common Commands

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

### Common Fixes

**Container unhealthy**:

```bash
# Restart container
docker restart <container-id>

# Check logs for errors
docker logs <container-id> --tail 100
```

**Build failures**:

```bash
# Review build logs
check-build-logs.sh <feature>

# Rebuild with verbose logging
docker build --progress=plain ...
```

**Disk space issues**:

```bash
# Clean cache directories
rm -rf /cache/pip/* /cache/npm/* /cache/cargo/*

# Clean old logs
find /var/log/container-build -type f -mtime +7 -delete
```

## Severity Levels

### Critical

- **Response Time**: Immediate (within 15 minutes)
- **Impact**: Service degradation or outage
- **Notification**: PagerDuty, phone call
- **Examples**: Container unhealthy, container flapping

### Warning

- **Response Time**: Within 1-2 hours
- **Impact**: Degraded performance, potential future issues
- **Notification**: Slack, email
- **Examples**: Build failed, healthcheck slow, disk usage high

### Info

- **Response Time**: Within 1 business day
- **Impact**: Minor issues, optimization opportunities
- **Notification**: Email, ticketing system
- **Examples**: Build slow, build warnings

## Escalation Path

1. **On-Call Engineer**: First responder for all alerts
1. **Team Lead**: Escalate if issue persists after 1 hour
1. **Platform Team**: Escalate for infrastructure issues
1. **Security Team**: Escalate for security-related incidents

## On-Call Procedures

### When You Receive an Alert

1. **Acknowledge** the alert in PagerDuty/monitoring system
1. **Assess** severity and impact
1. **Investigate** using the appropriate runbook
1. **Communicate** status to team (Slack, incident channel)
1. **Resolve** the issue following runbook guidance
1. **Document** actions taken and resolution
1. **Post-mortem** if critical incident (within 24 hours)

### If You Can't Resolve

- **Escalate** to team lead
- **Continue investigation** while waiting
- **Keep stakeholders updated** every 30 minutes
- **Document** everything tried

## Contributing

### Adding a New Runbook

1. Copy the template below
1. Fill in all sections
1. Add link to this README
1. Update alert definition to include runbook URL

### Runbook Template

````text
# Alert: [Alert Name]

## Overview

- **Alert Name**: AlertName
- **Severity**: Critical/Warning/Info
- **Component**: build/runtime/resources/metrics

## Description

[Brief description of what this alert means]

## Impact

### User Impact

[How this affects end users]

### System Impact

[How this affects the system]

## Diagnosis

### Quick Checks

1. [First thing to check]
2. [Second thing to check]
3. [Third thing to check]

### Detailed Investigation

```bash
# Commands to run
````

### Common Causes

- Cause 1
- Cause 2
- Cause 3

## Resolution

### Quick Fix

```bash
# Immediate mitigation steps
```

### Permanent Fix

1. Step 1
1. Step 2
1. Step 3

### Verification

```bash
# How to verify the fix worked
```

## Prevention

- How to prevent this in the future
- Monitoring improvements
- Process changes

## Escalation

Escalate if:

- Issue persists after [timeframe]
- Impact is greater than expected
- Root cause is unclear

Escalate to: [Team/Person]

## Related

- Related alerts: [Links]
- Related documentation: [Links]
- Related incidents: [Links]

## History

- First occurrence: [Date]
- Frequency: [How often this fires]
- False positive rate: [Percentage]

## Metrics

Track runbook effectiveness:

- **Time to Acknowledge**: How quickly alerts are acknowledged
- **Time to Resolve**: How long it takes to resolve incidents
- **Runbook Usage**: Which runbooks are used most
- **False Positives**: Alerts that don't require action

Review quarterly to improve runbooks and alert thresholds.
