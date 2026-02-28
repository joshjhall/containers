# CI/CD Issues

This section covers issues specific to continuous integration and deployment
pipelines, including test failures, timeouts, and security scanning.

## Integration tests failing

**Symptom**: Integration tests fail with build errors or tool verification
failures.

**Common Causes**:

1. **apt-key deprecation** (see
   [Debian Version Compatibility](debian-compatibility.md))
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
```

**Available Integration Tests**:

- `minimal` - Base container with no features
- `python_dev` - Python + dev tools + databases + Docker
- `node_dev` - Node.js + dev tools + databases + Docker
- `cloud_ops` - Kubernetes + Terraform + AWS + GCloud
- `polyglot` - Python + Node.js multi-language
- `rust_golang` - Rust + Go systems programming

## GitHub Actions: Build timeout

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

## GitHub Actions: Rate limit exceeded

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

## Security scanning fails

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
```

## Image pull fails in CI

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
