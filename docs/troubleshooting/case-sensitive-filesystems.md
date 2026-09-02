# Case-Sensitive Filesystem Issues

## Overview

Linux containers expect **case-sensitive** filesystems, but macOS and Windows
use **case-insensitive** filesystems by default. When you mount host directories
into containers, this mismatch can cause confusion and unexpected behavior.

## The Problem

### Filesystem Behavior Differences

| Platform    | Default Behavior | Example                                   |
| ----------- | ---------------- | ----------------------------------------- |
| **Linux**   | Case-sensitive   | `file.txt` ≠ `File.txt` (different files) |
| **macOS**   | Case-insensitive | `file.txt` = `File.txt` (same file)       |
| **Windows** | Case-insensitive | `file.txt` = `File.txt` (same file)       |

### Why This Matters

1. **Git tracks case changes** - Git records `README.md` vs `readme.md` as
   different filenames
1. **Filesystem ignores case** - macOS/Windows treat them as the same file
1. **Container sees what filesystem shows** - Linux container sees what the
   mounted filesystem provides
1. **Confusion ensues** - Git and filesystem disagree on what exists

## Common Symptoms

### Symptom 1: Git Changes Not Reflected

```bash
# On macOS host
git mv README.md readme.md
git commit -m "Lowercase readme"
git push

# Another developer pulls changes
# Inside Linux container
ls -la
# Shows: README.md (filesystem didn't change case)

git status
# Shows: nothing to commit, working tree clean

# But git thinks filename is readme.md
git ls-files | grep -i readme
# Shows: readme.md
```

A related and more dangerous variant: a file appears **twice** in
`git status`, once tracked and once untracked under a different case
(`catalog.rs` and `Catalog.rs`). On a case-insensitive filesystem these are
one file — the same inode reached through two cached names — which happens
when `core.ignorecase` is wrong (see
[Solution 5](#solution-5-align-git-coreignorecase)).

> **Warning — do not clean these up by deleting the "extra" entry.**
> Because both names resolve to the same inode, `rm Catalog.rs` deletes
> `catalog.rs` too, and `git clean -fd` will do exactly that across every
> shadowed path — silently destroying tracked source. Fix `core.ignorecase`
> instead; the phantom entries disappear on their own.

### Symptom 2: Import/Module Errors

```python
# file: MyModule.py
class MyClass:
    pass

# file: main.py
from mymodule import MyClass  # Works on macOS, fails on Linux
```

On macOS: Import succeeds (case-insensitive) On Linux: Import fails (can't find
`mymodule`, only `MyModule`)

### Symptom 3: Build Tool Confusion

```bash
# Makefile references src/Main.go
# But filesystem has src/main.go

# On macOS: make succeeds
# On Linux: make fails (file not found)
```

## Detection

### Automatic Detection and Repair (Built-in)

On every container start — and then hourly for as long as the container runs —
`42-workspace-fs-health.sh` probes the **project mount** and repairs two things
it can fix safely. It prints nothing when the workspace is healthy, so any
output means it acted:

```text
[fs-health] /workspace/myproject is on a case-insensitive mount
[fs-health] git core.ignorecase is 'unset' (incorrect for this mount)
[fs-health] set core.ignorecase=true (opt out with SKIP_CASE_FIX=true)
```

It also refreshes tracked symlinks whose filesystem attributes have gone stale,
which otherwise makes them show as permanently modified in `git status`:

```text
[fs-health] AGENTS.md: stale symlink attributes (nlink=0)
[fs-health] refreshed AGENTS.md -> CLAUDE.md
```

A link is treated as stale on either of two signals, and the report names which
one fired:

| Signal | Why it means "stale" |
| ------ | -------------------- |
| `nlink=0` | Impossible for a live symlink. A *broken* link (target missing) still reports `nlink=1`, so this never fires on one. |
| `st_size=0` with a non-empty target | What git actually keys on — it sizes a symlink from `st_size` before reading it, so a zero size makes git diff the link against the empty blob. A live symlink's `st_size` is the length of its target, so zero-size-with-a-real-target is a self-contradiction. |

Both repairs cover the superproject **and every initialized submodule,
recursively**. This matters because `git ls-files` stops at a submodule's
gitlink: a superproject-only pass never enumerates the submodule's symlinks at
all, so they decay indefinitely while the top-level ones get fixed. The
signature is a `git status` that permanently shows the submodule as modified
(`m` in the unstaged column) and nothing else, with the dirty symlinks visible
only one level down. Submodule paths are reported with their full prefix:

```text
[fs-health] containers/AGENTS.md: stale symlink attributes (nlink=0)
[fs-health] refreshed containers/AGENTS.md -> CLAUDE.md
```

A submodule's `core.ignorecase` is its own config and is aligned the same way.
Uninitialized submodules are skipped silently.

Both repairs also cover every **linked worktree** of the project — the
`.worktrees/issue-N` checkouts the golem flow creates. A linked worktree is
neither of the two roots above: it has its own working tree and its own index,
so `git ls-files` in the superproject never names it, and it is not a gitlink,
so the submodule walk never descends into it. Without this pass every fresh
worktree arrived with its tracked symlinks already showing as modified, so
`git status` could not be trusted as a clean-tree signal and a `git add -A`
would commit the symlink deletions. Worktree paths are reported relative to the
project root:

```text
[fs-health] .worktrees/issue-882/AGENTS.md: stale symlink attributes (nlink=0)
[fs-health] refreshed .worktrees/issue-882/AGENTS.md -> CLAUDE.md
```

Worktrees are enumerated **only when the scan starts from the main worktree**.
`git worktree list` is repo-global, so asking from inside a linked worktree
returns the whole set including the caller; restricting it to the primary
checkout keeps the walk loop-free and keeps
`workspace-fs-health /path/to/a/worktree` scoped to the worktree you named. A
registered worktree whose directory has been deleted but not pruned is skipped
silently, like an uninitialized submodule. Each worktree's own submodules are
walked as usual.

A worktree created **outside** the project root (`git worktree add` accepts any
path) gets the symlink repair but never a `core.ignorecase` decision. Unlike a
submodule, such a worktree can sit on a different mount, so the project's
case-sensitivity verdict is not evidence about it — and `core.ignorecase` is not
per-worktree: every worktree shares the repository's single `.git/config`, so
there is no "align just this one" to perform. Writing it from an out-of-tree
worktree would silently change the setting for the main checkout and every
sibling, so the project's own mount stays the sole authority. The symlink
repair, which really is per-worktree, still runs.

A worktree created hours into container uptime is picked up by the **hourly
cron leg** below, which re-runs the same scan against the same project root.

Both repairs are idempotent and leave file contents untouched. Two opt-outs:

| Variable           | Effect                                          |
| ------------------ | ----------------------------------------------- |
| `SKIP_CASE_FIX`    | Detect and report, but never write              |
| `SKIP_CASE_CHECK`  | Disable the check entirely                      |

#### Why it also runs hourly

The stale-symlink decay is a function of **uptime**, not of how the container
started: virtiofs re-caches the bad attributes on long-lived links, so a
container left up for a couple of days drifts back into the broken state after
the boot-time repair already fixed it once.

That is worth more than a clean `git status`. With the links reading as empty,
git sees the stored target line as deleted, so `git add -A`, `git commit -a`,
or `git stash` will stage the **deletion of the symlinks** — the same class of
silent data loss as the `git clean -fd` hazard below, reached by a different
route. Explicit file-by-file staging stays safe; scripted and agentic paths
using `-A`/`-a` do not.

So the same script also runs from cron at **:17 past every hour**
(`/etc/cron.d/workspace-fs-health`). It is silent and idempotent when healthy,
so the recurring pass costs nothing when there is nothing to fix. The hourly
leg requires the **cron feature** (`INCLUDE_CRON=true`, also pulled in by
`INCLUDE_DEV_TOOLS` and `INCLUDE_RUST_DEV`); without it the boot-time repair
and the on-demand command below still work. `SKIP_CASE_CHECK=true` disables the
hourly pass along with everything else.

The cron entry runs as **root** and the wrapper drops to the container user it
resolves at run time, using the same ladder the entrypoint does. Cron's user
column is written when the image is built, but the runtime user is not knowable
then (Zed adopts the host UID, VS Code keeps 1000), and a stale name there would
fail *silently*: the job would run as a user that exists, look for its state
under the wrong `HOME`, find nothing, and exit successfully having repaired
nothing.

One caveat on that parity. The ladder's first arm honors `CONTAINER_UID`, but
cron inherits nothing from `docker run -e`, and nothing writes that value into
the root-owned `/etc/container/cron-env` the wrapper reads. So **`CONTAINER_UID`
is not honored by the hourly leg today** — it resolves by **user shape**, which
is correct for every image with a single regular login user (all of ours). The
two legs could only disagree on an image with a second such account *and* a
`CONTAINER_UID` naming the other one. Exporting `CONTAINER_UID` from
`/etc/container/cron-env` is the supported way to make that arm live, since the
wrapper sources that file before resolving.

Its output is appended to a **log file**, not mailed — these images ship no MTA,
and no syslog daemon either, so `logger` would discard the message and still
exit 0:

```bash
tail /var/log/workspace-fs-health.log
```

#### Running it on demand

To repair right now — typically when symlinks are showing as modified just
before a commit:

```bash
workspace-fs-health              # inspect the current directory's project
workspace-fs-health /workspace/myproject
```

Silent when healthy, and it honors the same `SKIP_CASE_FIX` /
`SKIP_CASE_CHECK` variables as the automatic runs.

### Manual Detection

Check if a mount point is case-sensitive:

```bash
# Inside container — pass the project mount, not /workspace
/usr/local/bin/detect-case-sensitivity.sh /workspace/myproject

# Output examples:
# ✓ /workspace/myproject is case-sensitive (safe)
# ⚠ /workspace/myproject is case-insensitive (may cause issues)
```

Or manually test:

```bash
cd /workspace
touch testfile
touch TESTFILE
ls -la | grep -i testfile
# Case-sensitive: shows both testfile and TESTFILE
# Case-insensitive: shows only one file (last write wins)
rm -f testfile TESTFILE
```

## Solutions

### Solution 1: Use Case-Sensitive APFS Volume (macOS - Recommended)

Create a dedicated case-sensitive volume for development:

```bash
# Create a 50GB case-sensitive APFS volume
hdiutil create -size 50g -fs "Case-sensitive APFS" -volname DevWorkspace ~/DevWorkspace.dmg

# Mount it
hdiutil attach ~/DevWorkspace.dmg

# Move your code
mv ~/projects /Volumes/DevWorkspace/

# Create symlink for convenience
ln -s /Volumes/DevWorkspace/projects ~/projects

# Auto-mount on login (optional)
# System Preferences > Users & Groups > Login Items > Add DevWorkspace.dmg
```

**Pros**:

- ✅ Perfect compatibility with Linux containers
- ✅ No git confusion
- ✅ Same behavior across all platforms

**Cons**:

- ❌ One-time setup required
- ❌ Extra disk image to manage
- ❌ Some macOS apps might have issues (rare)

### Solution 2: Use Docker Volume (Project-Specific)

Instead of mounting host directory, use a Docker volume:

```bash
# Create a Docker volume (always case-sensitive)
docker volume create myproject-code

# Initialize it with your code
docker run --rm \
  -v "$(pwd):/source:ro" \
  -v myproject-code:/workspace \
  alpine sh -c "cp -a /source/. /workspace/"

# Use the volume in development
docker run -it \
  -v myproject-code:/workspace/myproject \
  myimage:dev

# Sync changes back to host (when needed)
docker run --rm \
  -v myproject-code:/workspace \
  -v "$(pwd):/dest" \
  alpine sh -c "cp -a /workspace/. /dest/"
```

**Pros**:

- ✅ Always case-sensitive
- ✅ Better performance than host mounts
- ✅ No host filesystem changes needed

**Cons**:

- ❌ Code not directly accessible on host
- ❌ Requires sync step for IDE/tools on host
- ❌ More complex workflow

### Solution 3: Name Files Carefully (Workaround)

If you can't use solutions 1 or 2, follow these guidelines:

1. **Use consistent casing**:

   - ✅ Always lowercase: `myfile.py`, `mymodule.go`
   - ✅ Or always PascalCase: `MyFile.py`, `MyModule.go`
   - ❌ Never mix: `myFile.py` and `MyFile.py`

1. **Never rename just to change case**:

   ```bash
   # ❌ DON'T: macOS won't reflect this change
   git mv README.md readme.md

   # ✅ DO: Rename to temp name first
   git mv README.md temp.md
   git commit -m "Rename step 1"
   git mv temp.md readme.md
   git commit -m "Rename step 2"
   ```

1. **Use language conventions**:

   - Python: `lowercase_with_underscores.py`
   - Go: `lowercase.go` or `package_name.go`
   - JavaScript: `camelCase.js` or `kebab-case.js`

### Solution 4: Fix Case Mismatches (Repair)

If you have existing case mismatches:

```bash
# Find files where git and filesystem disagree
git ls-files | while read file; do
    if [ ! -f "$file" ]; then
        echo "Mismatch: $file"
    fi
done

# Fix by renaming with temp file
# Inside container (case-sensitive environment)
git mv README.md temp-readme.md
git commit -m "Temp rename"
git mv temp-readme.md readme.md
git commit -m "Fix case"
git push
```

### Solution 5: Align git core.ignorecase

Git records whether the filesystem is case-insensitive in `core.ignorecase`,
probed once when the repo is created. A repo **cloned on a case-sensitive
filesystem and later moved** to a case-insensitive one keeps the stale
`false`, and git then reports each case-variant spelling as a separate
untracked file (see the warning under Symptom 1).

Check whether git's belief matches reality:

```bash
# What git believes
git config --get core.ignorecase          # empty output means false

# What is actually true
detect-case-sensitivity.sh "$PWD"          # exit 1 = case-insensitive
```

If the filesystem is case-insensitive and `core.ignorecase` is not `true`:

```bash
git config core.ignorecase true
```

This is local to `.git/config`, so it does not affect teammates who clone on a
case-sensitive filesystem. It also covers every linked worktree, since they
share the repository config. Setting it does **not** hide genuinely new files —
only the duplicate spellings of files git already tracks.

Containers built from this repo apply this fix automatically at startup; see
[Detection](#detection).

## Prevention

### For New Projects

1. **Start with case-sensitive storage** (Solution 1)
1. **Establish naming conventions early**
1. **Document filesystem requirements** in project README
1. **Re-clone rather than move a repo** between filesystems of different
   case-sensitivity — moving leaves `core.ignorecase` stale (Solution 5).
   Containers built from this repo correct it automatically at startup.
1. **Add a lefthook hook** to check for case issues. In `lefthook.yml`:

```yaml
pre-commit:
  commands:
    case-collision-check:
      run: |
        git ls-files | tr '[:upper:]' '[:lower:]' | sort | uniq -d | while read file; do
          echo "ERROR: Multiple files differ only by case: $file"
          exit 1
        done
```

Then run `lefthook install` to register the hook.

### For Team Development

1. **Document filesystem setup** in project README
1. **Test on Linux** regularly (even if developing on macOS/Windows)
1. **Use CI/CD** to catch case-sensitivity issues early
1. **Agree on naming conventions** (commit them to CONTRIBUTING.md)

## Platform-Specific Notes

### macOS

**Check your filesystem type**:

```bash
diskutil info / | grep "File System"
# Case-sensitive APFS: ✅ Good
# APFS: ⚠ Case-insensitive (default)
```

**Create case-sensitive APFS**:

```bash
# Disk Utility > File > New Image > Blank Image
# Name: DevWorkspace
# Size: 50 GB
# Format: APFS (Case-sensitive)
```

### Windows

**Windows filesystems are always case-insensitive**. Solutions:

1. Use WSL2 filesystem (ext4 - case-sensitive):

   ```powershell
   # Store code in WSL2, not Windows
   \\wsl$\Ubuntu\home\user\projects
   ```

1. Use Docker volumes (always case-sensitive)

1. Use virtual machine with Linux filesystem

### Linux

Linux filesystems (ext4, xfs, btrfs) are **always case-sensitive**. No issues!

## Testing Your Setup

Run this test to verify case-sensitivity:

```bash
# Create test directory
mkdir -p /tmp/case-test
cd /tmp/case-test

# Create two files differing only by case
echo "lowercase" > testfile.txt
echo "uppercase" > TESTFILE.TXT

# Check result
file_count=$(ls -1 | wc -l)

if [ "$file_count" -eq 2 ]; then
    echo "✅ Case-sensitive filesystem (correct)"
else
    echo "⚠ Case-insensitive filesystem (may cause issues)"
fi

# Cleanup
rm -f testfile.txt TESTFILE.TXT
cd -
```

## FAQ

### Q: Can I convert my existing macOS volume to case-sensitive?

**A**: No, you cannot convert in-place. You must:

1. Create a new case-sensitive APFS container or disk image
1. Copy files to the new volume
1. Update paths and bookmarks

### Q: Will case-sensitive APFS break macOS applications?

**A**: Most modern apps work fine. Issues are rare and usually affect:

- Very old applications (pre-2015)
- Adobe Creative Cloud (older versions)
- Some games

Use case-sensitive volume ONLY for development projects, not your entire system.

### Q: Does Docker Desktop support case-sensitive volumes automatically?

**A**: No. Docker Desktop uses the host filesystem's case-sensitivity. You must:

- Use case-sensitive host filesystem (APFS/ext4)
- OR use Docker volumes (always case-sensitive)

### Q: How do I know if my project has case issues?

**A**: Run these checks:

```bash
# Check for duplicate filenames (case-insensitive)
git ls-files | tr '[:upper:]' '[:lower:]' | sort | uniq -d

# Check if git and filesystem agree
git ls-files | while read f; do
    [ -f "$f" ] || echo "Missing: $f"
done
```

## Related Documentation

- [Docker Volumes](https://docs.docker.com/storage/volumes/)
- [APFS Case Sensitivity](https://developer.apple.com/documentation/foundation/file_system/about_apple_file_system)
- [WSL2 Filesystem](https://docs.microsoft.com/en-us/windows/wsl/filesystems)

## Summary

**Best Practices**:

1. ✅ Use case-sensitive storage for development (macOS: APFS volume, Windows:
   WSL2)
1. ✅ Use consistent naming conventions
1. ✅ Test on Linux regularly
1. ✅ Avoid case-only renames
1. ✅ Document filesystem requirements

**Quick Fix**:

- macOS: Create case-sensitive APFS volume (Solution 1)
- Windows: Use WSL2 filesystem
- Linux: You're already good!

**Prevention**:

- Pre-commit hooks to detect case conflicts
- Team conventions documented in CONTRIBUTING.md
- CI/CD testing on Linux

---

**Need help?** See [main troubleshooting guide](../troubleshooting.md) or
[file an issue](https://github.com/joshjhall/containers/issues).
