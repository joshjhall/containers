# Security Best Practices

This page documents the informational and best-practice security improvements
identified during the OWASP audit, covering secrets handling, Docker socket
security, temporary files, rate limiting, image digests, and container signing.

______________________________________________________________________

## #11: Secrets Could Be Exposed in Build Logs

**Priority**: INFORMATIONAL **Status**: COMPLETE (2025-11-09) **Actual
Effort**: 30 minutes

**Risk**: Sensitive data exposure in container build logs if users pass secrets
as build arguments.

**Observation**: While the system doesn't explicitly log secrets, build
arguments and environment variables appear in Docker build logs. If users
mistakenly pass secrets as build args, they would be exposed.

**Recommended Actions**:

1. **Add Warning to Dockerfile**:

```dockerfile
# ============================================================================
# SECURITY WARNING
# ============================================================================
# NEVER pass secrets as build arguments! Build arguments are visible in:
#   - Docker build logs
#   - Docker image history
#   - Container inspection
#
# For secrets, use:
#   - Environment variables at runtime
#   - Docker secrets
#   - Mounted config files
#   - Secret management tools (1Password CLI, AWS Secrets Manager, etc.)
# ============================================================================
```

1. **Add to README.md**:

```markdown
## Security Best Practices

### Never Pass Secrets as Build Arguments

Build arguments are **permanently stored** in the image and visible in:

- Docker build logs
- Image history (`docker history <image>`)
- Container inspection (`docker inspect <container>`)

**DON'T DO THIS:**

\`\`\`bash
docker build --build-arg API_KEY=secret123 ...
\`\`\`

**DO THIS INSTEAD:**

\`\`\`bash
# Use environment variables at runtime
docker run -e API_KEY=secret123 ...

# Or use Docker secrets
docker secret create api_key ./api_key.txt
docker service create --secret api_key ...

# Or use mounted config files
docker run -v ./secrets:/secrets:ro ...

# Or use secret management tools
docker run -e OP_SERVICE_ACCOUNT_TOKEN=... ...
\`\`\`
```

1. **Consider Implementing Secret Scrubbing** (future enhancement):

   ```bash
   # In logging functions, scrub common secret patterns
   log_message() {
    local message="$1"
    # Scrub common secret patterns
    message=$(echo "$message" | sed -E 's/(password|secret|key|token)=[^ ]+/\1=***REDACTED***/gi')
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $message" | tee -a "$LOG_FILE"
   }
   ```

______________________________________________________________________

## #12: Docker Socket Mounting Creates Container Escape Vector

**Priority**: INFORMATIONAL **Status**: COMPLETE (2025-11-09) **Actual
Effort**: 15 minutes (documentation only)

**Risk**: Container escape via Docker socket access when using Docker-in-Docker
functionality.

**Observation**: The Docker feature (`lib/features/docker.sh`) is designed for
Docker-in-Docker scenarios that require mounting `/var/run/docker.sock`. This
grants full Docker API access, which can be used to escape the container.

**This is by design** for the Docker feature, but should be clearly documented.

**Recommended Actions**:

1. **Update `lib/features/docker.sh` header comments**:

```bash
#!/bin/bash
# Docker CLI and Tools
#
# Description:
#   Installs Docker CLI tools for Docker-in-Docker (DinD) scenarios
#
# SECURITY WARNING:
#   This feature is designed for development containers that need Docker access.
#   Mounting the Docker socket provides FULL HOST ACCESS and can be used for:
#     - Container escape
#     - Host filesystem access
#     - Privilege escalation
#
#   Only use this feature in trusted development environments.
#   For production, consider:
#     - Sysbox (rootless container runtime)
#     - Podman (daemonless container engine)
#     - Kaniko (Dockerfile builds without Docker)
#     - BuildKit in rootless mode
#
# Usage:
#   Build with: --build-arg INCLUDE_DOCKER=true
#   Run with: -v /var/run/docker.sock:/var/run/docker.sock
```

1. **Add to README.md Docker section**:

```markdown
### Docker Feature Security Considerations

The Docker feature enables Docker-in-Docker functionality by mounting the host's
Docker socket. This provides **full access to the Docker daemon** and should
only be used in trusted development environments.

**Security Implications:**

- Enables running Docker commands inside the container
- Provides full access to host's Docker daemon
- Can be used to escape the container
- Can access host filesystem via volume mounts
- Can start privileged containers

**Production Alternatives:**

- **Sysbox**: Rootless container runtime with Docker-in-Docker support
- **Podman**: Daemonless container engine (no socket required)
- **Kaniko**: Build container images without Docker daemon
- **BuildKit**: Rootless mode for secure builds
```

______________________________________________________________________

## #13: Temporary File Security

**Priority**: LOW **Status**: COMPLETE (2025-11-09) **Actual Effort**: 2
hours

**Risk**: Potential temporary file attacks or race conditions when using `/tmp`
without secure temp file creation.

**Observation**: Many scripts use `/tmp` for downloads and extraction without
always using secure temporary file creation patterns.

**Current Pattern**:

```bash
cd /tmp
wget https://example.com/file.tar.gz
tar -xzf file.tar.gz
```

**Recommended Pattern**:

```bash
# Create secure temporary directory
BUILD_TEMP=$(mktemp -d)
trap "rm -rf '$BUILD_TEMP'" EXIT

cd "$BUILD_TEMP"
wget https://example.com/file.tar.gz
tar -xzf file.tar.gz
# Work is automatically cleaned up on exit
```

**Benefits**:

- Unique directory per build
- Automatic cleanup on exit (even on error)
- Protection against symlink attacks
- No collision with other builds

**Implementation Plan**:

1. Create helper function in `lib/base/feature-header.sh`
1. Update all feature scripts to use the pattern
1. Ensure trap handlers don't conflict

______________________________________________________________________

## #14: No Rate Limiting on External API Calls

**Priority**: INFORMATIONAL **Status**: COMPLETE (2025-11-09) **Actual
Effort**: 2 hours

**Risk**: Build failures due to rate limiting from external services. Potential
unintentional DoS of external services during high-volume builds.

**Observation**: Scripts make multiple GitHub API calls and downloads without
rate limiting or retry logic. GitHub API has rate limits (60/hour
unauthenticated, 5000/hour with token).

**Implementation**:

Created `lib/base/retry-utils.sh` with three retry functions:

1. **retry_with_backoff()** - Generic retry with exponential backoff (2s -> 4s ->
   8s, max 30s)

   - Configurable via `RETRY_MAX_ATTEMPTS`, `RETRY_INITIAL_DELAY`,
     `RETRY_MAX_DELAY`
   - Returns original exit code after final attempt

1. **retry_command()** - Wrapper with logging integration

   - Takes description as first parameter
   - Integrates with logging.sh if available

1. **retry_github_api()** - GitHub-specific retry with rate limit awareness

   - Automatically adds `Authorization` header if `GITHUB_TOKEN` is set
   - Detects rate limit errors (403, "rate limit" messages)
   - Provides helpful messages about token benefits

   Updated `lib/base/checksum-fetch.sh` to use retry_github_api for:

   - `fetch_github_checksums_txt()` - Checksums.txt file fetching
   - `fetch_github_sha256_file()` - Individual .sha256 file fetching
   - `fetch_github_sha512_file()` - Individual .sha512 file fetching

   **Files Modified**:

   - `lib/base/retry-utils.sh` (NEW)
   - `lib/base/checksum-fetch.sh`

   **Benefits**:

   - Reduced build failures from transient network issues
   - GitHub rate limit detection and helpful guidance
   - 5000x rate limit increase when using GITHUB_TOKEN (60 -> 5000 requests/hour)
   - Exponential backoff prevents hammering external services

______________________________________________________________________

## #15: Missing Container Image Digests in Releases

**Priority**: MEDIUM **Status**: COMPLETE (2025-11-09) **Actual Effort**: 30
minutes

**Risk**: Users cannot verify container image integrity. Missing standard supply
chain security practice for published artifacts.

**Observation**: The CI/CD pipeline builds and publishes container images to
GHCR, but doesn't publish image digests (SHA256 hashes) in GitHub releases. This
makes it difficult for users to verify they're pulling the correct, unmodified
images.

**Recommended Fix**:

Add a new step to the `release` job in `.github/workflows/ci.yml`:

```yaml
- name: Generate image digests
  id: digests
  run: |
    cat > image-digests.txt << EOF
    # Container Image Digests for Release ${{ steps.version.outputs.VERSION }}
    #
    # Verify images using:
    #   docker pull ghcr.io/${{ github.repository }}:<variant>@sha256:<digest>
    #
    # Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
    EOF

    for variant in minimal python-dev node-dev cloud-ops polyglot rust-golang; do
      IMAGE="${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.version.outputs.VERSION }}-${variant}"

      # Get image digest from registry
      DIGEST=$(docker buildx imagetools inspect "$IMAGE" --format '{{.Manifest.Digest}}')

      echo "" >> image-digests.txt
      echo "## ${variant}" >> image-digests.txt
      echo "Image: ${IMAGE}" >> image-digests.txt
      echo "Digest: ${DIGEST}" >> image-digests.txt
    done

- name: Attach image digests to release
  uses: softprops/action-gh-release@v2
  with:
    files: image-digests.txt
```

______________________________________________________________________

## #16: Container Image Signing with Cosign

**Priority**: MEDIUM **Status**: COMPLETE (2025-11-09) **Actual Effort**: 45
minutes

**Risk**: No cryptographic proof of image authenticity. Advanced supply chain
attacks could replace images without detection.

**Benefits of Image Signing**:

- **Cryptographic proof**: Images signed by specific identity (GitHub Actions
  OIDC)
- **Tamper detection**: Any modification invalidates signature
- **Keyless signing**: Uses Sigstore public infrastructure (no key management)
- **SLSA compliance**: Moves toward SLSA Level 3 supply chain security
- **Industry standard**: Used by Kubernetes, Docker, and major projects

**Recommended Implementation**:

```yaml
# In .github/workflows/ci.yml, add after the build job

- name: Install Cosign
  uses: sigstore/cosign-installer@v3

- name: Sign container images with Cosign
  env:
    COSIGN_EXPERIMENTAL: 1 # Enable keyless signing
  run: |
    for variant in minimal python-dev node-dev cloud-ops polyglot rust-golang; do
      IMAGE="${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.version.outputs.VERSION }}-${variant}"
      echo "Signing: $IMAGE"
      cosign sign --yes "$IMAGE"
      echo "Signed: $IMAGE"
    done
```

**Security Properties**:

- **Keyless signing**: No private keys to manage or leak
- **Transparency log**: All signatures recorded in Sigstore Rekor
- **OIDC-based**: Identity tied to GitHub repository and workflow
- **Verification without registry**: Can verify locally pulled images

**User Workflow**:

```bash
# User pulls image
docker pull ghcr.io/joshjhall/containers:v4.5.0-python-dev

# User verifies signature before running
cosign verify \
  --certificate-identity-regexp "^https://github.com/joshjhall/containers/.github/workflows/ci.yml@" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/joshjhall/containers:v4.5.0-python-dev

# Now safe to run
docker run -it ghcr.io/joshjhall/containers:v4.5.0-python-dev
```

**Permissions Required**: Add to `.github/workflows/ci.yml` `release` job:

```yaml
permissions:
  contents: write
  packages: read
  id-token: write # Required for OIDC signing
```
