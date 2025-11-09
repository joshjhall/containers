# Partial Version Resolution Analysis

## Overview
Review of all checksum implementations to determine which should support partial version resolution (e.g., "3.3" → "3.3.10").

## Analysis Criteria
- **Semantic Versioning**: Does the tool use semver (X.Y.Z)?
- **Multiple Patches Available**: Does the source list multiple patch versions?
- **User Benefit**: Would users benefit from auto-updating to latest patch?

## Checksum Implementations

### 1. fetch_ruby_checksum() ✅ COMPLETED
**Status**: Implemented with partial version support (2025-11-08)
**Source**: https://www.ruby-lang.org/en/downloads/
**Pattern**:
- Ruby downloads page lists latest patch per minor version
- Example: 3.3.10, 3.4.7 (not 3.3.9, 3.3.8, etc.)
**Implementation**:
- Detect partial version by counting dots (1 dot = partial)
- Search page for all matching versions (e.g., "Ruby 3.3.\d+")
- Sort with `sort -V` and take highest
- Export RUBY_RESOLVED_VERSION for caller
**Testing**:
- `RUBY_VERSION=3.3` → resolves to 3.3.10 ✓
- `RUBY_VERSION=3.4.7` → exact match ✓
**Commit**: 8b8016c - "feat: Add partial version resolution support to Ruby"

### 2. fetch_go_checksum() ✅ COMPLETED
**Status**: Implemented with partial version support (2025-11-08)
**Source**: https://go.dev/dl/
**Pattern**:
- Go downloads page lists ALL releases including older patches
- Example: 1.25.4, 1.25.3, 1.25.2, 1.25.1, 1.25.0, 1.24.10, 1.24.9, etc.
**Semantic Versioning**: Yes (1.X.Y format)
**Implementation**:
- Similar to Ruby implementation
- Detect partial version (1.23 vs 1.23.0)
- Search page for matching filenames (go1.23.\d+.linux-${arch}.tar.gz)
- Sort with `sort -V` and take highest
- Export GO_RESOLVED_VERSION for caller
**Testing**:
- `GO_VERSION=1.23` → resolves to 1.23.12 ✓
- `GO_VERSION=1.24` → resolves to 1.24.10 ✓
- `GO_VERSION=1.25.3` → exact match ✓
**Commit**: f105a8d - "feat: Add partial version resolution support to Go"

### 3. fetch_github_checksums_txt() ❌ NOT APPLICABLE
**Status**: Partial version resolution not applicable
**Used By**: lazygit, act, lazydocker, k9s
**Source**: GitHub release assets (checksums.txt files)
**Pattern**:
- GitHub releases use explicit tags (v0.56.0, v0.24.1, etc.)
- No concept of "latest patch for minor version"
- Users must specify exact release tag
**Reason**: GitHub releases are discrete tags, not a continuous version space

### 4. fetch_github_sha256_file() ❌ NOT APPLICABLE
**Status**: Partial version resolution not applicable
**Used By**: krew, terraform-docs, rustup
**Source**: GitHub release assets (.sha256 files)
**Pattern**: Same as fetch_github_checksums_txt()
**Reason**: GitHub releases are discrete tags

### 5. fetch_github_sha512_file() ❌ NOT APPLICABLE
**Status**: Partial version resolution not applicable
**Used By**: git-cliff
**Source**: GitHub release assets (.sha512 files)
**Pattern**: Same as fetch_github_checksums_txt()
**Reason**: GitHub releases are discrete tags

### 6. calculate_checksum_sha256() ❌ NOT APPLICABLE
**Status**: No version resolution needed
**Used By**: delta, helm
**Pattern**: Calculates checksum on download
**Reason**: No upstream version information to resolve

## Summary

### Implemented (2/6)
1. ✅ **fetch_ruby_checksum()** - Ruby version resolution (commit 8b8016c)
2. ✅ **fetch_go_checksum()** - Go version resolution (commit f105a8d)

### Not Applicable (4/6)
3. ❌ **fetch_github_checksums_txt()** - Discrete GitHub release tags
4. ❌ **fetch_github_sha256_file()** - Discrete GitHub release tags
5. ❌ **fetch_github_sha512_file()** - Discrete GitHub release tags
6. ❌ **calculate_checksum_sha256()** - No version metadata

## Benefits of Partial Version Support

### User Benefits
- **Automatic security patches**: Set `RUBY_VERSION=3.3` to automatically get latest 3.3.x patch
- **Package manager behavior**: Mirrors apt/yum behavior (e.g., `apt install ruby=3.3`)
- **Simplified versioning**: Don't need to update Dockerfile for every patch release
- **Backward compatible**: Exact versions still work (e.g., `RUBY_VERSION=3.4.7`)

### Examples
```dockerfile
# Partial version - auto-updates to latest patch
ARG RUBY_VERSION=3.3    # Gets 3.3.10 today, 3.3.11 tomorrow
ARG GO_VERSION=1.23      # Gets 1.23.12 today, 1.23.13 tomorrow

# Exact version - pins to specific patch
ARG RUBY_VERSION=3.4.7   # Always 3.4.7
ARG GO_VERSION=1.25.3    # Always 1.25.3
```

## Implementation Pattern

### Detection
```bash
# Count dots to detect partial version
local dot_count=$(echo "$version" | grep -o '\.' | wc -l)

if [ "$dot_count" -eq 1 ]; then
    # Partial version (e.g., "3.3" or "1.23")
else
    # Exact version (e.g., "3.3.10" or "1.25.3")
fi
```

### Resolution
```bash
# Search downloads page for all matching versions
matching_versions=$(echo "$page_content" | \
    grep -oP ">Ruby ${version}\.\d+<" | \
    sed 's/>Ruby //; s/<//' | \
    sort -V | \
    tail -1)

# Export for caller
export RUBY_RESOLVED_VERSION="$matching_versions"
```

### Caller Handling
```bash
# After calling fetch_*_checksum()
if [ -n "${RUBY_RESOLVED_VERSION:-}" ]; then
    log_message "Resolved Ruby ${RUBY_VERSION} to ${RUBY_RESOLVED_VERSION}"
    RUBY_VERSION="$RUBY_RESOLVED_VERSION"
fi
```

## Testing

All implementations tested with:
1. **Exact version**: Verifies exact match still works
2. **Partial version**: Verifies resolution to latest patch
3. **Invalid version**: Verifies error handling

Test results:
- Ruby unit tests: 556/557 passing (99%)
- Go unit tests: 546/547 passing (99%)

## Related Documentation
- `/workspace/containers/lib/features/lib/checksum-fetch.sh` - Checksum fetching library
- `/workspace/containers/lib/features/ruby.sh` - Ruby installation script
- `/workspace/containers/lib/features/golang.sh` - Go installation script
- `/workspace/containers/docs/checksum-verification-inventory.md` - Security audit tracking
