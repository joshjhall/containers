# Python Release Signing Keys

This directory contains GPG public keys used to verify Python release
signatures.

## Current Release Managers

### Thomas Wouters (3.12.x and 3.13.x)

- **Key ID**: A821E680E5FA6305
- **Source**: https://github.com/Yhg1s.gpg
- **Used for**: Python 3.12.x and 3.13.x source files and tags

### Pablo Galindo Salgado (3.10.x and 3.11.x)

- **Key ID**: 64E628F8D684696D
- **Fingerprint**: a035c8c19219ba821ecea86b64e628f8d684696d
- **Source**: https://keybase.io/pablogsal/pgp_keys.asc
- **Used for**: Python 3.10.x and 3.11.x source files and tags

### Łukasz Langa (3.8.x and 3.9.x)

- **Key ID**: B26995E310250568
- **Fingerprint**: e3ff2839c048b25c084debe9b26995e310250568
- **Source**: https://keybase.io/ambv/pgp_keys.asc
- **Used for**: Python 3.8.x and 3.9.x source files and tags

## Key Management

Keys are stored in this directory and imported during build time for GPG
signature verification.

To update keys:

1. Download the public key from the source URL
2. Verify the fingerprint matches the documented fingerprint
3. Save as `<manager-name>.asc` in this directory
4. Update this README with any changes

## Signature Verification

Python release tarballs include `.asc` signature files:

- Example: `Python-3.12.7.tar.gz.asc`
- Download from:
  `https://www.python.org/ftp/python/{version}/Python-{version}.tar.gz.asc`

## References

- Official Documentation: https://www.python.org/downloads/metadata/pgp/
- Sigstore (Python 3.11.0+): https://www.python.org/downloads/metadata/sigstore/
- PEP 761: Deprecating PGP signatures (Python 3.14+):
  https://peps.python.org/pep-0761/

## Note

Python 3.14 and later will use Sigstore signing exclusively. This GPG
infrastructure supports Python versions up to 3.13.
