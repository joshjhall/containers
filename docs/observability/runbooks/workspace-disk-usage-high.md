# Alert: Container Workspace Disk Usage High

## Overview

- **Alert Name**: ContainerWorkspaceDiskUsageHigh
- **Severity**: Info
- **Component**: resources
- **Threshold**: `container_disk_usage_bytes{path="/workspace"} > 53687091200` (50 GB) for 10 minutes

## Description

The `/workspace` directory is consuming more than 50 GB. This is an
informational alert since workspace size depends heavily on the project,
but unusually large workspaces may indicate accumulated artifacts or
unintended file growth.

## Impact

### User Impact

- **LOW**: Workspace is large but may be expected for the project
- Disk exhaustion could eventually cause failures

### System Impact

- Shared disk volumes may be affected
- Backup and sync operations may be slow

## Diagnosis

### Quick Checks

1. **Check workspace breakdown:**

   ```bash
   du -sh /workspace/*/
   ```

1. **Find largest directories:**

   ```bash
   du -sh /workspace/*/* 2>/dev/null | sort -rh | head -20
   ```

1. **Check for common space consumers:**

   ```bash
   # Node modules
   find /workspace -name node_modules -type d -exec du -sh {} \; 2>/dev/null

   # Build artifacts
   find /workspace -name "*.o" -o -name "*.pyc" -o -name "*.class" | head -20

   # Git objects
   du -sh /workspace/*/.git 2>/dev/null
   ```

### Common Causes

1. **Large git repositories**: Repos with large binary files or deep history
1. **Node modules**: Multiple projects with large dependency trees
1. **Build artifacts**: Compiled binaries, object files, intermediate outputs
1. **Data files**: Large datasets checked into the workspace
1. **Docker contexts**: Build contexts with unfiltered large directories

## Resolution

### Quick Fix

```bash
# Clean common artifacts
find /workspace -name node_modules -type d -exec rm -rf {} + 2>/dev/null
find /workspace -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
find /workspace -name "*.pyc" -delete 2>/dev/null
find /workspace -name target -path "*/target/release" -type d -exec rm -rf {} + 2>/dev/null
```

### Permanent Fix

1. **Add `.gitignore`** rules for build artifacts
1. **Use `.dockerignore`** to exclude large files from build contexts
1. **Configure git LFS** for large binary files
1. **Set up periodic cleanup** of build artifacts
1. **Increase disk allocation** if workspace legitimately needs the space

### Verification

```bash
du -sh /workspace/
# Verify size is reasonable for the project
```

## Escalation

- **First responder**: Developer using the workspace
- **Escalation**: Platform team if shared storage is affected

## Related

- **Related Alerts**: [disk-usage-high.md](disk-usage-high.md), [logs-disk-usage-high.md](logs-disk-usage-high.md)
