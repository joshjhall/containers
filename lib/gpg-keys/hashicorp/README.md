# HashiCorp Security GPG Key

This directory contains the GPG public key used to verify HashiCorp product
releases, including Terraform.

## HashiCorp Security Key

### Key Information

- **Key ID**: 72D7468F
- **Fingerprint**: `C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F`
- **Source**: `https://www.hashicorp.com/.well-known/pgp-key.txt`
- **UID**: HashiCorp Security (hashicorp.com/security) <security@hashicorp.com>
- **Valid**: 2021-04-19 to 2026-04-18
- **Used for**: Signing release checksums for all HashiCorp products

## Directory Structure

```text
lib/gpg-keys/hashicorp/
├── keys/                # GPG key files (permissions: 700)
│   └── hashicorp.asc   # HashiCorp Security public key (permissions: 600)
└── README.md           # This file
```

## Products Verified with This Key

- Terraform
- Vault
- Consul
- Nomad
- Packer
- Vagrant
- Waypoint
- Boundary

## Signature Verification Process

HashiCorp uses a signed checksums file pattern for verification:

1. Download the product binary (e.g., `terraform_1.10.0_linux_amd64.zip`)
1. Download the checksums file (`terraform_1.10.0_SHA256SUMS`)
1. Download the GPG signature (`terraform_1.10.0_SHA256SUMS.sig`)
1. Verify the signature of the checksums file using this GPG key
1. Verify the binary checksum matches the signed checksums file

### Example URLs

For Terraform 1.10.0:

- Binary:
  `https://releases.hashicorp.com/terraform/1.10.0/terraform_1.10.0_linux_amd64.zip`
- Checksums:
  `https://releases.hashicorp.com/terraform/1.10.0/terraform_1.10.0_SHA256SUMS`
- Signature:
  `https://releases.hashicorp.com/terraform/1.10.0/terraform_1.10.0_SHA256SUMS.sig`

## Updating the Key

### Automated Update

Run the update script to fetch the latest key from HashiCorp:

```bash
./bin/update-gpg-keys.sh hashicorp
```

The script will:

1. Download the key from `https://www.hashicorp.com/.well-known/pgp-key.txt`
1. Verify the key fingerprint matches the expected value
1. Save it to `keys/hashicorp.asc` with secure permissions (600)
1. Set directory permissions to 700

### Manual Update

If you need to update manually:

1. Download the public key:

   ```bash
   curl -fsSL https://www.hashicorp.com/.well-known/pgp-key.txt \
     -o lib/gpg-keys/hashicorp/keys/hashicorp.asc
   ```

1. Verify the fingerprint:

   ```bash
   gpg --show-keys --with-fingerprint \
     lib/gpg-keys/hashicorp/keys/hashicorp.asc
   ```

1. Confirm it matches: `C874 011F 0AB4 0511 0D02 1055 3436 5D94 72D7 468F`

1. Set secure permissions:

   ```bash
   chmod 700 lib/gpg-keys/hashicorp/keys
   chmod 600 lib/gpg-keys/hashicorp/keys/hashicorp.asc
   ```

1. Update this README if the key information changes

## Key Rotation

HashiCorp's current key expires in April 2026. Monitor
`https://www.hashicorp.com/security` for key rotation announcements.

When a new key is published:

- The update script will automatically fetch it
- Old signatures will remain valid for historical releases
- Both old and new keys may coexist during transition periods

## References

- **Official Key Page**: `https://www.hashicorp.com/security`
- **Key Download**: `https://www.hashicorp.com/.well-known/pgp-key.txt`
- **Security Policy**: `https://www.hashicorp.com/security`
- **Trust Signature Documentation**: `https://www.hashicorp.com/trust/security`
