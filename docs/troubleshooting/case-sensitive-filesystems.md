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

````bash
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
```text

### Symptom 2: Import/Module Errors

```python
# file: MyModule.py
class MyClass:
    pass

# file: main.py
from mymodule import MyClass  # Works on macOS, fails on Linux
```text

On macOS: Import succeeds (case-insensitive) On Linux: Import fails (can't find
`mymodule`, only `MyModule`)

### Symptom 3: Build Tool Confusion

```bash
# Makefile references src/Main.go
# But filesystem has src/main.go

# On macOS: make succeeds
# On Linux: make fails (file not found)
```text

## Detection

### Automatic Detection (Built-in)

When you start a container, the runtime automatically detects case-insensitive
mounts and displays a warning:

```text
⚠ Case-insensitive filesystem detected on /workspace
   Host: macOS with case-insensitive APFS
   This may cause issues with git case changes and imports

   Recommendation: Use a case-sensitive volume for development
   See: docs/troubleshooting/case-sensitive-filesystems.md
```text

### Manual Detection

Check if a mount point is case-sensitive:

```bash
# Inside container
/usr/local/bin/detect-case-sensitivity.sh /workspace

# Output examples:
# ✓ /workspace is case-sensitive (safe)
# ⚠ /workspace is case-insensitive (may cause issues)
```text

Or manually test:

```bash
cd /workspace
touch testfile
touch TESTFILE
ls -la | grep -i testfile
# Case-sensitive: shows both testfile and TESTFILE
# Case-insensitive: shows only one file (last write wins)
rm -f testfile TESTFILE
```text

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
```text

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
```text

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
````

1. **Use language conventions**:
   - Python: `lowercase_with_underscores.py`
   - Go: `lowercase.go` or `package_name.go`
   - JavaScript: `camelCase.js` or `kebab-case.js`

### Solution 4: Fix Case Mismatches (Repair)

If you have existing case mismatches:

````bash
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
```text

## Prevention

### For New Projects

1. **Start with case-sensitive storage** (Solution 1)
1. **Establish naming conventions early**
1. **Document filesystem requirements** in project README
1. **Add pre-commit hook** to check for case issues:

```bash
#!/bin/bash
# .git/hooks/pre-commit
# Check for files that differ only by case

git ls-files | tr '[:upper:]' '[:lower:]' | sort | uniq -d | while read file; do
    echo "ERROR: Multiple files differ only by case: $file"
    exit 1
done
```text

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
```text

**Create case-sensitive APFS**:

```bash
# Disk Utility > File > New Image > Blank Image
# Name: DevWorkspace
# Size: 50 GB
# Format: APFS (Case-sensitive)
```text

### Windows

**Windows filesystems are always case-insensitive**. Solutions:

1. Use WSL2 filesystem (ext4 - case-sensitive):

   ```powershell
   # Store code in WSL2, not Windows
   \\wsl$\Ubuntu\home\user\projects
````

1. Use Docker volumes (always case-sensitive)

1. Use virtual machine with Linux filesystem

### Linux

Linux filesystems (ext4, xfs, btrfs) are **always case-sensitive**. No issues!

## Testing Your Setup

Run this test to verify case-sensitivity:

````bash
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
```text

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
```text

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
````
