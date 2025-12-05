# Node.js Release Team GPG Keys

This directory contains the GPG keyring for verifying Node.js release
signatures.

## Directory Structure

```text
lib/gpg-keys/nodejs/
├── keyring/                    # GPG keyring directory (permissions: 700)
│   ├── pubring.kbx            # Public keys (permissions: 600)
│   └── trustdb.gpg            # Trust database (permissions: 600)
├── keyring-metadata.json       # Keyring provenance and metadata
├── update-keyring.sh           # Script to update keyring from official source
└── README.md                   # This file
```

## Keyring Coverage

The keyring contains GPG keys for **all Node.js release team members** (both
active and historical), supporting verification of:

- **Current releases** (latest major/minor/patch versions)
- **LTS releases** (all active LTS lines)
- **Historical releases** (older versions that may still be in use)

**Important**: This is a single, unified keyring that works across all Node.js
versions. Any Node.js release can be signed by any active releaser at the time
of that release, so we maintain a complete keyring with all current and
historical release team members' keys.

## Source

The keyring is sourced from the official Node.js release-keys repository:

- **Repository**: `https://github.com/nodejs/release-keys`
- **Last Updated**: See `keyring-metadata.json` for commit hash and date
- **Total Keys**: 28 (8 active releasers + 20 historical releasers)

### Active Releasers

- Antoine du Hamel
- Juan José Arboleda
- Marco Ippolito
- Michaël Zasso
- Rafael Gonzaga
- Richard Lau
- Ruy Adorno
- Ulises Gascón

## Usage

These keys are used by `lib/base/signature-verify.sh` to verify GPG signatures
on Node.js release tarballs downloaded from `https://nodejs.org/dist/`.

### Verification Process

Node.js releases include two signature file formats:

- `SHASUMS256.txt.sig` - Binary GPG signature
- `SHASUMS256.txt.asc` - ASCII-armored GPG signature

The verification workflow:

1. Download the Node.js tarball and SHASUMS256.txt file
1. Download either the .sig or .asc signature file
1. Verify the signature using the keyring in this directory
1. Check the tarball's SHA256 checksum against SHASUMS256.txt

## Updating the Keyring

### Manual Update

```bash
./bin/update-gpg-keys.sh
```

This script:

1. Clones the official nodejs/release-keys repository
1. Copies the full keyring (including historical keys)
1. Sets secure permissions (700 for directory, 600 for files)
1. Generates updated metadata with commit hash and date
1. Lists all keys for verification

### Automated Update

The keyring should be updated when:

- **New Node.js major/minor versions are released** (may have new releasers)
- **New patch versions are released** (could be signed by different team
  members)
- **Release team membership changes** (new members join or keys are rotated)

**Integration with version automation**:

- The `bin/check-versions.sh` script can call `update-keyring.sh` when new
  Node.js versions are detected
- The `bin/update-versions.sh` script can update the keyring as part of the
  version update process
- This ensures GPG keys are refreshed whenever we update Node.js version pins

### Update Frequency

**Recommended**: Check for keyring updates whenever new Node.js versions are
detected by the automated version checking system. This ensures we always have
the latest release team keys.

**Minimum**: Update when new major/minor Node.js versions are released.

## Security Considerations

### Permissions

- Keyring directory: `700` (drwx------) - Only owner can access
- Keyring files: `600` (-rw-------) - Only owner can read/write
- This prevents unauthorized modification or reading of the keyring

### Verification Chain

1. **Source Trust**: Keys are fetched from the official nodejs/release-keys
   repository
1. **Git Integrity**: Repository is cloned via HTTPS with certificate
   verification
1. **Metadata Tracking**: We record the exact commit hash and date of the source
1. **Reproducibility**: Anyone can verify our keyring matches the official
   source

### Cross-Reference

The release team members can be cross-referenced with:

- `https://github.com/nodejs/node#release-keys`
- `https://github.com/nodejs/node/blob/main/README.md#release-keys`
- Individual GPG key fingerprints on `https://nodejs.org`

## Troubleshooting

### Signature Verification Fails

1. **Check keyring is up to date**: Run
   `./lib/gpg-keys/nodejs/update-keyring.sh`
1. **Verify release team membership**: Check if the signer is in the official
   release-keys repo
1. **Check signature file**: Ensure you're using SHASUMS256.txt.sig or .asc from
   the official dist server

### Updating Keyring from Specific Commit

To fetch keys from a specific commit of the release-keys repository:

```bash
cd /tmp
git clone https://github.com/nodejs/release-keys.git
cd release-keys
git checkout <commit-hash>
cp gpg/pubring.kbx <containers-repo>/lib/gpg-keys/nodejs/keyring/
cp gpg/trustdb.gpg <containers-repo>/lib/gpg-keys/nodejs/keyring/
chmod 700 <containers-repo>/lib/gpg-keys/nodejs/keyring
chmod 600 <containers-repo>/lib/gpg-keys/nodejs/keyring/*
```

## References

- Official Node.js release keys: `https://github.com/nodejs/release-keys`
- Node.js security information: `https://nodejs.org/en/about/security/`
- Node.js downloads: `https://nodejs.org/dist/`
- GPG signature verification guide:
  `https://github.com/nodejs/node#verifying-binaries`
