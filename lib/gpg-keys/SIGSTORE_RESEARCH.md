# Sigstore Support Research (November 2025)

This document summarizes Sigstore availability for language runtime downloads.

## Summary

Only **Python** provides official Sigstore signatures for runtime downloads.
Other languages use alternative verification methods.

## By Language

### Python ✓

- **Status**: Official Sigstore support
- **Versions**: 3.11.0+ (with backports to 3.10.7, 3.9.14, 3.8.14, 3.7.14)
- **Files**: `.sigstore` bundle files alongside tarballs
- **Tool**: Can use `cosign` or `python -m sigstore verify`
- **Future**: Python 3.14+ will use Sigstore exclusively (PGP deprecated per
  PEP 761)
- **GPG**: Available for all versions through 3.13.x

### Node.js ✗

- **Status**: No Sigstore for runtime downloads
- **Note**: Sigstore available for npm packages, but not for Node.js binaries
- **Alternative**: Direct binary download with SHA256SUMS
- **GPG**: Not widely used for Node.js runtime downloads

### Rust ✗

- **Status**: No official Sigstore support
- **Note**: RFC proposed but closed due to time constraints
- **Alternative**: SHA256 checksums published
- **GPG**: PGP signatures available via rust-key@rust-lang.org

### Ruby ✗

- **Status**: No Sigstore for runtime downloads
- **Note**: sigstore-ruby gem exists for RubyGems, not runtime
- **Alternative**: SHA256/SHA512 checksums
- **GPG**: Not standard for Ruby runtime downloads

### Go ✗

- **Status**: Uses checksum database instead
- **Alternative**: Go checksum database (sum.golang.org) + reproducible builds
- **GPG**: Not used; Go relies on transparency logs

### Java ✗

- **Status**: No Sigstore for OpenJDK binaries
- **Note**: Maven Central supports Sigstore for artifacts, not JDK binaries
- **Alternative**: Vendor-specific .sig files (Red Hat, Microsoft)
- **GPG**: Traditional GPG/PGP signatures from vendors

## Implementation Strategy

Given this research, our 4-tier verification system will implement:

### Tier 1: Signature Verification

- Python 3.11.0+: Try Sigstore first, fallback to GPG
- Python < 3.11.0: GPG only
- All other languages: GPG only (where available)
- Graceful fallback to Tier 2 if unavailable/fails

**Tier 2-4**: Remain unchanged (pinned checksums, published checksums,
calculated checksums)

## Tools Required

- `cosign`: Standalone Sigstore verification tool (Python)
- `gpg`: GNU Privacy Guard for GPG verification
- Both are optional - verification fails gracefully if unavailable

## References

- Python Sigstore: https://www.python.org/downloads/metadata/sigstore/
- Python PGP: https://www.python.org/downloads/metadata/pgp/
- PEP 761: https://peps.python.org/pep-0761/
- Sigstore: https://www.sigstore.dev/
