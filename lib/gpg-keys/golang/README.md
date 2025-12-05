# Go (Golang) GPG Keys

This directory contains GPG public keys used to verify Go binary releases.

## Google Linux Packages Signing Authority

### Key Information

- **Key ID**: D38B4796
- **Fingerprint**: `EB4C 1BFD 4F04 2F6D DDCC EC91 7721 F63B D38B 4796`
- **UID**: Google Inc. (Linux Packages Signing Authority)
  <linux-packages-keymaster@google.com>
- **Source**: `https://dl.google.com/linux/linux_signing_key.pub`
- **Created**: 2016-04-12

### Products Verified with This Key

This key is used to sign:

- Go (Golang) binary releases
- Google Chrome packages
- Google Cloud SDK packages
- Other Google Linux software packages

## Signature Verification

Go binary releases include `.asc` signature files that can be verified using
this key.

### Verification Process

1. Download Go binary (e.g., `go1.23.4.linux-amd64.tar.gz`)
1. Download signature file (e.g., `go1.23.4.linux-amd64.tar.gz.asc`)
1. Import GPG key: `gpg --import google-linux-signing-key.asc`
1. Verify signature:
   `gpg --verify go1.23.4.linux-amd64.tar.gz.asc go1.23.4.linux-amd64.tar.gz`

The signature verification is handled automatically by the
`download_and_verify_golang_gpg()` function in `lib/base/signature-verify.sh`.

## Key Updates

To update the Google signing key:

```bash
./bin/update-gpg-keys.sh
```

This will:

- Download the latest key from Google's official source
- Verify the key fingerprint matches the expected value
- Update the key in this directory
- Set appropriate permissions (700 for directory, 600 for key file)

### Manual Update

```bash
# Download the key
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
  -o lib/gpg-keys/golang/keys/google-linux-signing-key.asc

# Verify fingerprint
gpg --with-colons --show-keys \
  lib/gpg-keys/golang/keys/google-linux-signing-key.asc | \
  awk -F: '/^fpr:/ {print $10; exit}'

# Expected: EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796

# Set permissions
chmod 700 lib/gpg-keys/golang/keys
chmod 600 lib/gpg-keys/golang/keys/google-linux-signing-key.asc
```

## Security Considerations

- Always verify the key fingerprint after downloading
- The key is stored with restrictive permissions (600)
- The key directory has restrictive permissions (700)
- Only import keys from official Google sources
- This key is used for all Google Linux packages, not just Go

## References

- Go Downloads: `https://go.dev/dl/`
- Google Linux Signing Key: `https://dl.google.com/linux/linux_signing_key.pub`
- Go Security Policy: `https://go.dev/security/policy`
