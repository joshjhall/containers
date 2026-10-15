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

### `Unable to create '.git/index.lock': File exists` on macOS

**Symptom**: git writes intermittently fail with `fatal: Unable to create
'/workspace/<repo>/.git/index.lock': File exists`. Commits whose pre-commit
hooks re-stage fixed files fail with `couldn't stage fixed files: … exit
status 128` nearly every time. Less often, `git status` shows every tracked
file as a staged deletion (the index was emptied).

**Cause**: mostly two git clients fighting over one index (issue #1114,
upstream [zed-industries/zed#52265](https://github.com/zed-industries/zed/issues/52265)).
With the repo open in Zed, git runs against the same `.git` from both the
macOS host and Zed's remote server in the container. Git caches each file's
`dev`/`ino`/`uid`/`gid` in the index, and the two sides see different values
for the same file across the virtiofs mount. So every pass reads the other
side's entries as changed and rewrites the whole index under `index.lock`.
After a container-side `git add`, `git ls-files --debug` showed the entry
rewritten with host values (`dev: 16777244 uid: 501`) within about ten
seconds.

`--no-optional-locks` doesn't help. Zed already passes it, but porcelain
`git diff` (which Zed runs once per changed file, as `git diff --numstat`)
never checks it: `refresh_index_quietly()` in git's `builtin/diff.c` takes
the lock whenever it sees a stat-only mismatch. Only `git status` honors the
flag.

Measured on this repo, 300 back-to-back `touch f && git add f` from inside
the container:

| Config                    | `index.lock` failures |
| ------------------------- | --------------------: |
| default                   |                 6/300 |
| `core.checkStat=minimal`  |                 0/300 |

A clone on the same mount that Zed wasn't watching had 0/400 failures. So the
mount alone isn't the cause.

A smaller, separate effect does come from the mount: Docker Desktop's
virtiofs occasionally misreports the `rename(2)` git uses to commit an index
write, leaving a stale `index.lock` behind (issue #1086). Measured with a
loop that mirrors git's index write, anomalies per 10,000 cycles:

| Mount                                                       | Anomalies |
| ----------------------------------------------------------- | --------: |
| raw virtiofs (no bindfs)                                    |      6-10 |
| bindfs overlay (default)                                    |        18 |
| bindfs + `entry_timeout=0,attr_timeout=0,negative_timeout=0` |        22 |

Disabling FUSE caches doesn't help with that, and neither does excluding the
repo with `BINDFS_SKIP_PATHS`.

**Solution**:

1. Stop the host and container from fighting over the index. Run this once
   per affected repo; `.git/config` is on the mount, so both sides pick it up:

   ```bash
   git config core.checkStat minimal
   ```

   This makes git compare only whole-second mtime and size, the stat fields
   that agree across the boundary. It's safe to keep after Zed is fixed.

1. If a lock is already stuck, make sure no git command is running against the repo (including from
   another container or the host), then remove the lock:

   ```bash
   rm -f /workspace/<repo>/.git/index.lock
   ```

1. Run `git status` **before committing**. If every tracked file shows as a
   staged deletion, the index was emptied; rebuild it from `HEAD` without
   touching the working tree:

   ```bash
   git reset
   ```

   Never commit that state: it would delete the whole tree.

On every container start and hourly, `workspace-fs-health` reports any
`index.lock` older than ten minutes, with the exact path and these steps:

```text
[fs-health] stale git index lock (3600s old): /workspace/app/.git/index.lock (issue #1086)
```

It never deletes the lock itself, because it can't tell whether a git process
in another container still holds it.

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

#### Why `/usr/local/bin/fuse-cleanup` ships even without bindfs

Both legs above delegate to one shared sweeper, `/usr/local/bin/fuse-cleanup`,
and the image installs it **regardless of `INCLUDE_BINDFS`** — so you will find
it in a minimal build that has no bindfs and no cron. That is deliberate
(issue #954), for two reasons:

- The **boot-time pass is not gated either**. The entrypoint sources the bindfs
  runtime lib whenever it exists, and that lib is copied into every image, so
  the boot pass calls the sweeper on every container.
- That call site **reports** a missing sweeper rather than skipping silently
  (issue #951) — a silent skip looks exactly like a clean run, which is the
  failure mode the shared sweeper was introduced to fix. Gating the install
  would therefore print a `FUSE cleanup skipped` warning at every boot of every
  non-bindfs container, in exchange for about 10 KB of shell script.

The sweeper itself is a no-op when there is nothing to clean: with no FUSE mount
and no fallback root it prints `0` and exits. Set `FUSE_CLEANUP_DISABLE=true` to
turn the passes off entirely.

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
