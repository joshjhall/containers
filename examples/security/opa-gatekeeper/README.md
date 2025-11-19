# OPA Gatekeeper Policy Enforcement

This directory contains OPA Gatekeeper configurations for automated security
policy enforcement at deployment time, supporting compliance requirements for
SOC 2, HIPAA, PCI DSS, GDPR, and FedRAMP.

## Compliance Coverage

| Framework    | Requirement                   | Policy Enforcement              |
| ------------ | ----------------------------- | ------------------------------- |
| SOC 2 CC6.1  | Logical access controls       | Block privileged, root, host NS |
| SOC 2 CC6.6  | System boundary protection    | Resource limits, network policy |
| ISO 27001    | A.14.2 Secure development     | Image provenance, health checks |
| HIPAA        | 164.312(a)(1) Access controls | Encryption labels, data class   |
| PCI DSS 1.3  | Network segmentation          | NetworkPolicy requirements      |
| PCI DSS 2.2  | Configuration standards       | Security context enforcement    |
| GDPR Art. 25 | Data protection by design     | Trusted registries, no latest   |
| FedRAMP CM-7 | Least functionality           | Drop capabilities, no root      |

## Files

| File                        | Description                      |
| --------------------------- | -------------------------------- |
| constraint-templates.yaml   | Rego policy definitions          |
| constraints-compliance.yaml | Policy instances with parameters |

## Quick Start

### 1. Install Gatekeeper

```bash
# Using kubectl
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.14.0/deploy/gatekeeper.yaml

# Or using Helm
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts
helm install gatekeeper/gatekeeper --name-template=gatekeeper --namespace gatekeeper-system --create-namespace
```

### 2. Apply Constraint Templates

```bash
kubectl apply -f constraint-templates.yaml

# Verify templates are ready
kubectl get constrainttemplates
```

### 3. Apply Constraints

```bash
# Review and customize constraints first
kubectl apply -f constraints-compliance.yaml

# Verify constraints
kubectl get constraints
```

### 4. Test Enforcement

```bash
# This should be DENIED in production namespace
kubectl run test-privileged --image=nginx --privileged -n production
# Error: Privileged container 'test-privileged' is not allowed. SOC 2 CC6.1 violation.

# This should be DENIED (no resource limits)
kubectl run test-nolimits --image=nginx -n production
# Error: Container 'test-nolimits' must have CPU limits. SOC 2 CC6.6 requires resource controls.
```

## Policy Catalog

### Security Policies

| Policy                   | Description                      | Compliance     |
| ------------------------ | -------------------------------- | -------------- |
| BlockPrivilegedContainer | Prevents privileged containers   | SOC 2, PCI DSS |
| BlockRootUser            | Prevents running as UID 0        | SOC 2, FedRAMP |
| BlockHostNamespace       | Prevents hostPID/IPC/Network     | SOC 2, PCI DSS |
| RequireSecurityContext   | Enforces read-only FS, drop caps | SOC 2, FedRAMP |

### Resource Policies

| Policy                | Description                        | Compliance |
| --------------------- | ---------------------------------- | ---------- |
| RequireResourceLimits | Enforces CPU/memory limits         | SOC 2      |
| RequireHealthChecks   | Enforces liveness/readiness probes | SOC 2      |

### Image Policies

| Policy          | Description                     | Compliance    |
| --------------- | ------------------------------- | ------------- |
| BlockLatestTag  | Prevents :latest tag usage      | GDPR, FedRAMP |
| TrustedRegistry | Allows only approved registries | GDPR, FedRAMP |

### Data Protection Policies

| Policy                 | Description                        | Compliance |
| ---------------------- | ---------------------------------- | ---------- |
| RequireHIPAAEncryption | Requires encryption labels for PHI | HIPAA      |
| RequireNetworkPolicy   | Requires NetworkPolicy for PCI     | PCI DSS    |

## Enforcement Actions

Gatekeeper supports three enforcement actions:

| Action   | Behavior                                              |
| -------- | ----------------------------------------------------- |
| `deny`   | Block non-compliant resources (production)            |
| `warn`   | Allow but warn in audit log (staging)                 |
| `dryrun` | Log violations without blocking (development/testing) |

### Recommended Rollout Strategy

1. **Week 1**: Deploy with `dryrun` mode across all namespaces
2. **Week 2**: Review violations, update applications
3. **Week 3**: Switch to `warn` mode in staging
4. **Week 4**: Enable `deny` mode in production

## Customization

### Adding Namespace Exceptions

```yaml
spec:
  match:
    excludedNamespaces:
      - 'kube-system'
      - 'your-exception-namespace'
```

### Modifying Trusted Registries

```yaml
parameters:
  registries:
    - 'gcr.io/your-project/'
    - 'your-private-registry.com/'
```

### Adding HIPAA Namespaces

```yaml
parameters:
  hipaaNamespaces:
    - 'healthcare-app'
    - 'phi-processing'
```

## Monitoring Violations

### View Current Violations

```bash
# Get constraint status
kubectl get constraints -o wide

# Detailed violations for a specific constraint
kubectl describe k8sblockprivilegedcontainer block-privileged-production
```

### Prometheus Metrics

Gatekeeper exposes metrics at `/metrics`:

```promql
# Total violations by constraint
sum by (constraint_name) (gatekeeper_violations)

# Violations by enforcement action
sum by (enforcement_action) (gatekeeper_violations)

# Audit duration
histogram_quantile(0.99, sum(rate(gatekeeper_audit_duration_seconds_bucket[5m])) by (le))
```

### Alert Rules

```yaml
groups:
  - name: gatekeeper
    rules:
      - alert: GatekeeperViolations
        expr: increase(gatekeeper_violations[1h]) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: 'High number of Gatekeeper policy violations'

      - alert: GatekeeperAuditFailure
        expr: gatekeeper_audit_last_run_time < (time() - 3600)
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Gatekeeper audit hasn't run in over an hour"
```

## Violation Remediation

### Privileged Container Violation

**Error**: `Privileged container 'X' is not allowed. SOC 2 CC6.1 violation.`

**Fix**: Remove privileged flag or add specific capabilities:

```yaml
securityContext:
  privileged: false # Remove this line
  capabilities:
    add: ['NET_ADMIN'] # Add only needed caps
```

### Missing Resource Limits

**Error**: `Container 'X' must have CPU limits`

**Fix**: Add resource limits:

```yaml
resources:
  limits:
    cpu: '500m'
    memory: '512Mi'
  requests:
    cpu: '100m'
    memory: '128Mi'
```

### Latest Tag Violation

**Error**: `Container 'X' uses :latest tag`

**Fix**: Specify exact version:

```yaml
image: nginx:1.25.3 # Not nginx:latest
```

### HIPAA Encryption Violation

**Error**: `HIPAA workload must have 'encryption' label`

**Fix**: Add required labels:

```yaml
metadata:
  labels:
    encryption: 'aes-256-gcm'
    data-classification: 'phi'
```

### Root User Violation

**Error**: `Container 'X' runs as root (UID 0)`

**Fix**: Set non-root user:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
```

### Security Context Violation

**Error**: `Container must drop ALL capabilities`

**Fix**: Add security context:

```yaml
securityContext:
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE # Only if needed
```

## CI/CD Integration

### Pre-deployment Validation

Use `conftest` to validate manifests before deployment:

```bash
# Install conftest
brew install conftest

# Test manifests
conftest test deployment.yaml --policy policies/

# In CI pipeline
- name: Policy Check
  run: |
    conftest test k8s/*.yaml --policy policies/ --output json
```

### GitOps Workflow

```yaml
# .github/workflows/policy-check.yaml
name: Policy Validation
on: [pull_request]
jobs:
  gatekeeper-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install gator
        run: |
          curl -L https://github.com/open-policy-agent/gatekeeper/releases/download/v3.14.0/gator-v3.14.0-linux-amd64.tar.gz | tar xz
          mv gator /usr/local/bin/
      - name: Verify constraints
        run: |
          gator verify policies/...
      - name: Test manifests
        run: |
          gator test manifests/*.yaml
```

## Troubleshooting

### Constraint Not Enforcing

1. Check if template is installed:

   ```bash
   kubectl get constrainttemplates
   ```

1. Check constraint status:

   ```bash
   kubectl describe <constraint-kind> <constraint-name>
   ```

1. Verify webhook is running:

   ```bash
   kubectl get pods -n gatekeeper-system
   ```

### Audit Not Running

```bash
# Check audit configuration
kubectl get config.config.gatekeeper.sh -o yaml

# Trigger manual audit
kubectl annotate config.config.gatekeeper.sh config gatekeeper.sh/audit=run
```

### Performance Issues

```yaml
# Increase webhook timeout
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: gatekeeper-validating-webhook-configuration
webhooks:
  - name: validation.gatekeeper.sh
    timeoutSeconds: 10 # Increase from default 3
```

## Related Documentation

- [Falco Runtime Security](../../observability/runtime-security/README.md)
- [OPA Gatekeeper Docs](https://open-policy-agent.github.io/gatekeeper/website/docs/)
- [Gatekeeper Library](https://github.com/open-policy-agent/gatekeeper-library)
- [Rego Language](https://www.openpolicyagent.org/docs/latest/policy-language/)
