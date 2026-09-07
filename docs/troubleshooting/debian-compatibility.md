# Debian Version Compatibility

This section covers issues related to Debian version differences and how the
build system handles them across Debian 12 (Bookworm) and 13 (Trixie).

## Debian 11 (Bullseye) — removed

**Debian 11 is no longer supported.** It was dropped from the tested matrix
after its LTS security support ended on **2026-08-31** (#933).

**Symptom if you try it anyway**: the build dies configuring packages whose
downloads 404'd:

```text
404  Not Found [IP: 146.75.30.132 80]
Err:67 http://deb.debian.org/debian-security bullseye-security/main amd64 gnupg all 2.2.27-2+deb11u3

locales depends on libc-l10n (>> 2.31); however:
  Package libc-l10n is not installed.
E: Sub-process /usr/bin/dpkg returned an error code (1)
```

**Cause**: as the `bullseye-security` suite is retired, package versions age
out of the mirror. The `dpkg` dependency errors are a downstream symptom — apt
could not fetch the packages, so their dependencies were never installed. This
does not clear on a rerun, and it worsens over time as more packages are
dropped.

**Why we did not repoint to `archive.debian.org`**: the archive receives no
security updates, so that leg would verify a base nobody should deploy. We
would rather stop asserting support we cannot deliver.

**Migration**: rebuild on `debian:bookworm-slim` (Debian 12) or
`debian:trixie-slim` (Debian 13, the default).

## apt-key command not found (Terraform, Google Cloud, Kubernetes)

**Symptom**: Build fails with `apt-key: command not found` when installing
Terraform, Google Cloud SDK, or Kubernetes tools.

```text
bash: line 1: apt-key: command not found
✗ Adding HashiCorp GPG key failed with exit code 127
```

**Cause**: Debian 13 (Trixie) and later removed the deprecated `apt-key`
command. The build system automatically detects your Debian version and uses the
appropriate method.

**Solution**: This is automatically handled as of v4.0.1.
`add_apt_repository_key()` in `lib/base/apt-repository.sh` branches on
`is_debian_version 12`:

- **Debian 12+ (Bookworm, Trixie, and later)**: Uses the modern `signed-by` GPG
  method — this is every supported version.
- **Below Debian 12**: Uses the legacy `apt-key` method. With Debian 11
  dropped (#933) nothing reaches this branch; it is retained only as a floor
  for any older base someone supplies via `BASE_IMAGE`.

**If you're on an older version of this container system**:

1. Update to the latest version:

   ```bash
   cd containers
   git pull origin main
   cd ..
   git add containers
   git commit -m "Update container build system"
   ```

1. Or manually patch the affected files:

   - `lib/features/terraform.sh`
   - `lib/features/gcloud.sh`
   - `lib/features/kubernetes.sh`

   See commit `b955fc3` for the fix implementation.

**Verification**:

```bash
# Check your Debian version
cat /etc/debian_version

# Rebuild and verify
docker build --build-arg INCLUDE_TERRAFORM=true -t test:terraform .
docker run --rm test:terraform terraform version
```

## Base image mismatch with Debian Trixie

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
```

## Package not available in Trixie

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
```

## Writing Debian-Compatible Feature Scripts

**Pattern**: When creating or updating feature installation scripts, use the
Debian version detection system to ensure compatibility across Debian 12
and 13.

### Debian Version Detection Functions

The build system provides three functions in `lib/base/apt-utils.sh`:

1. **`get_debian_major_version()`** - Returns the major version number (11, 12,
   or 13)
1. **`is_debian_version <min>`** - Checks if current version >= minimum
1. **`apt_install_conditional <min> <max> <packages...>`** - Install packages
   only on specific versions

### Usage Examples

#### Example 1: Install packages only on specific Debian versions

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
```

#### Example 2: Conditional logic for installation methods

```bash
source /tmp/build-scripts/base/apt-utils.sh

if ! is_debian_version 12; then
    # Old method, for a pre-Bookworm base
    log_message "Using apt-key method (below Debian 12)"
    curl -fsSL https://example.com/key.gpg | apt-key add -
    apt-add-repository "deb https://example.com/apt stable main"
else
    # New method for Debian 12+
    log_message "Using signed-by method (Debian 12+)"
    curl -fsSL https://example.com/key.gpg | gpg --dearmor -o /usr/share/keyrings/example-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/example-keyring.gpg] https://example.com/apt stable main" > /etc/apt/sources.list.d/example.list
fi
```

#### Example 3: Check version before applying workarounds

```bash
source /tmp/build-scripts/base/apt-utils.sh

if is_debian_version 13; then
    # Trixie-specific workaround
    log_message "Applying Debian 13+ configuration..."
    # Your Trixie-specific code
fi
```

### Package Migration Reference

Common package changes between Debian versions:

| Package        | Debian 12    | Debian 13+ | Notes                                   |
| -------------- | ------------ | ---------- | --------------------------------------- |
| lzma, lzma-dev | Available    | Removed    | Use liblzma-dev (works on all versions) |
| apt-key        | Available    | Removed    | Use signed-by method instead            |

### Testing Your Changes

When adding version-specific logic:

1. **Test locally with different base images**:

   ```bash
   # Test Debian 12
   docker build --build-arg BASE_IMAGE=debian:bookworm-slim \
                --build-arg INCLUDE_YOUR_FEATURE=true -t test:debian12 .

   # Test Debian 13
   docker build --build-arg BASE_IMAGE=debian:trixie-slim \
                --build-arg INCLUDE_YOUR_FEATURE=true -t test:debian13 .
   ```

1. **CI automatically tests all supported versions**: The GitHub Actions
   workflow includes a `debian-version-test` job that tests Python and cloud
   tools on Debian 12 and 13. It runs `fail-fast: false`, so one failing
   version does not cancel the others.

### Design Philosophy

- **Backwards Compatible**: Always support Debian 12 unless absolutely
  necessary
- **Forward Compatible**: Prefer methods that work on Debian 13+ when possible
- **Graceful Degradation**: Use version detection, don't assume availability
- **Explicit Detection**: Check for command/package availability, don't rely on
  version alone
- **Document Changes**: Add comments explaining why version-specific code exists
