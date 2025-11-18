# Compliance Documentation

This directory contains security compliance documentation for the container
build system. Use these resources to understand how the system aligns with
various compliance frameworks and how to deploy securely.

## Quick Start

1. **Understand compliance coverage**: Read the
   [Framework Analysis](../reference/compliance.md)
2. **Prepare for production**: Follow the
   [Production Security Checklist](production-checklist.md)
3. **Choose your framework**: Use the framework-specific guides below

## Document Overview

| Document                                         | Purpose                           |
| ------------------------------------------------ | --------------------------------- |
| [Framework Analysis](../reference/compliance.md) | Comprehensive coverage analysis   |
| [Production Checklist](production-checklist.md)  | Pre-deployment security checklist |
| [OWASP Docker Top 10](owasp.md)                  | Container-specific security       |
| [SOC 2](soc2.md)                                 | Service organization controls     |

## Framework Coverage Summary

**Current Coverage: 60-70%** across major frameworks

### Strengths

- **Supply Chain Security (9.5/10)**: GPG signatures, Sigstore verification,
  pinned checksums
- **Image Security**: Trivy scanning, Gitleaks secret detection, SBOM generation
- **Access Control**: Non-root user by default, configurable sudo
- **Reproducible Builds**: Version pinning, declarative configuration

### Common Gaps

These gaps are intentionally left to the deploying organization:

- **Audit Logging**: Runtime concern - implement with Falco, Loki, etc.
- **Network Policies**: Environment-specific - examples provided in
  `examples/kubernetes/`
- **Backup/DR**: Infrastructure concern - outside container scope
- **MFA**: Authentication system concern - not container responsibility

## How to Use This Documentation

### For Auditors

1. Review the [Framework Analysis](../reference/compliance.md) for control
   mappings
2. Check specific framework sections (OWASP, SOC 2, ISO 27001, etc.)
3. Note which controls are build-time vs runtime responsibilities

### For DevOps Teams

1. Complete the [Production Checklist](production-checklist.md) before
   deployment
2. Implement runtime controls (network policies, monitoring, etc.)
3. Document your implementation for audit purposes

### For Security Teams

1. Review gap analysis and prioritize based on your framework requirements
2. Use the checklist to verify deployments
3. Implement additional runtime security (Falco, OPA Gatekeeper, etc.)

## Compliance by Framework

### OWASP Docker Top 10

The container system addresses 8 of 10 OWASP Docker security risks out of the
box. See [owasp.md](owasp.md) for detailed mapping.

**Key Controls:**

- D01: Non-root user mapping ✅
- D04: Secure defaults ✅
- D06: Secret protection (Gitleaks) ✅
- D08: Image integrity (signatures) ✅

### SOC 2 Trust Services Criteria

Strong coverage for Security and Availability principles. See [soc2.md](soc2.md)
for detailed mapping.

**Key Controls:**

- CC6.1: Logical access controls ✅
- CC6.8: Malware prevention ✅
- CC7.1: Configuration management ✅
- CC7.3: Vulnerability management ✅

### ISO 27001:2022

Good alignment with Annex A controls for secure development. See
[Framework Analysis](../reference/compliance.md#iso-270012022).

### HIPAA Security Rule

Partial coverage - requires additional runtime controls for full compliance. See
[Framework Analysis](../reference/compliance.md#hipaa-security-rule).

### PCI DSS v4.0

Strong secure development practices. Network and encryption controls need
environment-specific implementation. See
[Framework Analysis](../reference/compliance.md#pci-dss-v40).

### GDPR

Data protection by design principles are followed. Privacy impact assessments
and breach notification are organizational responsibilities. See
[Framework Analysis](../reference/compliance.md#gdpr-eu-data-protection).

## Evidence Collection

For audit evidence, document the following:

### Build-Time Evidence

- CI/CD pipeline logs showing security scans
- Trivy vulnerability reports
- SBOM (Software Bill of Materials)
- Signature verification logs
- Pre-commit hook configurations

### Runtime Evidence

- Container health check results
- Resource utilization metrics
- Network policy configurations
- Security event logs (Falco, audit logs)
- Backup verification records

## Getting Help

- **Questions**: Open a GitHub issue with the `compliance` label
- **Contributions**: PRs welcome for additional framework mappings
- **Updates**: Compliance docs are updated with each release

## Related Documentation

- [Security Checksums](../reference/security-checksums.md) - Supply chain
  security details
- [Environment Variables](../reference/environment-variables.md) - Security
  configuration options
- [Healthcheck Documentation](../healthcheck.md) - Container health monitoring
