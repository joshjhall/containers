# Production Deployment Security Checklist

Use this checklist before deploying containers to production environments. Each
item includes the relevant compliance frameworks it addresses.

## Pre-Deployment Checklist

### Container Build Configuration

- [ ] **Disable passwordless sudo**

  ```bash
  --build-arg ENABLE_PASSWORDLESS_SUDO=false
  ```

  _Frameworks: OWASP D01, SOC 2 CC6.1, ISO 27001 A.8.2, HIPAA §164.312(a)_

- [ ] **Enable JSON logging for log aggregation**

  ```bash
  --build-arg ENABLE_JSON_LOGGING=true
  ```

  _Frameworks: SOC 2 CC7.2, ISO 27001 A.8.16, HIPAA §164.312(b), PCI DSS 10.x_

- [ ] **Use minimal base image**

  ```bash
  --build-arg BASE_IMAGE=debian:trixie-slim
  ```

  _Frameworks: OWASP D04, CIS Docker Benchmark 4.1_

- [ ] **Pin all version numbers**
  - Verify PYTHON_VERSION, NODE_VERSION, etc. are explicitly set
  - Check that Dockerfile uses specific tags, not `latest`

  _Frameworks: SOC 2 CC7.1, ISO 27001 A.8.9_

### Security Scanning

- [ ] **Run Trivy vulnerability scan**

  ```bash
  trivy image --severity CRITICAL,HIGH your-image:tag
  ```

  - No CRITICAL vulnerabilities with available fixes
  - Document accepted risks for unfixed vulnerabilities

  _Frameworks: OWASP D02, SOC 2 CC7.3, ISO 27001 A.8.8, PCI DSS 6.3_

- [ ] **Verify image signatures**

  ```bash
  cosign verify \
    --certificate-identity-regexp='^https://github.com/joshjhall/containers' \
    --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
    ghcr.io/joshjhall/containers:your-variant
  ```

  _Frameworks: OWASP D08, SOC 2 CC6.8, ISO 27001 A.8.24_

- [ ] **Review SBOM (Software Bill of Materials)**
  - Download SBOM from CI artifacts
  - Review for unexpected or outdated components
  - Archive for compliance records

  _Frameworks: NIST SP 800-218, Executive Order 14028_

- [ ] **Run secret scanning**

  ```bash
  gitleaks detect --source . --verbose
  ```

  _Frameworks: OWASP D06, SOC 2 CC6.1, PCI DSS 3.4_

### Resource Configuration

- [ ] **Set CPU limits**

  ```yaml
  resources:
    limits:
      cpu: '2'
    requests:
      cpu: '500m'
  ```

  _Frameworks: OWASP D07, SOC 2 A1.1_

- [ ] **Set memory limits**

  ```yaml
  resources:
    limits:
      memory: '4Gi'
    requests:
      memory: '1Gi'
  ```

  _Frameworks: OWASP D07, SOC 2 A1.1_

- [ ] **Configure storage limits**

  ```yaml
  resources:
    limits:
      ephemeral-storage: '10Gi'
  ```

- [ ] **Apply namespace-level limits** (recommended)

  See
  [Resource Limits Examples](../../examples/kubernetes/base/resource-limits.yaml)
  for LimitRange and ResourceQuota templates with sizing guidelines.

  _Frameworks: OWASP D07, SOC 2 A1.1, CIS Kubernetes Benchmark 5.2_

### Health Monitoring

- [ ] **Configure health checks**

  ```yaml
  livenessProbe:
    exec:
      command: ['healthcheck', '--quick']
    initialDelaySeconds: 60
    periodSeconds: 30
  readinessProbe:
    exec:
      command: ['healthcheck', '--quick']
    initialDelaySeconds: 30
    periodSeconds: 10
  ```

  _Frameworks: SOC 2 A1.2, ISO 27001 A.8.14_

- [ ] **Set up custom health checks** (if needed)
  - Add scripts to `/etc/healthcheck.d/`
  - Test with `healthcheck --verbose`

### Data Protection

- [ ] **Enable encryption in transit**
  - Configure TLS for all service endpoints
  - Use cert-manager or similar for certificate management
  - Enforce minimum TLS 1.2

  _Frameworks: HIPAA §164.312(e), PCI DSS 4.1, GDPR Art. 32_

- [ ] **Document encryption at rest**
  - Persistent volumes use encrypted storage classes
  - Database connections use TLS
  - Secrets are stored in encrypted secret management (Vault, AWS SM, etc.)

  _Frameworks: HIPAA §164.312(a), PCI DSS 3.4, GDPR Art. 32_

- [ ] **Configure log retention**
  - Security logs: minimum 90 days (PCI DSS requires 1 year online)
  - Audit logs: per compliance requirements
  - Set up log rotation to prevent disk exhaustion

  _Frameworks: PCI DSS 10.7, HIPAA §164.312(b), SOC 2 CC7.2_

## Kubernetes-Specific Checklist

### Pod Security

- [ ] **Apply Pod Security Standards**

  ```yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: production
    labels:
      pod-security.kubernetes.io/enforce: restricted
      pod-security.kubernetes.io/audit: restricted
      pod-security.kubernetes.io/warn: restricted
  ```

  _Frameworks: OWASP D04, CIS Kubernetes Benchmark 5.2_

- [ ] **Set security context**

  ```yaml
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  ```

  _Frameworks: OWASP D01/D05/D09, CIS Docker Benchmark 5.x_

### Network Security

- [ ] **Configure network policies**

  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny-all
  spec:
    podSelector: {}
    policyTypes:
      - Ingress
      - Egress
  ```

  Then add specific allow rules. _Frameworks: OWASP D03, SOC 2 CC6.6, PCI DSS
  1.x_

- [ ] **Set up ingress with TLS**

  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: 'true'
  spec:
    tls:
      - hosts:
          - your-app.example.com
        secretName: tls-secret
  ```

### Access Control

- [ ] **Configure RBAC**
  - Create service accounts for each application
  - Apply least privilege principle
  - Avoid cluster-admin role for applications

  _Frameworks: SOC 2 CC6.1, ISO 27001 A.5.15, HIPAA §164.312(a)_

- [ ] **Enable audit logging**

  ```yaml
  apiVersion: audit.k8s.io/v1
  kind: Policy
  rules:
    - level: Metadata
      resources:
        - group: ''
          resources: ['secrets', 'configmaps']
  ```

  _Frameworks: SOC 2 CC7.2, ISO 27001 A.8.16, HIPAA §164.312(b)_

### Policy Enforcement

- [ ] **Deploy OPA Gatekeeper** (recommended)
  - Enforce allowed registries
  - Require resource limits
  - Block privileged containers
  - Enforce labels/annotations

  _Frameworks: SOC 2 CC8.1, ISO 27001 A.8.9_

### Runtime Security

- [ ] **Deploy Falco** (recommended)

  ```yaml
  apiVersion: helm.toolkit.fluxcd.io/v2beta1
  kind: HelmRelease
  metadata:
    name: falco
  spec:
    chart:
      spec:
        chart: falco
        sourceRef:
          kind: HelmRepository
          name: falcosecurity
  ```

  _Frameworks: SOC 2 CC7.2, ISO 27001 A.8.16, NIST CSF DE.CM-1_

### Logging and Monitoring

- [ ] **Set up log aggregation**
  - Deploy Loki, Elasticsearch, or cloud provider solution
  - Configure JSON log parsing
  - Set up dashboards for security events

  _Frameworks: SOC 2 CC7.2, ISO 27001 A.8.16, PCI DSS 10.x_

- [ ] **Configure alerting**
  - Container restarts
  - Health check failures
  - Security events (Falco alerts)
  - Resource exhaustion

  _Frameworks: SOC 2 CC7.3, ISO 27001 A.8.16_

## Post-Deployment Verification

### Immediate Checks

- [ ] **Verify health checks pass**

  ```bash
  kubectl exec -it <pod> -- healthcheck --verbose
  ```

- [ ] **Confirm resource limits are enforced**

  ```bash
  kubectl describe pod <pod> | grep -A5 Limits
  ```

- [ ] **Validate network policies**

  ```bash
  # Test that unauthorized connections are blocked
  kubectl exec -it <pod> -- curl -v <blocked-service>
  ```

- [ ] **Check security context**

  ```bash
  kubectl exec -it <pod> -- id
  # Should show uid=1000, not root
  ```

### Ongoing Monitoring

- [ ] **Set up vulnerability scanning schedule**
  - Daily: Trivy scans of running images
  - Weekly: Full SBOM review
  - Monthly: Compliance posture review

- [ ] **Configure backup verification**
  - Test restore procedures
  - Document RTO/RPO
  - Schedule regular restore tests

  _Frameworks: SOC 2 A1.2, ISO 27001 A.8.13, HIPAA §164.308(a)(7)_

- [ ] **Review security events**
  - Check Falco alerts daily
  - Review audit logs weekly
  - Investigate anomalies promptly

- [ ] **Test incident response**
  - Conduct tabletop exercises quarterly
  - Test alerting and escalation paths
  - Update runbooks based on findings

  _Frameworks: SOC 2 CC7.4, ISO 27001 A.5.24, HIPAA §164.308(a)(6)_

## Documentation Requirements

For audit purposes, maintain records of:

- [ ] Build configurations (docker-compose.yml, Kubernetes manifests)
- [ ] Security scan results (Trivy reports, SBOM)
- [ ] Network policy configurations
- [ ] RBAC role bindings
- [ ] Change management records
- [ ] Incident response procedures
- [ ] Backup/restore test results

## Sign-Off

| Role            | Name | Date | Signature |
| --------------- | ---- | ---- | --------- |
| DevOps Engineer |      |      |           |
| Security        |      |      |           |
| Change Manager  |      |      |           |

---

## Quick Reference

### Minimum Production Build Command

```bash
docker build \
  -f containers/Dockerfile \
  --build-arg PROJECT_NAME=myapp \
  --build-arg BASE_IMAGE=debian:trixie-slim \
  --build-arg ENABLE_PASSWORDLESS_SUDO=false \
  --build-arg ENABLE_JSON_LOGGING=true \
  --build-arg INCLUDE_PYTHON_DEV=true \
  -t myapp:prod \
  .
```

### Compliance Quick Check

```bash
# Scan for vulnerabilities
trivy image --severity CRITICAL,HIGH myapp:prod

# Verify signature
cosign verify --certificate-identity-regexp=... myapp:prod

# Test health check
docker run --rm myapp:prod healthcheck --verbose

# Check user is non-root
docker run --rm myapp:prod id
```

## See Also

- [Compliance Framework Analysis](../reference/compliance.md)
- [Healthcheck Documentation](../healthcheck.md)
- [Security Checksums](../reference/security-checksums.md)
- [examples/kubernetes/](../../examples/kubernetes/) - Kubernetes deployment
  examples
