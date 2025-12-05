# Permission Issues

Debug and resolve file permission errors in containers.

## Symptoms

- "Permission denied" errors
- Cannot write to mounted volumes
- Package manager fails to install
- Build scripts fail to execute

## Quick Checks

```bash
# Check current user
docker run --rm <image> id

# Check directory permissions
docker run --rm <image> ls -la /workspace /cache /home/vscode

# Check volume ownership
docker run --rm -v <volume>:/mnt debian:trixie-slim ls -la /mnt
```

## Common Causes

### 1. UID/GID Mismatch

**Symptom**: Cannot write to mounted volume

**Check**:

```bash
# Host UID
id -u

# Container UID
docker run --rm <image> id -u

# File owner on host
ls -ln /path/to/mounted/dir
```

**Fix**: Match container user to host user UID

### 2. Root-Owned Files in Non-Root Container

**Symptom**: "Permission denied" for files created by root

**Check**:

```bash
docker run --rm -v <volume>:/data <image> ls -la /data
```

**Fix**:

```bash
# Fix ownership
docker run --rm -v <volume>:/data <image> \
  sudo chown -R vscode:vscode /data
```

### 3. Read-Only Volume Mount

**Symptom**: "Read-only file system"

**Check**:

```bash
docker inspect <container_id> --format='{{json .Mounts}}'
```

**Fix**: Mount as read-write (default) or use a different path

### 4. SELinux/AppArmor Blocking

**Symptom**: Permission denied despite correct ownership

**Check**:

```bash
# Check SELinux context (RHEL/Fedora)
ls -laZ /path/to/dir

# Check AppArmor (Ubuntu/Debian)
aa-status
```

**Fix**:

```bash
# SELinux: Add :z or :Z to mount
docker run -v /host/path:/container/path:z <image>

# AppArmor: Run with specific profile
docker run --security-opt apparmor=unconfined <image>
```

### 5. Case-Sensitive Filesystem Mismatch

**Symptom**: Files not found or wrong file accessed

**Check**: See
[case-sensitive-filesystems.md](../../troubleshooting/case-sensitive-filesystems.md)

## Diagnostic Steps

### Step 1: Identify the User

```bash
# Check which user the container runs as
docker run --rm <image> id

# Expected for this container system:
# uid=1000(vscode) gid=1000(vscode) groups=1000(vscode)
```

### Step 2: Check File Ownership

```bash
# In container
docker run --rm <image> ls -la /workspace

# Check specific file
docker run --rm <image> stat /path/to/file

# On host for mounted volume
ls -la /host/path/to/volume
```

### Step 3: Check Mount Configuration

```bash
# Inspect mounts
docker inspect <container_id> --format='
{{range .Mounts}}
Type: {{.Type}}
Source: {{.Source}}
Dest: {{.Destination}}
Mode: {{.Mode}}
RW: {{.RW}}
{{end}}'
```

### Step 4: Test Write Access

```bash
# Test writing to directories
docker run --rm <image> /bin/bash -c "
  echo 'Testing /workspace...' && touch /workspace/test && rm /workspace/test && echo 'OK'
  echo 'Testing /cache...' && touch /cache/test && rm /cache/test && echo 'OK'
  echo 'Testing /home/vscode...' && touch /home/vscode/test && rm /home/vscode/test && echo 'OK'
"
```

### Step 5: Check Sudo Access

```bash
# Test sudo
docker run --rm <image> sudo whoami

# If passwordless sudo is disabled, this will prompt for password
```

## Resolution

### Fix Volume Ownership

```bash
# Option 1: Fix from within container
docker run --rm -v <volume>:/data <image> \
  sudo chown -R vscode:vscode /data

# Option 2: Fix from host
sudo chown -R 1000:1000 /host/path

# Option 3: Use named volume with correct ownership
docker volume create --driver local myvolume
docker run --rm -v myvolume:/data debian:trixie-slim \
  chown -R 1000:1000 /data
```

### Match Container UID to Host

```bash
# Build with custom UID
docker build \
  --build-arg USER_UID=$(id -u) \
  --build-arg USER_GID=$(id -g) \
  -f containers/Dockerfile .

# Or in docker-compose.yml
services:
  app:
    build:
      args:
        USER_UID: ${UID:-1000}
        USER_GID: ${GID:-1000}
```

### Run as Different User

```bash
# Run as root (for debugging)
docker run --user root <image>

# Run as specific UID
docker run --user 1000:1000 <image>

# Run with current host user
docker run --user $(id -u):$(id -g) <image>
```

### Fix Docker-Compose Permissions

```yaml
services:
  app:
    image: ghcr.io/joshjhall/containers:python-dev
    user: '${UID:-1000}:${GID:-1000}'
    volumes:
      - .:/workspace/project
      - cache:/cache

volumes:
  cache:
    driver: local
```

With init container to fix permissions:

```yaml
services:
  init:
    image: debian:trixie-slim
    volumes:
      - cache:/cache
    command: chown -R 1000:1000 /cache

  app:
    depends_on:
      init:
        condition: service_completed_successfully
```

### Configure SELinux

```bash
# Temporary fix with :z label
docker run -v /host:/container:z <image>

# Permanent fix: set SELinux context
chcon -Rt svirt_sandbox_file_t /host/path
```

### Kubernetes Permissions

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: app
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
```

For PersistentVolumes:

```yaml
spec:
  securityContext:
    fsGroup: 1000 # All mounted volumes owned by this group
```

## Permission Reference

### Container User

- **Username**: vscode (configurable via `USERNAME` build arg)
- **UID**: 1000 (configurable via `USER_UID` build arg)
- **GID**: 1000 (configurable via `USER_GID` build arg)

### Directory Permissions

| Directory      | Owner  | Mode | Purpose          |
| -------------- | ------ | ---- | ---------------- |
| /workspace     | vscode | 755  | Project files    |
| /cache         | vscode | 755  | Package caches   |
| /home/vscode   | vscode | 755  | User home        |
| /etc/container | root   | 755  | Container config |
| /tmp           | root   | 1777 | Temp files       |

### Sudo Access

- **Production** (`ENABLE_PASSWORDLESS_SUDO=false`): Sudo requires password
- **Development** (`ENABLE_PASSWORDLESS_SUDO=true`): Passwordless sudo

## Prevention

1. **Use consistent UIDs** across development team
1. **Document volume permissions** in project setup
1. **Use init containers** to set ownership in Kubernetes
1. **Test permissions** as part of CI/CD
1. **Avoid running as root** in production

## Escalation

If permission issues persist:

1. Document the exact error message
1. Include output of `id` command in container
1. Show `ls -la` of affected directories
1. Note the host OS and Docker version
1. Open GitHub issue with `bug` label
