# Network Issues

This section covers network-related build and runtime failures, including
download problems, proxy configuration, and security verification issues.

## Cannot download packages during build

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

## GitHub API rate limit exceeded

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

## Proxy issues

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

## Security & Download Issues

### Checksum verification failure

**Symptom**: Build fails with checksum mismatch error during tool download.

```text
Error: Checksum verification failed
Expected: abc123...
Got:      def456...
```

**Cause**: The downloaded file doesn't match the expected checksum. This could
indicate:

1. Network corruption during download
1. Tool maintainer updated the file without updating the checksum
1. Potential supply chain attack (rare but serious)

**Solution**:

1. **First, retry the build** (network corruption is common):

   ```bash
   docker build --no-cache .
   ```

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
   - See `SECURITY.md` for reporting procedures

**Related Files**:

- `lib/base/download-verify.sh` - Core verification logic
- `lib/base/checksum-fetch.sh` - Checksum fetching utilities
- `docs/reference/security-checksums.md` - Complete implementation guide

### GPG signature verification failure

**Symptom**: Build fails when verifying GPG signatures.

```text
gpg: BAD signature from "Tool Maintainer <email@example.com>"
Error: GPG verification failed
```

**Cause**: Downloaded package signature doesn't match the GPG key.

**Solution**:

1. **AWS CLI verification** (uses GPG signatures):

   ```bash
   # Check the GPG fingerprint being used
   grep -A 5 "AWS_CLI_GPG_FINGERPRINT" lib/features/aws.sh

   # Verify against official AWS documentation
   # https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
   ```

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

```text
Error: download_and_verify failed
Error: calculate_checksum_sha256 failed
```

**Cause**: The download verification utilities encountered an error.

**Common Issues**:

1. **URL unreachable**:

   ```bash
   # Test the URL manually
   curl -I https://example.com/tool.tar.gz

   # Check DNS resolution
   docker run --rm debian:trixie-slim nslookup example.com
   ```

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

```bash
# Enable verbose logging in the feature script
# Add this temporarily to see detailed output:
set -x

# Check build logs for the failing feature
docker build --progress=plain . 2>&1 | grep -A 20 "download_and_verify"
```

**Related Files**:

- `lib/base/download-verify.sh` - Core download verification functions
- `lib/base/checksum-fetch.sh` - Checksum fetching from GitHub releases

### Checksum fetch failures (GitHub releases)

**Symptom**: Build fails when fetching checksums from GitHub releases.

```text
Error: Failed to fetch checksum for tool 1.2.3
```

**Cause**: Cannot retrieve checksum file from GitHub release page.

**Solution**:

1. **GitHub API rate limiting**:

   ```bash
   # Check your rate limit
   curl -H "Authorization: token $GITHUB_TOKEN" \
     https://api.github.com/rate_limit

   # Add GitHub token to build
   docker build --build-arg GITHUB_TOKEN=$GITHUB_TOKEN .
   ```

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

- `lib/base/checksum-fetch.sh` - GitHub checksum fetching logic

### Security best practices

When encountering download or verification issues:

1. Always investigate checksum failures — Don't disable verification
1. Verify the source — Check official documentation for checksums/signatures
1. Use published checksums when available (more trustworthy than calculated)
1. Report persistent failures — May indicate upstream issues
1. Never skip verification — Even for "trusted" sources
1. Never hardcode checksums — Breaks version flexibility

**Supply Chain Security**:

- All downloads use SHA256 verification (as of v4.5.0)
- See `docs/reference/security-checksums.md` for complete audit
- See `docs/security-hardening.md` for roadmap
