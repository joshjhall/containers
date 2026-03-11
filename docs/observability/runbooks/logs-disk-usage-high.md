# Alert: Container Logs Disk Usage High

## Overview

- **Alert Name**: ContainerLogsDiskUsageHigh
- **Severity**: Warning
- **Component**: resources
- **Threshold**: `container_disk_usage_bytes{path=~"/var/log/.*"} > 1073741824` (1 GB) for 10 minutes

## Description

Log directories are consuming more than 1 GB of disk space. Logs should be
rotated or archived to prevent disk exhaustion.

## Impact

### User Impact

- **LOW-MEDIUM**: No immediate impact, but disk exhaustion will cause failures

### System Impact

- Disk may fill up, causing container unhealthiness
- Log writes may fail, losing diagnostic information
- Other processes competing for disk space may be affected

## Diagnosis

### Quick Checks

1. **Identify large log files:**

   ```bash
   find /var/log -type f -size +100M -exec ls -lh {} \;
   ```

1. **Check build log sizes:**

   ```bash
   du -sh /var/log/container-build/
   ls -lhS /var/log/container-build/
   ```

1. **Check system logs:**

   ```bash
   du -sh /var/log/syslog /var/log/auth.log /var/log/dpkg.log 2>/dev/null
   ```

### Common Causes

1. **Build logs accumulating**: Multiple builds without cleanup
1. **Verbose logging enabled**: Debug-level logging producing excessive output
1. **Log rotation not configured**: No logrotate or similar mechanism
1. **Application logs**: Application writing large amounts to log files

## Resolution

### Quick Fix

```bash
# Clean old build logs (keep last 7 days)
find /var/log/container-build -type f -mtime +7 -delete

# Truncate large log files (keeps file handle valid)
truncate -s 0 /var/log/container-build/master-summary.log

# Clean rotated logs
find /var/log -name "*.gz" -delete
find /var/log -name "*.old" -delete
```

### Permanent Fix

1. **Enable log rotation** for build logs and application logs

1. **Set maximum log file sizes** in logging configuration

1. **Forward logs** to external aggregation (Loki, ELK) instead of storing locally

1. **Configure Docker log drivers** with max-size limits:

   ```yaml
   logging:
     driver: json-file
     options:
       max-size: "50m"
       max-file: "3"
   ```

### Verification

```bash
du -sh /var/log/
# Should be below 1 GB

curl -s 'http://localhost:9090/api/v1/query?query=container_disk_usage_bytes{path=~"/var/log/.*"}' | jq .
```

## Escalation

- **First responder**: Platform engineering team
- **Escalation**: Generally not required for log cleanup

## Related

- **Related Alerts**: [disk-usage-high.md](disk-usage-high.md), [workspace-disk-usage-high.md](workspace-disk-usage-high.md)
