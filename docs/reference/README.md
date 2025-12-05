# Reference Documentation

This directory contains technical reference documentation for configuration,
APIs, and system specifications.

## Available References

### Configuration

- [**Environment Variables**](environment-variables.md) - Complete list of build
  arguments and environment variables
- [**Feature Dependencies**](features.md) - Which tools depend on which other
  tools

### Versioning

- [**Version Tracking**](versions.md) - Which versions are pinned vs. latest,
  update policies
- [**Version Compatibility**](compatibility.md) - Compatibility matrix for
  language versions and platforms

### Security

- [**Security Checksums**](security-checksums.md) - Checksum verification system
  and cryptographic signatures

## Quick Reference

### Build Arguments

All features are controlled via `INCLUDE_<FEATURE>=true/false`:

**Languages**:

- `INCLUDE_PYTHON=true`
- `INCLUDE_NODE=true`
- `INCLUDE_RUST=true`
- `INCLUDE_GOLANG=true`
- `INCLUDE_RUBY=true`
- `INCLUDE_JAVA=true`
- `INCLUDE_R=true`
- `INCLUDE_MOJO=true`

**Development Tools**:

- `INCLUDE_PYTHON_DEV=true`
- `INCLUDE_NODE_DEV=true`
- `INCLUDE_DEV_TOOLS=true`

**Cloud & Infrastructure**:

- `INCLUDE_DOCKER=true`
- `INCLUDE_KUBERNETES=true`
- `INCLUDE_TERRAFORM=true`
- `INCLUDE_AWS=true`
- `INCLUDE_GCLOUD=true`

See [Environment Variables](environment-variables.md) for complete list.

### Version Control

```bash
# Check installed versions
check-installed-versions.sh

# Compare with expected versions
check-installed-versions.sh --compare

# Check for outdated versions
./bin/check-versions.sh

# Update versions from JSON
./bin/update-versions.sh versions.json
```

See [Version Tracking](versions.md) for version policies.

### Security Verification

All downloads are verified using a 4-tier progressive system:

1. **Tier 1**: Cryptographic signatures (GPG/Sigstore) - Best
1. **Tier 2**: Pinned checksums (lib/checksums.json) - Good
1. **Tier 3**: Published checksums (from official source) - Acceptable
1. **Tier 4**: Calculated checksums (TOFU fallback) - Last resort

See [Security Checksums](security-checksums.md) for complete details.

## For Users

When building containers:

1. Check [Environment Variables](environment-variables.md) for available options
1. Review [Version Compatibility](compatibility.md) for supported platforms
1. Consult [Feature Dependencies](features.md) to understand requirements

## For Contributors

When adding new features:

1. Document new build arguments in
   [Environment Variables](environment-variables.md)
1. Update [Feature Dependencies](features.md) if adding dependencies
1. Document version policies in [Version Tracking](versions.md)
1. Follow security guidelines in [Security Checksums](security-checksums.md)

## Related Documentation

- [Development](../development/) - How to contribute
- [Architecture](../architecture/) - Design decisions
- [Operations](../operations/) - Deployment and management
