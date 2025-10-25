# Troubleshooting Guide

This guide covers common issues and their solutions when using the container build system.

## Table of Contents

- [Build Issues](#build-issues)
- [Runtime Issues](#runtime-issues)
- [Permission Issues](#permission-issues)
- [Network Issues](#network-issues)
- [Feature-Specific Issues](#feature-specific-issues)
- [CI/CD Issues](#cicd-issues)
- [Debugging Tools](#debugging-tools)

## Build Issues

### Build fails with "permission denied" errors

**Symptom**: Build fails when trying to execute scripts.

**Solution**:
```bash
# Ensure all scripts have executable permissions
chmod +x lib/**/*.sh bin/*.sh
git add -u
git commit -m "fix: Add executable permissions to scripts"
```

### BuildKit cache mount errors

**Symptom**: Errors about cache mounts or permission issues during build.

**Solution**:
```bash
# Clear BuildKit cache
docker builder prune -af

# Rebuild without cache
docker build --no-cache -t myproject:dev .
```

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
```

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
```

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
```

## Runtime Issues

### Container starts but commands not found

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
```

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
```

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
```

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
```

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
```

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
```

## Feature-Specific Issues

### Python: pip install fails

**Symptom**: Python packages fail to install.

**Solution**:
```bash
# Check Python version
python3 --version

# Upgrade pip
pip3 install --upgrade pip

# Use cache mount
docker build --mount=type=cache,target=/cache/pip .

# Check for conflicting packages
pip3 check
```

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
```

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
```

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
```

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
```

## CI/CD Issues

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
```

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
```

### Security scanning fails

**Symptom**: Trivy or Gitleaks fail the build.

**Solution**:
```yaml
# For Trivy, allow high severity
- uses: aquasecurity/trivy-action@master
  with:
    severity: 'CRITICAL'  # Only fail on critical

# For Gitleaks, use baseline
- uses: gitleaks/gitleaks-action@v2
  with:
    args: --baseline-path=.gitleaks-baseline.json
```

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
```

## Debugging Tools

### Check build logs

```bash
# Inside container
check-build-logs.sh python-dev
check-build-logs.sh master-summary

# Or manually
cat /var/log/build-*.log
```

### Verify installed versions

```bash
# Inside container
check-installed-versions.sh

# Or manually check specific tools
python3 --version
node --version
rustc --version
go version
```

### Test feature installations

```bash
# Run unit tests
./tests/run_unit_tests.sh

# Test specific feature
./bin/test-all-features.sh --verbose

# Check if feature script ran
grep "python-dev" /var/log/build-master-summary.log
```

### Inspect container layers

```bash
# View layer history
docker history myproject:dev

# Dive into layers
dive myproject:dev

# Export filesystem
docker export mycontainer > container.tar
```

### Debug build failures

```bash
# Build with debug output
docker build --progress=plain --no-cache .

# Stop at specific stage
docker build --target=<stage-name> .

# Run failed step manually
docker run -it --rm myproject:dev bash
# Then run the failing command
```

### Check resource usage

```bash
# Container stats
docker stats mycontainer

# Disk usage
docker system df

# Check limits
docker inspect mycontainer | grep -A 10 "Memory"
```

## Getting Help

If you can't resolve your issue:

1. **Check existing issues**: https://github.com/yourusername/containers/issues
2. **Check documentation**: Browse other docs in `docs/` directory
3. **Enable verbose logging**: Set `set -x` in scripts for detailed output
4. **Create an issue**: Include:
   - OS and Docker version
   - Build command used
   - Full error output
   - Relevant logs from `/var/log/build-*.log`

## Related Documentation

- [Version Tracking](version-tracking.md) - Managing tool versions
- [Testing](testing.md) - Running tests
- [Architecture](architecture.md) - System design
- [README](../README.md) - Getting started
