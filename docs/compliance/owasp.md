# OWASP Docker Top 10 Compliance

This document maps the container build system's security controls to the
[OWASP Docker Top 10](https://owasp.org/www-project-docker-top-10/) security
risks.

## Summary

**Overall Coverage: 8/10 controls fully addressed**

| Risk | Status      | Summary                                   |
| ---- | ----------- | ----------------------------------------- |
| D01  | ✅ Complete | Non-root user by default                  |
| D02  | ✅ Complete | Weekly auto-patch workflow                |
| D03  | ⚠️ Examples | Network policy examples provided          |
| D04  | ✅ Complete | Security-hardened defaults                |
| D05  | ⚠️ Partial  | Documentation for AppArmor/SELinux needed |
| D06  | ✅ Complete | Gitleaks scanning, no embedded secrets    |
| D07  | ⚠️ Examples | Resource limit examples provided          |
| D08  | ✅ Complete | GPG/Sigstore signatures, checksums        |
| D09  | ✅ Complete | Read-only filesystem support              |
| D10  | ✅ Complete | JSON logging available                    |

## Detailed Control Mapping

### D01: Secure User Mapping

**Status: ✅ Complete**

**Risk**: Running containers as root gives attackers elevated privileges if they
escape the container.

**Implementation**:

- Non-root user created by default (`lib/base/create-user.sh`)
- Configurable via `USERNAME`, `USER_UID`, `USER_GID` build args
- Passwordless sudo disabled in production (`ENABLE_PASSWORDLESS_SUDO=false`)

**Verification**:

```bash
docker run --rm your-image id
# Expected: uid=1000(vscode) gid=1000(vscode) groups=1000(vscode)
```

**Files**: `lib/base/create-user.sh`

---

### D02: Patch Management Strategy

**Status: ✅ Complete**

**Risk**: Outdated packages contain known vulnerabilities.

**Implementation**:

- Weekly auto-patch GitHub Actions workflow
- All tool versions pinned in `lib/versions.sh`
- `bin/check-versions.sh` to identify outdated versions
- `bin/update-versions.sh` for automated updates
- Trivy scanning in CI for vulnerability detection

**Verification**:

```bash
# Check for outdated versions
./bin/check-versions.sh --json

# Run vulnerability scan
trivy image --severity HIGH,CRITICAL your-image
```

**Files**: `.github/workflows/auto-patch.yml`, `lib/versions.sh`

---

### D03: Network Segmentation and Firewalling

**Status: ⚠️ Examples Provided**

**Risk**: Unrestricted network access enables lateral movement.

**Implementation**:

- Network policies are environment-specific (not container responsibility)
- Examples provided in `examples/kubernetes/`
- Documentation on implementing network segmentation

**Required Action**:

```yaml
# Example NetworkPolicy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

**Files**: `examples/kubernetes/network-policies/`

---

### D04: Secure Defaults and Hardening

**Status: ✅ Complete**

**Risk**: Insecure defaults expose unnecessary attack surface.

**Implementation**:

- Minimal base image (`debian:bookworm-slim`)
- Only essential packages installed
- Unnecessary services disabled
- Secure file permissions
- Read-only root filesystem support
- No SETUID/SETGID binaries where possible

**Verification**:

```bash
# Check for SETUID binaries
docker run --rm your-image find / -perm /6000 -type f 2>/dev/null
```

---

### D05: Maintain Security Contexts

**Status: ⚠️ Partial**

**Risk**: Missing security contexts allow privilege escalation.

**Implementation**:

- Non-root user enforced
- `securityContext` examples provided
- AppArmor/SELinux profiles documented but not enforced

**Required Action**:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
```

**Gap**: Need to provide default AppArmor/SELinux profiles.

---

### D06: Protect Secrets

**Status: ✅ Complete**

**Risk**: Secrets embedded in images or exposed in logs.

**Implementation**:

- Gitleaks scanning in CI pipeline
- No secrets embedded in images
- Secret mounting via environment variables or volumes
- 1Password CLI support (`INCLUDE_OP=true`)

**Verification**:

```bash
# Scan for secrets
gitleaks detect --source . --verbose

# Check image for embedded secrets
trivy image --scanners secret your-image
```

**Files**: `.gitleaks.toml`, `.github/workflows/ci.yml`

---

### D07: Resource Protection

**Status: ⚠️ Examples Provided**

**Risk**: Resource exhaustion enables denial of service.

**Implementation**:

- Resource limit examples in documentation
- Not enforced at container level (orchestrator responsibility)

**Required Action**:

```yaml
resources:
  limits:
    cpu: '2'
    memory: '4Gi'
  requests:
    cpu: '500m'
    memory: '1Gi'
```

See [Production Checklist](production-checklist.md#resource-configuration).

---

### D08: Container Image Integrity and Origin

**Status: ✅ Complete**

**Risk**: Tampered images introduce malicious code.

**Implementation**:

- GPG signature verification for tools
- Sigstore/Cosign signatures for released images
- SHA256 checksum verification
- Pinned versions prevent supply chain attacks

**Verification**:

```bash
# Verify image signature
cosign verify \
  --certificate-identity-regexp='^https://github.com/joshjhall/containers' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/joshjhall/containers:your-variant
```

**Files**: `lib/base/signature-verify.sh`, `lib/base/checksum-verification.sh`

---

### D09: Immutable Container Filesystems

**Status: ✅ Complete**

**Risk**: Writable filesystems allow runtime modification.

**Implementation**:

- Read-only root filesystem support
- Writable volumes mounted as needed (`/tmp`, `/cache`)
- Application data in volumes, not container layer

**Usage**:

```yaml
securityContext:
  readOnlyRootFilesystem: true
volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: cache
    mountPath: /cache
```

---

### D10: Logging

**Status: ✅ Complete**

**Risk**: Insufficient logging prevents incident detection.

**Implementation**:

- JSON logging available (`ENABLE_JSON_LOGGING=true`)
- Build-time logging with configurable verbosity (`LOG_LEVEL`)
- Application logs to stdout/stderr for aggregation

**Usage**:

```bash
--build-arg ENABLE_JSON_LOGGING=true
```

**Files**: `lib/base/logging.sh`, `lib/observability/json-logging.sh`

---

## Implementation Priorities

### Immediate Actions (Complete)

1. ✅ Use non-root user
2. ✅ Enable Gitleaks scanning
3. ✅ Verify image signatures
4. ✅ Enable JSON logging for production

### Short-term Actions (Deployment Team)

1. Apply network policies
2. Set resource limits
3. Configure read-only root filesystem
4. Enable audit logging

### Medium-term Actions (Platform Team)

1. Create AppArmor/SELinux profiles
2. Implement OPA Gatekeeper policies
3. Deploy Falco for runtime monitoring

## Related Documentation

- [Production Checklist](production-checklist.md)
- [Framework Analysis](../reference/compliance.md)
- [Security Checksums](../reference/security-checksums.md)
