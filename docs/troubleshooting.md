# Troubleshooting Guide

This guide covers common issues and their solutions when using the container
build system.

> **📌 Important**: If you're experiencing build failures with Terraform, Google
> Cloud, or Kubernetes features, see the
> [Debian Version Compatibility](#debian-version-compatibility) section first. A
> critical fix was added in v4.0.1 for apt-key deprecation in Debian Trixie.

## Table of Contents

- [Build Issues](#build-issues)
- [Debian Version Compatibility](#debian-version-compatibility)
- [Runtime Issues](#runtime-issues)
- [Permission Issues](#permission-issues)
- [Network Issues](#network-issues)
- [Feature-Specific Issues](#feature-specific-issues)
- [CI/CD Issues](#cicd-issues)
- [Debugging Tools](#debugging-tools)

## Build Issues

### Understanding Build vs Buildx

**Important**: Docker may use `buildx` by default on some systems, which has
different behavior than traditional `docker build`.

**Check which builder you're using**:

````bash
# Check current builder
docker buildx ls

# Check if buildx is default
docker version | grep -A 10 "Server:"

# Use traditional builder
docker build .

# Use buildx explicitly
docker buildx build .
```text

**Key differences**:

- **Argument order**: Buildx requires the context (`.`) at the very end
- **Cache behavior**: Buildx may handle cache mounts differently
- **Output**: Different progress display formats

**Solution**: For this project, prefer traditional `docker build` or use the
test framework which handles both correctly.

### Build argument order (Buildx)

**Symptom**: Build fails with "context must be last argument" or similar error.

**Problem**: Buildx requires build context (`.`) as the final argument.

```bash
# ✗ WRONG (works with docker build, fails with buildx)
docker build -t myimage . --build-arg ARG=value

# ✓ CORRECT (works with both)
docker build -t myimage --build-arg ARG=value .
```text

**Solution**: Always put the build context (`.`) at the end of the command.

### Build fails with "permission denied" errors

**Symptom**: Build fails when trying to execute scripts.

**Solution**:

```bash
# Ensure all scripts have executable permissions
chmod +x lib/**/*.sh bin/*.sh
git add -u
git commit -m "fix: Add executable permissions to scripts"
```text

### BuildKit cache mount errors

**Symptom**: Errors about cache mounts or permission issues during build.

**Solution**:

```bash
# Clear BuildKit cache
docker builder prune -af

# Rebuild without cache
docker build --no-cache -t myproject:dev .
```text

### Script sourcing failures

**Symptom**: Build fails with "file not found" when sourcing scripts, even
though the file exists.

```text
/bin/bash: line 1: /tmp/build-scripts/base/logging.sh: No such file or directory
```text

**Causes**:

1. Scripts not copied to build context
1. Incorrect COPY statement in Dockerfile
1. Symlinks not resolved

**Solution**:

```bash
# Verify files are in build context
ls -la lib/base/

# Check Dockerfile COPY statement
grep "COPY lib" Dockerfile

# Ensure no broken symlinks
find lib -type l -exec test ! -e {} \; -print

# Rebuild with verbose output
DOCKER_BUILDKIT=0 docker build --progress=plain -t test .
```text

### Feature script execution fails mid-build

**Symptom**: Build stops during a feature installation with unclear error.

**Debugging steps**:

1. **Check the build logs**:

```bash
# Build with plain progress output
DOCKER_BUILDKIT=0 docker build --progress=plain . 2>&1 | tee build.log

# Search for errors
grep -i "error\|failed\|fatal" build.log
```text

1. **Test feature script in isolation**:

```bash
# Use test framework
./tests/test_feature.sh python-dev

# Or manually with Docker
docker run --rm -it debian:trixie-slim bash
# Then inside container:
apt-get update && apt-get install -y curl ca-certificates
# Copy and run your feature script
```text

1. **Check feature dependencies**:

```bash
# Some features require others
# Example: python-dev requires python
docker build \
  --build-arg INCLUDE_PYTHON=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  .
```text

### Compilation failures (Python, Ruby, Rust from source)

**Symptom**: Build fails when compiling language runtimes from source.

**Common causes**:

- Missing build dependencies
- Insufficient memory
- Corrupted downloads

**Solutions**:

```bash
# Check system dependencies are installed
docker run --rm debian:trixie-slim bash -c \
  "apt-get update && apt-get install -y build-essential"

# Increase Docker memory limit (Docker Desktop)
# Settings → Resources → Memory: 4GB+

# Verify download integrity
docker build --no-cache --build-arg PYTHON_VERSION=3.12.0 . 2>&1 | \
  grep -A 5 "Verifying checksum"

# Try a different version
docker build --build-arg PYTHON_VERSION=3.11.7 .
```text

### Cache invalidation issues

**Symptom**: Changes to scripts not reflected in build, or build uses old cached
layers.

**Understanding Docker layer caching**:

- Each `RUN` command creates a cached layer
- Cache invalidates if command changes or previous layers change
- COPY commands cache based on file content hashes

**Solutions**:

```bash
# Force rebuild without cache
docker build --no-cache -t myproject:dev .

# Invalidate from specific point
# Add --build-arg with changing value
docker build --build-arg BUST_CACHE=$(date +%s) .

# Clear all Docker build cache
docker builder prune -af

# Verify no cached layers used
DOCKER_BUILDKIT=0 docker build --progress=plain --no-cache . 2>&1 | \
  grep "cache"
```text

### Multi-stage build failures

**Symptom**: Build fails referencing files from previous stages, or "stage not
found" errors.

**Common issues**:

1. Stage name typo
1. Incorrect `--from` reference
1. File paths don't match between stages

**Solution**:

```bash
# Verify stage names in Dockerfile
grep "^FROM.*AS" Dockerfile

# Build only specific stage for testing
docker build --target base -t test:base .

# Check what files exist in a stage
docker run --rm test:base ls -la /tmp/build-scripts/
```text

### Environment variable vs build argument confusion

**Symptom**: Variables not available during build, or runtime values not set.

**Understanding ARG vs ENV**:

- `ARG`: Only available during build, not in running container
- `ENV`: Available during build AND runtime
- ARG can have default values: `ARG PYTHON_VERSION=3.12.0`

**Check what's available**:

```bash
# View build arguments in Dockerfile
grep "^ARG" Dockerfile

# Check if build arg is used
docker build --build-arg PYTHON_VERSION=3.14.0 .

# Runtime check
docker run --rm myimage env | grep PYTHON
```text

**See also**: [environment-variables.md](reference/environment-variables.md) for complete
reference.

### Intermediate build failure analysis

**Symptom**: Need to inspect container state at point of failure.

**Solution**: Create a debug point and inspect

```bash
# Method 1: Build to just before failure
# Add RUN command before failing step
RUN echo "Debug checkpoint" && bash

# Rebuild and commit at that point
docker build -t debug:checkpoint .
docker run -it debug:checkpoint bash

# Method 2: Use failed build container
# When build fails, Docker leaves container
docker ps -a | head -5

# Commit the failed state
docker commit <container-id> debug:failed

# Inspect
docker run --rm -it debug:failed bash
```text

### Testing feature installation without full build

**Solution**: Use the feature test script

```bash
# Test single feature quickly
./tests/test_feature.sh python-dev

# This creates minimal container and tests just that feature
# Faster than full build when debugging a specific feature
```text

### "Failed to resolve base image" error

**Symptom**: Cannot pull base Debian image.

**Solution**:

```bash
# Check Docker daemon is running
docker info

# Try pulling base image manually
docker pull mcr.microsoft.com/devcontainers/base:trixie

# Check network connectivity
ping -c 3 mcr.microsoft.com
```text

### Out of disk space during build

**Symptom**: Build fails with "no space left on device" error.

**Solution**:

```bash
# Check disk usage
df -h

# Clean up Docker resources
docker system prune -af --volumes

# Check build context size (should be reasonable)
du -sh .
```text

### Version download failures

**Symptom**: Failed to download specific tool versions (e.g., Python, Node.js).

**Solution**:

```bash
# Check if version exists
curl -I https://www.python.org/ftp/python/3.14.0/Python-3.14.0.tgz

# Update to a known good version
docker build --build-arg PYTHON_VERSION=3.13.7 .

# Check version-tracking.md for tested versions
cat docs/version-tracking.md
```text

## Debian Version Compatibility

### apt-key command not found (Terraform, Google Cloud, Kubernetes)

**Symptom**: Build fails with `apt-key: command not found` when installing
Terraform, Google Cloud SDK, or Kubernetes tools.

```text
bash: line 1: apt-key: command not found
✗ Adding HashiCorp GPG key failed with exit code 127
```text

**Cause**: Debian 13 (Trixie) and later removed the deprecated `apt-key`
command. The build system automatically detects your Debian version and uses the
appropriate method.

**Solution**: This is automatically handled as of v4.0.1. The system detects
whether `apt-key` is available:

- **Debian 11/12 (Bullseye/Bookworm)**: Uses legacy `apt-key` method
- **Debian 13+ (Trixie and later)**: Uses modern `signed-by` GPG method

**If you're on an older version of this container system**:

1. Update to the latest version:

   ```bash
   cd containers
   git pull origin main
   cd ..
   git add containers
   git commit -m "Update container build system"
````

1. Or manually patch the affected files:

   - `lib/features/terraform.sh`
   - `lib/features/gcloud.sh`
   - `lib/features/kubernetes.sh`

   See commit `b955fc3` for the fix implementation.

**Verification**:

````bash
# Check your Debian version
cat /etc/debian_version

# Rebuild and verify
docker build --build-arg INCLUDE_TERRAFORM=true -t test:terraform .
docker run --rm test:terraform terraform version
```text

### Base image mismatch with Debian Trixie

**Symptom**: Unexpected behavior when using older base images with Trixie
features.

**Solution**:

```bash
# For Debian Trixie, use:
docker build --build-arg BASE_IMAGE=debian:trixie-slim .

# For Debian Bookworm (12), use:
docker build --build-arg BASE_IMAGE=debian:bookworm-slim .

# For VS Code devcontainers:
docker build --build-arg BASE_IMAGE=mcr.microsoft.com/devcontainers/base:trixie .
```text

### Package not available in Trixie

**Symptom**: `E: Package 'package-name' has no installation candidate`

**Solution**:

```bash
# Check package availability
apt-cache policy package-name

# Update package lists
apt-get update

# Search for alternative package name
apt-cache search package-name

# If package was removed, check Debian migration notes
# https://wiki.debian.org/DebianTrixie
```text

### Writing Debian-Compatible Feature Scripts

**Pattern**: When creating or updating feature installation scripts, use the
Debian version detection system to ensure compatibility across Debian 11, 12,
and 13.

#### Debian Version Detection Functions

The build system provides three functions in `lib/base/apt-utils.sh`:

1. **`get_debian_major_version()`** - Returns the major version number (11, 12,
   or 13)
1. **`is_debian_version <min>`** - Checks if current version >= minimum
1. **`apt_install_conditional <min> <max> <packages...>`** - Install packages
   only on specific versions

#### Usage Examples

**Example 1: Install packages only on specific Debian versions**

```bash
# In your feature script, source apt-utils first
source /tmp/build-scripts/base/apt-utils.sh

# Install common packages (work on all versions)
apt_install \
    build-essential \
    libssl-dev \
    ca-certificates

# Install version-specific packages
# lzma/lzma-dev were removed in Debian 13, replaced by liblzma-dev
apt_install_conditional 11 12 lzma lzma-dev
```text

**Example 2: Conditional logic for installation methods**

```bash
source /tmp/build-scripts/base/apt-utils.sh

if command -v apt-key >/dev/null 2>&1; then
    # Old method for Debian 11/12
    log_message "Using apt-key method (Debian 11/12)"
    curl -fsSL https://example.com/key.gpg | apt-key add -
    apt-add-repository "deb https://example.com/apt stable main"
else
    # New method for Debian 13+
    log_message "Using signed-by method (Debian 13+)"
    curl -fsSL https://example.com/key.gpg | gpg --dearmor -o /usr/share/keyrings/example-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/example-keyring.gpg] https://example.com/apt stable main" > /etc/apt/sources.list.d/example.list
fi
```text

**Example 3: Check version before applying workarounds**

```bash
source /tmp/build-scripts/base/apt-utils.sh

if is_debian_version 13; then
    # Trixie-specific workaround
    log_message "Applying Debian 13+ configuration..."
    # Your Trixie-specific code
fi
```text

#### Package Migration Reference

Common package changes between Debian versions:

| Package        | Debian 11/12 | Debian 13+ | Notes                                   |
| -------------- | ------------ | ---------- | --------------------------------------- |
| lzma, lzma-dev | Available    | Removed    | Use liblzma-dev (works on all versions) |
| apt-key        | Available    | Removed    | Use signed-by method instead            |

#### Testing Your Changes

When adding version-specific logic:

1. **Test locally with different base images**:

   ```bash
   # Test Debian 11
   docker build --build-arg BASE_IMAGE=debian:bullseye-slim \
                --build-arg INCLUDE_YOUR_FEATURE=true -t test:debian11 .

   # Test Debian 12
   docker build --build-arg BASE_IMAGE=debian:bookworm-slim \
                --build-arg INCLUDE_YOUR_FEATURE=true -t test:debian12 .

   # Test Debian 13
   docker build --build-arg BASE_IMAGE=debian:trixie-slim \
                --build-arg INCLUDE_YOUR_FEATURE=true -t test:debian13 .
````

1. **CI automatically tests all versions**: The GitHub Actions workflow includes
   a `debian-version-test` job that tests Python and cloud tools on all three
   Debian versions.

#### Design Philosophy

- **Backwards Compatible**: Always support Debian 11 and 12 unless absolutely
  necessary
- **Forward Compatible**: Prefer methods that work on Debian 13+ when possible
- **Graceful Degradation**: Use version detection, don't assume availability
- **Explicit Detection**: Check for command/package availability, don't rely on
  version alone
- **Document Changes**: Add comments explaining why version-specific code exists

## Runtime Issues

### Container starts but commands not found

**Symptom**: Tools are installed but not in PATH.

**Solution**:

````bash
# Inside container, check PATH
echo $PATH

# Source the profile
source ~/.bashrc

# Check if tools are installed
ls -la /usr/local/bin
```text

### UID/GID conflicts with host

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
```text

### Cache directories not persisting

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
```text

### Python/Node/Ruby not found after installation

**Symptom**: Language runtime installed but not available.

**Solution**:

```bash
# Check installation logs
docker history myproject:dev | grep INCLUDE_

# Verify build args were passed correctly
docker inspect myproject:dev | grep INCLUDE_

# Rebuild with correct build args
docker build --build-arg INCLUDE_PYTHON_DEV=true .
```text

## Permission Issues

### Cannot write to /workspace

**Symptom**: Permission denied when creating files in workspace.

**Solution**:

```bash
# Check ownership
ls -la /workspace

# If needed, fix ownership (inside container as root)
docker exec -u root mycontainer chown -R vscode:vscode /workspace

# Or rebuild with correct UID/GID (see above)
```text

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
```text

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
```text

## Network Issues

### Cannot download packages during build

**Symptom**: apt-get, curl, or wget failures during build.

**Solution**:

```bash
# Check DNS resolution
docker run --rm myproject:dev nslookup github.com

# Try with explicit DNS
docker build --network=host .

# Or configure DNS in daemon.json
{
  "dns": ["8.8.8.8", "1.1.1.1"]
}
```text

### GitHub API rate limit exceeded

**Symptom**: Version checks or downloads from GitHub fail.

**Solution**:

```bash
# Add GitHub token to .env
echo "GITHUB_TOKEN=ghp_your_token_here" >> .env

# Or pass as build arg
docker build --build-arg GITHUB_TOKEN=$GITHUB_TOKEN .

# Check rate limit status
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/rate_limit
```text

### Proxy issues

**Symptom**: Cannot access external resources from behind corporate proxy.

**Solution**:

```bash
# Set proxy in Dockerfile
ENV http_proxy=http://proxy.corp.com:8080
ENV https_proxy=http://proxy.corp.com:8080
ENV no_proxy=localhost,127.0.0.1

# Or pass as build args
docker build \
  --build-arg http_proxy=$http_proxy \
  --build-arg https_proxy=$https_proxy \
  .
```text

## Security & Download Issues

### Checksum verification failure

**Symptom**: Build fails with checksum mismatch error during tool download.

```text
Error: Checksum verification failed
Expected: abc123...
Got:      def456...
```text

**Cause**: The downloaded file doesn't match the expected checksum. This could
indicate:

1. Network corruption during download
1. Tool maintainer updated the file without updating the checksum
1. Potential supply chain attack (rare but serious)

**Solution**:

1. **First, retry the build** (network corruption is common):

   ```bash
   docker build --no-cache .
````

1. **Check if the version is correct**:

   ```bash
   # View the version being installed
   grep 'VERSION=' lib/features/your-feature.sh

   # Try a different version
   docker build --build-arg TOOL_VERSION=1.2.3 .
   ```

1. **Verify the checksum source**:

   ```bash
   # For tools using published checksums (preferred method)
   # The error message will show the URL where checksums are fetched from
   # Visit that URL to verify checksums are correct

   # Example for terraform tools:
   curl -L https://github.com/gruntwork-io/terragrunt/releases/download/v0.71.3/SHA256SUMS
   ```

1. **If using calculated checksums** (fallback method):

   ```bash
   # The build calculates checksums at build time
   # If this fails consistently, the download source may be unstable
   # Check the download URL is still valid
   ```

1. **Report security concerns**:

   - If retries fail consistently
   - If checksum source is unreachable
   - If you suspect tampering
   - See `docs/SECURITY.md` for reporting procedures

**Related Files**:

- `lib/base/download-verify.sh` - Core verification logic
- `lib/features/lib/checksum-fetch.sh` - Checksum fetching utilities
- `docs/checksum-verification.md` - Complete implementation guide

### GPG signature verification failure

**Symptom**: Build fails when verifying GPG signatures.

````text
gpg: BAD signature from "Tool Maintainer <email@example.com>"
Error: GPG verification failed
```text

**Cause**: Downloaded package signature doesn't match the GPG key.

**Solution**:

1. **AWS CLI verification** (uses GPG signatures):

   ```bash
   # Check the GPG fingerprint being used
   grep -A 5 "AWS_CLI_GPG_FINGERPRINT" lib/features/aws.sh

   # Verify against official AWS documentation
   # https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
````

1. **Network/proxy issues**:

   ```bash
   # GPG verification requires downloading the signature file
   # Network interruptions can cause failures
   docker build --no-cache .
   ```

1. **Key server issues**:

   ```bash
   # If the script fetches keys from key servers
   # Try updating the keyserver URL in the feature script
   # Or use a different keyserver mirror
   ```

**Related Files**:

- `lib/features/aws.sh:172-198` - AWS CLI GPG verification implementation

### Download-verify.sh utility errors

**Symptom**: Build fails with errors from download-verify.sh utilities.

````text
Error: download_and_verify failed
Error: calculate_checksum_sha256 failed
```text

**Cause**: The download verification utilities encountered an error.

**Common Issues**:

1. **URL unreachable**:

   ```bash
   # Test the URL manually
   curl -I https://example.com/tool.tar.gz

   # Check DNS resolution
   docker run --rm debian:trixie-slim nslookup example.com
````

1. **Temporary file issues**:

   ```bash
   # Check disk space during build
   df -h

   # Clean up Docker build cache
   docker builder prune -af
   ```

1. **Missing dependencies**:

   ```bash
   # Ensure curl and sha256sum are available
   # These are installed in base/setup.sh
   which curl sha256sum
   ```

**Debugging**:

````bash
# Enable verbose logging in the feature script
# Add this temporarily to see detailed output:
set -x

# Check build logs for the failing feature
docker build --progress=plain . 2>&1 | grep -A 20 "download_and_verify"
```text

**Related Files**:

- `lib/base/download-verify.sh` - Core download verification functions
- `lib/features/lib/checksum-fetch.sh` - Checksum fetching from GitHub releases

### Checksum fetch failures (GitHub releases)

**Symptom**: Build fails when fetching checksums from GitHub releases.

```text
Error: Failed to fetch checksum for tool 1.2.3
```text

**Cause**: Cannot retrieve checksum file from GitHub release page.

**Solution**:

1. **GitHub API rate limiting**:

   ```bash
   # Check your rate limit
   curl -H "Authorization: token $GITHUB_TOKEN" \
     https://api.github.com/rate_limit

   # Add GitHub token to build
   docker build --build-arg GITHUB_TOKEN=$GITHUB_TOKEN .
````

1. **Checksum file not found**:

   ```bash
   # The tool may use a different checksum file format
   # Common patterns:
   # - SHA256SUMS, SHA256SUMS.txt
   # - checksums.txt, checksums_sha256.txt
   # - tool-version.sha256

   # Check the GitHub release page manually
   # Update the fetch_github_checksums_txt() call if needed
   ```

1. **Release doesn't exist**:

   ```bash
   # Verify the version exists on GitHub
   curl -I https://github.com/org/tool/releases/download/v1.2.3/tool.tar.gz

   # Update to a known good version
   docker build --build-arg TOOL_VERSION=1.2.2 .
   ```

**Related Files**:

- `lib/features/lib/checksum-fetch.sh` - GitHub checksum fetching logic

### Security best practices

When encountering download or verification issues:

1. ✅ **Always investigate checksum failures** - Don't disable verification
1. ✅ **Verify the source** - Check official documentation for
   checksums/signatures
1. ✅ **Use published checksums** when available (more trustworthy than
   calculated)
1. ✅ **Report persistent failures** - May indicate upstream issues
1. ❌ **Never skip verification** - Even for "trusted" sources
1. ❌ **Never hardcode checksums** - Breaks version flexibility

**Supply Chain Security**:

- All downloads use SHA256 verification (as of v4.5.0)
- See `docs/checksum-verification.md` for complete audit
- See `docs/security-hardening.md` for roadmap

## Feature-Specific Issues

### Python: pip install fails

**Symptom**: Python packages fail to install.

**Solution**:

````bash
# Check Python version
python3 --version

# Upgrade pip
pip3 install --upgrade pip

# Use cache mount
docker build --mount=type=cache,target=/cache/pip .

# Check for conflicting packages
pip3 check
```text

### Python: Poetry version mismatch

**Symptom**: Poetry commands fail or behave unexpectedly.

**Solution**:

```bash
# Check installed Poetry version
poetry --version

# The system pins Poetry to 2.2.1 (as of v4.0.1)
# To use a different version, update POETRY_VERSION in lib/features/python.sh

# Clear Poetry cache
poetry cache clear pypi --all

# Reinstall Poetry (inside container)
python3 -m pipx reinstall poetry==2.2.1
```text

### Node.js: npm install hangs

**Symptom**: npm install is extremely slow or hangs.

**Solution**:

```bash
# Clear npm cache
npm cache clean --force

# Use npm ci instead
npm ci

# Increase timeout
npm install --timeout=120000

# Check registry
npm config get registry
```text

### Rust: cargo build fails

**Symptom**: Cargo compilation errors.

**Solution**:

```bash
# Update Rust toolchain
rustup update stable

# Clean cargo cache
cargo clean

# Check for disk space
df -h /cache/cargo

# Rebuild with verbose output
cargo build --verbose
```text

### Docker: Cannot start Docker daemon in container

**Symptom**: docker: Cannot connect to the Docker daemon.

**Solution**:

```bash
# For Docker-in-Docker, you need privileged mode
docker run --privileged myproject:dev

# Or use Docker socket mounting (Docker-out-of-Docker)
docker run -v /var/run/docker.sock:/var/run/docker.sock myproject:dev

# Check Docker is installed
docker --version
```text

### Kubernetes: kubectl not configured

**Symptom**: kubectl: command not found or not configured.

**Solution**:

```bash
# Check if kubectl is installed
kubectl version --client

# Configure kubeconfig
export KUBECONFIG=/path/to/kubeconfig

# Or mount kubeconfig
docker run -v ~/.kube:/home/vscode/.kube myproject:dev
```text

## CI/CD Issues

### Integration tests failing

**Symptom**: Integration tests fail with build errors or tool verification
failures.

**Common Causes**:

1. **apt-key deprecation** (see
   [Debian Version Compatibility](#debian-version-compatibility))
1. **Network timeouts** during tool downloads
1. **Version mismatches** between pinned versions and available versions

**Solution**:

```bash
# Run integration tests locally to debug
./tests/run_integration_tests.sh

# Run specific test
./tests/run_integration_tests.sh cloud_ops

# Check test framework logs
cat tests/results/*.log

# Verify all tools can be installed
docker build --build-arg INCLUDE_KUBERNETES=true \
  --build-arg INCLUDE_TERRAFORM=true \
  --build-arg INCLUDE_AWS=true \
  -t test:debug .
```text

**Available Integration Tests**:

- `minimal` - Base container with no features
- `python_dev` - Python + dev tools + databases + Docker
- `node_dev` - Node.js + dev tools + databases + Docker
- `cloud_ops` - Kubernetes + Terraform + AWS + GCloud
- `polyglot` - Python + Node.js multi-language
- `rust_golang` - Rust + Go systems programming

### GitHub Actions: Build timeout

**Symptom**: Build exceeds 6 hour timeout.

**Solution**:

```yaml
# Use layer caching
- uses: docker/build-push-action@v6
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max

# Build only necessary variants
matrix:
  variant: [minimal, python-dev]  # Reduced from 5 to 2
```text

### GitHub Actions: Rate limit exceeded

**Symptom**: API calls to GitHub fail with 403.

**Solution**:

```yaml
# Ensure GITHUB_TOKEN is used
env:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

# Add retry logic
- name: Check versions
  run: |
    for i in {1..3}; do
      ./bin/check-versions.sh && break || sleep 30
    done
```text

### Security scanning fails

**Symptom**: Trivy or Gitleaks fail the build.

**Solution**:

```yaml
# For Trivy, allow high severity
- uses: aquasecurity/trivy-action@master
  with:
    severity: 'CRITICAL' # Only fail on critical

# For Gitleaks, use baseline
- uses: gitleaks/gitleaks-action@v2
  with:
    args: --baseline-path=.gitleaks-baseline.json
```text

### Image pull fails in CI

**Symptom**: Cannot pull image for scanning.

**Solution**:

```yaml
# Ensure login happens first
- name: Log in to registry
  uses: docker/login-action@v3
  with:
    registry: ghcr.io
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}

# Check image exists
- run: docker images
```text

## Debugging Tools

### Check build logs

```bash
# Inside container
check-build-logs.sh python-dev
check-build-logs.sh master-summary

# Or manually
cat /var/log/build-*.log
```text

### Verify installed versions

```bash
# Inside container
check-installed-versions.sh

# Or manually check specific tools
python3 --version
node --version
rustc --version
go version
```text

### Test feature installations

```bash
# Run unit tests
./tests/run_unit_tests.sh

# Test specific feature
./bin/test-all-features.sh --verbose

# Check if feature script ran
grep "python-dev" /var/log/build-master-summary.log
```text

### Inspect container layers

```bash
# View layer history
docker history myproject:dev

# Dive into layers
dive myproject:dev

# Export filesystem
docker export mycontainer > container.tar
```text

### Debug build failures

```bash
# Build with debug output
docker build --progress=plain --no-cache .

# Stop at specific stage
docker build --target=<stage-name> .

# Run failed step manually
docker run -it --rm myproject:dev bash
# Then run the failing command
```text

### Check resource usage

```bash
# Container stats
docker stats mycontainer

# Disk usage
docker system df

# Check limits
docker inspect mycontainer | grep -A 10 "Memory"
```text

## Getting Help

If you can't resolve your issue:

1. **Check existing issues**: https://github.com/joshjhall/containers/issues
1. **Check documentation**: Browse other docs in `docs/` directory
1. **Enable verbose logging**: Set `set -x` in scripts for detailed output
1. **Run integration tests**: `./tests/run_integration_tests.sh` to verify your
   setup
1. **Check CI status**: View recent builds at
   https://github.com/joshjhall/containers/actions
1. **Create an issue**: Include:
   - OS and Docker version (`docker version`)
   - Debian version (if relevant): `cat /etc/debian_version`
   - Build command used
   - Full error output
   - Relevant logs from `/var/log/build-*.log`
   - Output from `./bin/check-versions.sh`

## Quick Diagnostic Commands

```bash
# Check system info
docker version
docker info
cat /etc/debian_version  # Inside container

# Check build system version
git -C containers log -1 --oneline

# Verify tool versions
./bin/check-versions.sh

# Run unit tests (no Docker required)
./tests/run_unit_tests.sh

# Run integration tests (requires Docker)
./tests/run_integration_tests.sh

# Check installed tools in running container
docker exec mycontainer /bin/check-installed-versions.sh
```text

## Related Documentation

- [Version Tracking](reference/versions.md) - Managing tool versions
- [Testing Framework](development/testing.md) - Testing guide
- [Security and Init System](security-and-init-system.md) - Security model
- [README](../README.md) - Getting started
- [CHANGELOG](../CHANGELOG.md) - Recent changes and fixes
````
