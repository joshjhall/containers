# Runtime Issues

This section covers issues that occur when running containers, including PATH
problems, volume mounts, and permission errors.

## Container starts but commands not found

**Symptom**: Tools are installed but not in PATH.

**Solution**:

```bash
# Inside container, check PATH
echo $PATH

# Source the profile
source ~/.bashrc

# Check if tools are installed
ls -la /usr/local/bin
```

## UID/GID conflicts with host

**Symptom**: Permission denied when accessing mounted volumes.

**Solution**:

```bash
# Build with matching UID/GID
docker build \
  --build-arg USER_UID=$(id -u) \
  --build-arg USER_GID=$(id -g) \
  -t myproject:dev .

# Or change ownership inside container
docker exec -u root mycontainer chown -R vscode:vscode /workspace
```

## Cache directories not persisting

**Symptom**: Package installations are slow, cache not working.

**Solution**:

```bash
# Create named volume for cache
docker volume create myproject-cache

# Mount it when running
docker run -v myproject-cache:/cache myproject:dev

# Or use Docker Compose
volumes:
  myproject-cache:
```

## Python/Node/Ruby not found after installation

**Symptom**: Language runtime installed but not available.

**Solution**:

```bash
# Check installation logs
docker history myproject:dev | grep INCLUDE_

# Verify build args were passed correctly
docker inspect myproject:dev | grep INCLUDE_

# Rebuild with correct build args
docker build --build-arg INCLUDE_PYTHON_DEV=true .
```

## Permission Issues

### macOS VirtioFS permission issues (execute bits dropping)

**Symptom**: File permissions don't stick on bind-mounted volumes. `chmod 755`
on a file results in `644` or similar. Scripts lose their execute bit. Ownership
appears incorrect.

**Cause**: macOS APFS lacks full Linux permission semantics. The VirtioFS
translation layer cannot faithfully represent Linux permissions on an APFS
volume.

**Solution**: The container includes **bindfs** (auto-installed with
`INCLUDE_DEV_TOOLS=true`) which creates a FUSE overlay that forces correct
permissions.

1. Add capabilities to your `docker-compose.yml`:

   ```yaml
   services:
     devcontainer:
       cap_add:
         - SYS_ADMIN
       devices:
         - /dev/fuse
   ```

1. The entrypoint auto-detects broken permissions and applies the overlay. Check
   startup logs for:

   ```text
   🔧 Checking bind mounts for permission fixes (bindfs=auto)...
      ✓ Applied bindfs overlay on /workspace/myproject
   ```

1. To force bindfs on (bypassing auto-detection):

   ```bash
   docker run -e BINDFS_ENABLED=true ...
   ```

1. To exclude specific paths:

   ```bash
   docker run -e BINDFS_SKIP_PATHS="/workspace/.git,/workspace/node_modules" ...
   ```

**Note**: This does NOT fix case-sensitivity issues. For those, see
`docs/troubleshooting/case-sensitive-filesystems.md`.

**Note**: On Linux hosts, bindfs is a safe no-op — the entrypoint detects that
permissions work correctly and skips the overlay.

### Stale `.fuse_hidden*` files

**Symptom**: Files named `.fuse_hidden0000000300000003` (or similar) appear in
your workspace, often inside `.claude/` or other directories.

**Cause**: When a FUSE filesystem (including bindfs) is active and a file is
deleted while a process still has it open, FUSE defers the removal by renaming
the file to `.fuse_hiddenXXXX`. The file is deleted when the last file
descriptor closes. However, if the process exits uncleanly or the container is
stopped before cleanup completes, these files are left behind.

This is normal FUSE behavior and cannot be disabled without breaking POSIX
semantics (the `-o hard_remove` FUSE option exists but causes `read()`/`write()`
failures on open deleted files and is explicitly discouraged).

**Solution**:

1. **Automatic cleanup**: The container handles this in two ways:

   - **Boot-time pass**: The entrypoint cleans up stale files from the previous
     session on every container start.
   - **Ongoing cron job**: When bindfs and cron are installed, a cron job runs
     every 10 minutes to clean up stale `.fuse_hidden*` files across all FUSE
     mount points. It uses `fuser` to skip files still held open by a process,
     so only truly orphaned files are removed. Disable with
     `FUSE_CLEANUP_DISABLE=true`.

1. Add `.fuse_hidden*` to your project's `.gitignore`:

   ```gitignore
   # FUSE filesystem artifacts (bindfs overlay deferred deletes)
   .fuse_hidden*
   ```

1. To manually clean up:

   ```bash
   find /workspace -name '.fuse_hidden*' -delete
   ```

### Cannot write to /workspace

**Symptom**: Permission denied when creating files in workspace.

**Solution**:

```bash
# Check ownership
ls -la /workspace

# If needed, fix ownership (inside container as root)
docker exec -u root mycontainer chown -R vscode:vscode /workspace

# Or rebuild with correct UID/GID (see above)
```

### Git operations fail with permission errors

**Symptom**: Cannot commit or push from inside container.

**Solution**:

```bash
# Fix git config
git config --global --add safe.directory /workspace/myproject

# Check SSH keys have correct permissions
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub
chmod 700 ~/.ssh

# For SSH agent forwarding
ssh-add -l  # Verify keys are loaded
```

### Docker socket permission denied

**Symptom**: Cannot use Docker inside container (Docker-in-Docker).

**Solution**:

```bash
# Add user to docker group
docker exec -u root mycontainer usermod -aG docker vscode

# Or mount socket with correct permissions
docker run -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add $(stat -c '%g' /var/run/docker.sock) \
  myproject:dev
```
