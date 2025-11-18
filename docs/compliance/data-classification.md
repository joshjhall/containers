# Data Classification and Handling Procedures

This document defines data classification taxonomy and handling procedures for
containers processing sensitive data.

## Compliance Coverage

| Framework       | Requirement           | Status   |
| --------------- | --------------------- | -------- |
| GDPR Art. 9     | Special category data | Guidance |
| HIPAA §164.312  | ePHI protection       | Guidance |
| PCI DSS 3.x     | Cardholder data       | Guidance |
| SOC 2 C1        | Confidentiality       | Guidance |
| ISO 27001 A.8.2 | Information labeling  | Guidance |

---

## Classification Taxonomy

### Level 1: Public

**Definition**: Information intended for public access.

**Examples**:

- Public documentation
- Marketing materials
- Open source code
- Public APIs

**Handling**:

- No encryption required
- No access restrictions
- No special container requirements

---

### Level 2: Internal

**Definition**: Information for internal use, not intended for public
disclosure.

**Examples**:

- Internal documentation
- Development configurations
- Non-sensitive metrics
- Team communications

**Handling**:

- Encryption in transit required
- Authentication required
- Standard container security

**Container Requirements**:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
```

---

### Level 3: Confidential

**Definition**: Sensitive business information requiring protection.

**Examples**:

- Customer data (non-PII)
- Financial reports
- Business strategies
- Vendor contracts

**Handling**:

- Encryption at rest and in transit
- Role-based access control
- Audit logging required
- Data retention policies

**Container Requirements**:

```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

**Pod Labels**:

```yaml
metadata:
  labels:
    data-classification: confidential
    audit-logging: required
```

---

### Level 4: Restricted

**Definition**: Highly sensitive data requiring maximum protection.

**Examples**:

- PII (Personally Identifiable Information)
- PHI (Protected Health Information)
- PAN (Payment Card Numbers)
- Authentication credentials
- Encryption keys

**Handling**:

- Strong encryption at rest (AES-256)
- Encryption in transit (TLS 1.3)
- Strict access control (need-to-know)
- Complete audit trail
- Data minimization
- Retention limits enforced

**Container Requirements**:

```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop:
      - ALL
```

**Pod Labels**:

```yaml
metadata:
  labels:
    data-classification: restricted
    audit-logging: required
    encryption: required
    pii-present: 'true'
```

---

## Kubernetes Enforcement

### Namespace Labels

Label namespaces by maximum data classification allowed:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    data-classification-max: restricted
    pod-security.kubernetes.io/enforce: restricted
```

### OPA Gatekeeper Policies

#### Require Classification Label

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: requireclassification
spec:
  crd:
    spec:
      names:
        kind: RequireClassification
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package requireclassification

        violation[{"msg": msg}] {
          not input.review.object.metadata.labels["data-classification"]
          msg := "Pods must have a data-classification label"
        }
```

#### Enforce Restricted Data Controls

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: restricteddatacontrols
spec:
  crd:
    spec:
      names:
        kind: RestrictedDataControls
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package restricteddatacontrols

        violation[{"msg": msg}] {
          input.review.object.metadata.labels["data-classification"] == "restricted"
          not input.review.object.spec.containers[_].securityContext.readOnlyRootFilesystem
          msg := "Restricted data containers must use read-only root filesystem"
        }

        violation[{"msg": msg}] {
          input.review.object.metadata.labels["data-classification"] == "restricted"
          input.review.object.spec.containers[_].securityContext.privileged
          msg := "Restricted data containers cannot run as privileged"
        }
```

---

## Data Handling Procedures

### Data Discovery

Identify and classify data in containers:

```bash
# Scan for potential PII patterns
grep -r -E '\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b' /app  # SSN
grep -r -E '\b[0-9]{16}\b' /app                     # Credit card
grep -r -E '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b' /app  # Email
```

### Data Minimization

Only collect and store data that is necessary:

1. Review data collection requirements
2. Remove unnecessary data fields
3. Implement data masking where possible
4. Use tokenization for sensitive identifiers

### Data Encryption

**At Rest**:

- See [Encryption at Rest](encryption-at-rest.md)
- Use encrypted volumes for Confidential/Restricted data
- Encrypt database fields containing PII

**In Transit**:

- Enforce TLS 1.2+ for all connections
- Use mTLS for service-to-service communication
- Disable insecure protocols

### Data Retention

| Classification | Default Retention | Notes                    |
| -------------- | ----------------- | ------------------------ |
| Public         | Indefinite        | Archive as appropriate   |
| Internal       | 3 years           | Purge after business use |
| Confidential   | 7 years           | Per legal requirements   |
| Restricted     | As required       | Minimize retention       |

Implement automated deletion:

```yaml
# Example: CronJob for data cleanup
apiVersion: batch/v1
kind: CronJob
metadata:
  name: data-retention-cleanup
spec:
  schedule: '0 2 * * *'
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: cleanup
              image: ghcr.io/joshjhall/containers:python-dev
              command:
                - python
                - /scripts/cleanup-expired-data.py
```

---

## Access Control

### Role-Based Access by Classification

| Role            | Public | Internal | Confidential | Restricted |
| --------------- | ------ | -------- | ------------ | ---------- |
| Public Users    | ✓      | ✗        | ✗            | ✗          |
| Employees       | ✓      | ✓        | ✗            | ✗          |
| Team Members    | ✓      | ✓        | ✓            | ✗          |
| Data Custodians | ✓      | ✓        | ✓            | ✓          |

### Kubernetes RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: restricted-data-access
  namespace: production
rules:
  - apiGroups: ['']
    resources: ['pods']
    verbs: ['get', 'list']
    resourceNames: [] # Specific pods only
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: restricted-data-access
  namespace: production
subjects:
  - kind: User
    name: data-custodian@example.com
roleRef:
  kind: Role
  name: restricted-data-access
  apiGroup: rbac.authorization.k8s.io
```

---

## Audit Requirements

### By Classification Level

| Classification | Audit Requirement      | Retention |
| -------------- | ---------------------- | --------- |
| Public         | None                   | N/A       |
| Internal       | Access logs            | 90 days   |
| Confidential   | All access + changes   | 1 year    |
| Restricted     | All activity + exports | 7 years   |

### Audit Log Content

For Confidential/Restricted data:

```json
{
  "timestamp": "2025-01-15T10:30:00Z",
  "user": "user@example.com",
  "action": "read",
  "resource": "customer-data",
  "classification": "restricted",
  "pod": "api-server-abc123",
  "namespace": "production",
  "success": true,
  "data_fields_accessed": ["email", "phone"]
}
```

---

## Compliance Mapping

### GDPR Requirements

- **Article 5**: Data minimization, accuracy, storage limitation
- **Article 9**: Special category data (health, biometric, etc.)
- **Article 32**: Security measures appropriate to risk
- **Article 35**: DPIA for high-risk processing

### HIPAA Requirements

- **§164.312(a)**: Access controls for ePHI
- **§164.312(b)**: Audit controls
- **§164.312(c)**: Data integrity
- **§164.312(e)**: Transmission security

### PCI DSS Requirements

- **3.4**: Render PAN unreadable
- **3.5**: Protect cryptographic keys
- **7.1**: Limit access to cardholder data
- **10.x**: Track and monitor all access

---

## Implementation Checklist

### Initial Setup

- [ ] Define classification taxonomy for your organization
- [ ] Create namespace labels for data classifications
- [ ] Deploy OPA Gatekeeper policies
- [ ] Configure RBAC for data access
- [ ] Set up audit logging

### Ongoing

- [ ] Regular data discovery scans
- [ ] Quarterly access reviews
- [ ] Annual classification review
- [ ] Retention policy enforcement
- [ ] Audit log reviews

---

## Related Documentation

- [Encryption at Rest](encryption-at-rest.md)
- [Production Checklist](production-checklist.md)
- [SOC 2 Compliance](soc2.md)
- [Incident Response](incident-response.md)
