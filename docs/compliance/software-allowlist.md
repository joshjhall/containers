# Software Allowlist and Version Control Catalog

This document defines the approved software allowlist for container builds,
addressing compliance requirements for authorized software control.

## Compliance Coverage

| Framework           | Requirement                   | Status    |
| ------------------- | ----------------------------- | --------- |
| CMMC CM.L2-3.4.7    | Authorized software           | Compliant |
| FedRAMP CM-7(5)     | Authorized software allowlist | Compliant |
| NIST 800-53 CM-7(5) | Authorized software           | Compliant |
| CIS Controls 2.5    | Software inventory            | Compliant |

______________________________________________________________________

## Approved Software Categories

### 1. Language Runtimes

All language runtimes are version-pinned and signature-verified.

| Software | Current Version | Source        | Verification |
| -------- | --------------- | ------------- | ------------ |
| Python   | 3.13.x          | python.org    | Sigstore/GPG |
| Node.js  | 22.x LTS        | nodejs.org    | GPG          |
| Go       | 1.23.x          | go.dev        | GPG          |
| Rust     | 1.82.x          | rust-lang.org | GPG          |
| Ruby     | 3.3.x           | ruby-lang.org | SHA256       |
| Java     | 21 LTS          | adoptium.net  | GPG          |
| R        | 4.4.x           | r-project.org | SHA256       |

**Version Policy**: Use latest stable/LTS version. Update weekly via auto-patch.

______________________________________________________________________

### 2. Base System Packages

Installed from Debian official repositories.

| Package         | Purpose              | Required |
| --------------- | -------------------- | -------- |
| bash            | Shell                | Yes      |
| curl            | HTTP client          | Yes      |
| wget            | File download        | Yes      |
| git             | Version control      | Yes      |
| ca-certificates | TLS root certs       | Yes      |
| gnupg           | GPG operations       | Yes      |
| openssh-client  | SSH client           | Yes      |
| sudo            | Privilege escalation | Yes      |
| locales         | Locale support       | Yes      |
| tzdata          | Timezone data        | Yes      |

**Version Policy**: Latest from Debian stable repository.

______________________________________________________________________

### 3. Build Dependencies

Required for compiling language extensions.

| Package         | Purpose             | Removed After Build |
| --------------- | ------------------- | ------------------- |
| build-essential | GCC, make, etc.     | Production only     |
| libssl-dev      | OpenSSL headers     | Production only     |
| libffi-dev      | FFI headers         | Production only     |
| zlib1g-dev      | Compression headers | Production only     |
| libbz2-dev      | BZ2 compression     | Production only     |
| libreadline-dev | Readline headers    | Production only     |
| libsqlite3-dev  | SQLite headers      | Production only     |
| libncurses5-dev | NCurses headers     | Production only     |
| libxml2-dev     | XML parsing         | Production only     |
| libxslt1-dev    | XSLT processing     | Production only     |

**Version Policy**: Latest from Debian stable. Removed in production builds.

______________________________________________________________________

### 4. Security Tools

| Tool     | Current Version | Purpose                | Verification |
| -------- | --------------- | ---------------------- | ------------ |
| cosign   | 2.x             | Sigstore verification  | Checksum     |
| trivy    | (CI only)       | Vulnerability scanning | N/A          |
| gitleaks | (CI only)       | Secret detection       | N/A          |

______________________________________________________________________

### 5. Cloud & Infrastructure CLIs

| Tool      | Current Version | Source        | Verification |
| --------- | --------------- | ------------- | ------------ |
| kubectl   | 1.31.x          | kubernetes.io | Sigstore     |
| helm      | 3.16.x          | helm.sh       | GPG          |
| terraform | 1.9.x           | hashicorp.com | GPG          |
| aws-cli   | 2.x             | AWS           | GPG          |
| gcloud    | Latest          | Google Cloud  | Checksum     |
| az        | Latest          | Microsoft     | Checksum     |

______________________________________________________________________

### 6. Development Tools

Version-pinned in feature scripts.

| Tool    | Current Version | Purpose              |
| ------- | --------------- | -------------------- |
| direnv  | 2.35.x          | Environment manager  |
| lazygit | 0.44.x          | Git TUI              |
| delta   | 0.18.x          | Git diff viewer      |
| mkcert  | 1.4.x           | Local TLS certs      |
| act     | 0.2.x           | Local GitHub Actions |

See [docs/reference/versions.md](../reference/versions.md) for complete list.

______________________________________________________________________

## Approval Process

### Adding New Software

1. **Request**: Open GitHub issue with:

   - Software name and version
   - Business justification
   - Security review (CVE history, maintenance status)
   - License compliance check

1. **Review**: Security team evaluates:

   - Attack surface increase
   - Dependency chain
   - Update/patch availability
   - Signature verification method

1. **Approval**: Requires sign-off from:

   - Project maintainer
   - Security lead (for tools with network access)

1. **Implementation**:

   - Add to feature script with version pinning
   - Implement verification (checksum/GPG/Sigstore)
   - Add to check-versions.sh for tracking
   - Update this allowlist

### Removing Software

1. Check for dependencies
1. Update deprecation in CHANGELOG
1. Remove from feature scripts
1. Update allowlist

______________________________________________________________________

## Version Control

### Pinning Strategy

| Category        | Strategy          | Rationale                       |
| --------------- | ----------------- | ------------------------------- |
| Languages       | Major.Minor.Patch | Reproducible builds             |
| Security tools  | Major.Minor       | Security fixes important        |
| Dev tools       | Major.Minor.Patch | Consistent developer experience |
| System packages | Latest stable     | Security patches                |

### Update Frequency

| Type           | Frequency | Method                  |
| -------------- | --------- | ----------------------- |
| Security fixes | Immediate | Manual update + release |
| Minor versions | Weekly    | Auto-patch workflow     |
| Major versions | Quarterly | Manual review + testing |

### Automated Updates

The auto-patch workflow (`bin/check-versions.sh`) checks for updates:

```bash
# Check for outdated versions
./bin/check-versions.sh

# Output as JSON
./bin/check-versions.sh --json

# Update versions
./bin/update-versions.sh versions.json
```

______________________________________________________________________

## Verification Methods

### GPG Signatures

```bash
# Example: Node.js
gpg --keyserver hkps://keys.openpgp.org --recv-keys <key_id>
gpg --verify SHASUMS256.txt.sig SHASUMS256.txt
```

### Sigstore/Cosign

```bash
# Example: kubectl
cosign verify-blob \
  --certificate kubectl.sig.cert \
  --signature kubectl.sig \
  --certificate-oidc-issuer https://accounts.google.com \
  kubectl
```

### SHA256 Checksums

```bash
# Example: Ruby
echo "<expected_hash>  ruby-<version>.tar.gz" | sha256sum -c -
```

______________________________________________________________________

## Audit Evidence

### Generate Current Allowlist

```bash
# Runtime check
docker run --rm <image> check-installed-versions.sh

# From Dockerfile
grep -E "^ARG.*_VERSION=" Dockerfile
```

### SBOM (Software Bill of Materials)

Generated in CI for each build:

- Format: CycloneDX JSON
- Location: CI artifacts
- Contains: All installed packages with versions

### Compliance Report

```bash
#!/bin/bash
# generate-compliance-report.sh

echo "=== Software Allowlist Compliance Report ==="
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "=== Pinned Versions ==="
./bin/check-versions.sh

echo ""
echo "=== Verification Status ==="
# Check GPG keys are valid
gpg --list-keys

echo ""
echo "=== SBOM Available ==="
ls -la sbom-*.json 2>/dev/null || echo "Run CI to generate SBOM"
```

______________________________________________________________________

## Non-Allowed Software

The following are explicitly **NOT allowed**:

| Software   | Reason                             |
| ---------- | ---------------------------------- |
| telnet     | Insecure protocol                  |
| ftp        | Insecure protocol                  |
| rsh/rlogin | Insecure protocols                 |
| nmap       | Not needed for container operation |
| netcat     | Potential security tool misuse     |

Exceptions require documented business justification and security review.

______________________________________________________________________

## Change Log

Track changes to the allowlist:

| Date       | Change                      | Approver   |
| ---------- | --------------------------- | ---------- |
| 2025-11-01 | Initial allowlist creation  | @joshjhall |
| 2025-11-15 | Added Sigstore verification | @joshjhall |

______________________________________________________________________

## Related Documentation

- [Version Tracking](../reference/versions.md) - Complete version list
- [Security Checksums](../reference/security-checksums.md) - Verification
  details
- [Auto-Patch Workflow](../operations/automated-releases.md) - Update process
