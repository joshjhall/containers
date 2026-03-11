# Alert: Container Disk Usage High

## Overview

- **Alert Name**: ContainerDiskUsageHigh
- **Severity**: Warning
- **Component**: resources
- **Threshold**: `container_disk_usage_bytes{path="/cache"} > 10737418240` (10 GB) for 10 minutes

## Description

The `/cache` directory is consuming more than 10 GB of disk space. This
directory stores package manager caches (pip, npm, cargo, go, bundle, etc.)
and can grow significantly over time.

## Impact

### User Impact

- **MEDIUM**: Builds may slow down or fail if disk fills completely
- Package installations may fail with "no space left on device"

### System Impact

- Container may become unhealthy if disk is full
- Other containers sharing the volume may be affected
- Build cache effectiveness may degrade

## Diagnosis

### Quick Checks

1. **Check cache directory sizes:**

   ```bash
   du -sh /cache/*/
   ```

1. **Check overall disk usage:**

   ```bash
   df -h
   ```

1. **Identify largest consumers:**

   ```bash
   du -sh /cache/* | sort -rh | head -20
   ```

### Common Causes

1. **Accumulated package caches**: pip, npm, cargo caches grow over time
1. **Multiple Python/Node versions**: Each version maintains its own cache
1. **Large compiled dependencies**: Rust/Go binaries in cache
1. **Stale cache entries**: Old versions of packages never cleaned up

## Resolution

### Quick Fix

```bash
# Clean specific caches
rm -rf /cache/pip/*
rm -rf /cache/npm/*
rm -rf /cache/cargo/registry/cache/*
rm -rf /cache/go/pkg/mod/cache/*

# Or clean all caches
find /cache -mindepth 2 -type f -atime +30 -delete
```

### Permanent Fix

1. **Set up periodic cache cleanup** via cron (enabled with `INCLUDE_CRON=true`)
1. **Configure cache size limits** in package manager configs
1. **Use separate volumes** for different cache types to isolate growth
1. **Increase volume size** if the workload legitimately needs large caches

### Verification

```bash
du -sh /cache/
# Should be below 10 GB

curl -s 'http://localhost:9090/api/v1/query?query=container_disk_usage_bytes{path="/cache"}' | jq .
```

## Escalation

- **First responder**: Platform engineering team
- **Escalation**: Infrastructure team if shared storage is affected

## Related

- **Related Alerts**: [logs-disk-usage-high.md](logs-disk-usage-high.md), [workspace-disk-usage-high.md](workspace-disk-usage-high.md)
