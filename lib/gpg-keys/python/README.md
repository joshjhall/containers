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

## Directory Structure

```
lib/gpg-keys/python/
├── keys/                   # Individual GPG key files (permissions: 700)
│   ├── thomas-wouters.asc # Python 3.12.x, 3.13.x (permissions: 600)
│   ├── pablo-galindo.asc  # Python 3.10.x, 3.11.x (permissions: 600)
│   └── lukasz-langa.asc   # Python 3.8.x, 3.9.x  (permissions: 600)
└── README.md              # This file
```

## Key Management

Keys are stored in the `keys/` subdirectory and imported during build time for
GPG signature verification.

To update keys:

1. Download the public key from the source URL
2. Verify the fingerprint matches the documented fingerprint
3. Save as `<manager-name>.asc` in the `keys/` directory with 600 permissions
4. Ensure the `keys/` directory has 700 permissions
5. Update this README with any changes

**Automated Updates**: Run `bin/update-gpg-keys.sh python` to fetch the latest
keys from official sources.

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
