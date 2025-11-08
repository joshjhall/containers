# Checksum Verification Implementation Guide

## Overview

This guide explains how to add SHA256 checksum verification to feature scripts to prevent supply chain attacks. All downloaded binaries should be verified before extraction or execution.

## Why Checksum Verification?

**Security Risk**: Without checksum verification, compromised or man-in-the-middle attacks could inject malicious binaries during container builds.

**Example Attack Scenario**:
```bash
# ❌ INSECURE - Downloads and executes without verification
curl -L https://example.com/install.sh | bash

# ❌ INSECURE - Downloads binary without checksum
curl -L https://example.com/tool -o /usr/local/bin/tool
chmod +x /usr/local/bin/tool
```

## Using the Download Verification Library

### 1. Source the Library

Add to your feature script:

```bash
#!/bin/bash
set -euo pipefail

# Source standard feature header
source /tmp/build-scripts/base/feature-header.sh

# Source download verification utilities
source /tmp/build-scripts/base/download-verify.sh
```

### 2. Define Checksums

Obtain official SHA256 checksums from the project's release page:

```bash
# Example: k9s checksums (hardcoded for security)
K9S_VERSION="0.32.4"
K9S_AMD64_SHA256="a1b2c3d4e5f6..."  # Get from GitHub releases
K9S_ARM64_SHA256="f6e5d4c3b2a1..."  # Get from GitHub releases
```

**Where to Find Checksums**:
- GitHub Releases: Look for `checksums.txt`, `SHA256SUMS`, or similar files
- Project Documentation: Check installation docs for verification instructions
- Official Downloads: Many projects provide `.sha256` files alongside binaries

**Example from k9s**:
```bash
# Visit: https://github.com/derailed/k9s/releases/tag/v0.32.4
# Download: checksums.txt
# Extract the SHA256 for your architecture
```

### 3. Download and Verify

Replace insecure download patterns with verified downloads:

#### Pattern 1: Download and Extract Tarball

**Before (Insecure)**:
```bash
curl -L https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz | \
    tar xz -C /usr/local/bin k9s
```

**After (Secure)**:
```bash
download_and_extract \
    "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
    "${K9S_AMD64_SHA256}" \
    "/usr/local/bin" \
    "k9s"
```

#### Pattern 2: Download Binary

**Before (Insecure)**:
```bash
curl -L https://example.com/tool -o /usr/local/bin/tool
chmod +x /usr/local/bin/tool
```

**After (Secure)**:
```bash
download_and_verify \
    "https://example.com/tool" \
    "${TOOL_SHA256}" \
    "/usr/local/bin/tool"

chmod +x /usr/local/bin/tool
```

#### Pattern 3: Download Script (Still Requires Review)

**Before (Very Insecure)**:
```bash
curl https://example.com/install.sh | bash
```

**After (Better, but still requires review)**:
```bash
# Download script to temp location
download_and_verify \
    "https://example.com/install.sh" \
    "${INSTALL_SCRIPT_SHA256}" \
    "/tmp/install.sh"

# Review the script (in CI/testing)
# cat /tmp/install.sh

# Execute with controlled environment
bash /tmp/install.sh

# Cleanup
rm -f /tmp/install.sh
```

**⚠️ Note**: Even with checksum verification, piping to bash is risky. Consider:
1. Mirroring the script in your repository
2. Using official package repositories instead
3. Building from source with verified releases

## Complete Example: Refactoring kubernetes.sh

### Before (Insecure)

```bash
# k9s installation
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    curl -L https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz | \
        tar xz -C /usr/local/bin k9s
elif [ "$ARCH" = "arm64" ]; then
    curl -L https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_arm64.tar.gz | \
        tar xz -C /usr/local/bin k9s
fi
```

### After (Secure)

```bash
#!/bin/bash
set -euo pipefail

# Source utilities
source /tmp/build-scripts/base/feature-header.sh
source /tmp/build-scripts/base/download-verify.sh

# Version and checksums
K9S_VERSION="0.32.4"

# SHA256 checksums from https://github.com/derailed/k9s/releases/tag/v0.32.4
# Verified on: 2025-11-07
K9S_AMD64_SHA256="abc123def456..."
K9S_ARM64_SHA256="789ghi012jkl..."

# k9s installation with verification
log_message "Installing k9s ${K9S_VERSION}..."

ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    download_and_extract \
        "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz" \
        "${K9S_AMD64_SHA256}" \
        "/usr/local/bin" \
        "k9s"
elif [ "$ARCH" = "arm64" ]; then
    download_and_extract \
        "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_arm64.tar.gz" \
        "${K9S_ARM64_SHA256}" \
        "/usr/local/bin" \
        "k9s"
else
    log_warning "k9s not available for architecture $ARCH, skipping..."
fi

# Verify installation
if command -v k9s >/dev/null 2>&1; then
    log_command "Verifying k9s installation" k9s version
else
    log_error "k9s installation failed"
    exit 1
fi
```

## Scripts Requiring Updates

The following scripts currently download binaries without checksum verification:

### High Priority (Binary Downloads)

1. **lib/features/kubernetes.sh**
   - k9s (lines 126-132)
   - krew (lines 158-162)
   - helm script (line 141) - consider mirroring script

2. **lib/features/terraform.sh**
   - tflint install script (line 146)

3. **lib/features/node.sh**
   - NodeSource setup script (lines 97, 116)

4. **lib/features/cloudflare.sh**
   - NodeSource setup script (line 74)

5. **lib/features/mojo.sh**
   - pixi installer script (line 119)

### Medium Priority (Package Managers with GPG)

These use package managers with GPG verification, but could add additional checks:

6. **lib/features/rust.sh**
   - rustup installer (line 73)

7. **lib/features/gcloud.sh**
   - Uses apt repository (already has GPG)

## Automation: Checksum Update Script

Consider creating a script to update checksums when bumping versions:

```bash
#!/bin/bash
# bin/update-checksums.sh

# Example for k9s
K9S_VERSION="0.32.4"

echo "Fetching checksums for k9s v${K9S_VERSION}..."
curl -sL "https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/checksums.txt" | \
    grep -E "k9s_Linux_(amd64|arm64).tar.gz"

# Parse and update feature script
```

## CI/CD Integration

Add checksum verification to your CI pipeline:

```yaml
- name: Verify tool checksums are current
  run: |
    # Script that checks if checksums in feature scripts match current releases
    ./bin/verify-checksums.sh
```

## Best Practices

1. **Hardcode Checksums**: Never fetch checksums dynamically
2. **Document Source**: Comment where checksums were obtained
3. **Date Verification**: Note when checksums were last verified
4. **Pin Versions**: Always use specific versions, never "latest"
5. **Test Before Commit**: Build locally to verify checksums are correct
6. **Review Scripts**: Even with checksums, review installation scripts before trusting them

## Migration Strategy

### Phase 1: Critical Binaries (Week 1)
- Add verification to k9s, kubectl, helm, terraform

### Phase 2: Package Manager Scripts (Week 2)
- Mirror critical installation scripts
- Add verification for mirrored scripts

### Phase 3: All Downloads (Week 3)
- Complete verification for all feature scripts
- Update CI to enforce verification

### Phase 4: Automation (Week 4)
- Create checksum update automation
- Add verification tests to CI

## Testing

After adding checksum verification:

```bash
# Test with correct checksum
docker build -t test:verify \
  -f Dockerfile \
  --build-arg INCLUDE_KUBERNETES=true \
  --no-cache \
  .

# Test failure case (wrong checksum)
# Temporarily modify checksum in script to verify error handling
```

## Questions?

- See `lib/base/download-verify.sh` for function documentation
- Open an issue for questions about specific tools
- Consult SECURITY.md for security reporting

---

**Status**: ✅ Utility functions created (2025-11-07)
**TODO**: Migrate existing feature scripts to use verification
