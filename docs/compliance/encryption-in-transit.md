# Encryption in Transit

This document provides guidance for implementing encryption in transit for
container deployments to meet compliance requirements.

## Compliance Coverage

| Framework          | Requirement                        | Section        |
| ------------------ | ---------------------------------- | -------------- |
| GDPR               | Encryption of personal data        | Article 32     |
| HIPAA              | Transmission security              | §164.312(e)    |
| PCI DSS            | Strong cryptography for cardholder | Requirement 4  |
| SOC 2              | Encryption of data in transit      | CC6.7          |
| FedRAMP            | Transmission confidentiality       | SC-8           |
| ISO 27001          | Network security controls          | A.13.1         |

## Implementation Options

### Option 1: cert-manager (Automated TLS)

Best for: External-facing services, Ingress TLS termination

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Apply configuration
kubectl apply -f examples/kubernetes/tls/cert-manager.yaml
```

**Features:**

- Automated certificate issuance from Let's Encrypt
- Automatic renewal before expiry
- Support for internal CA for service-to-service TLS
- Integration with Ingress controllers

### Option 2: Istio Service Mesh (mTLS)

Best for: Service-to-service encryption, zero-trust architecture

```bash
# Install Istio
istioctl install --set profile=default

# Enable strict mTLS
kubectl apply -f examples/kubernetes/tls/istio-mtls.yaml
```

**Features:**

- Automatic mTLS between all services
- No application code changes required
- Fine-grained authorization policies
- Traffic observability

### Option 3: Linkerd Service Mesh

Best for: Lightweight mTLS, lower resource overhead

```bash
# Install Linkerd
linkerd install | kubectl apply -f -
linkerd inject deployment.yaml | kubectl apply -f -
```

## Minimum Requirements

### TLS Version

- **Minimum**: TLS 1.2
- **Recommended**: TLS 1.3

### Cipher Suites

Approved cipher suites (in order of preference):

```text
TLS_AES_256_GCM_SHA384
TLS_CHACHA20_POLY1305_SHA256
TLS_AES_128_GCM_SHA256
ECDHE-ECDSA-AES256-GCM-SHA384
ECDHE-RSA-AES256-GCM-SHA384
ECDHE-ECDSA-AES128-GCM-SHA256
ECDHE-RSA-AES128-GCM-SHA256
```

### Certificate Requirements

| Parameter       | Requirement                  |
| --------------- | ---------------------------- |
| Key Algorithm   | RSA 2048+ or ECDSA P-256+    |
| Validity Period | 90 days maximum              |
| Renewal Window  | 30 days before expiry        |
| Subject         | Proper CN/SAN for service    |

## Certificate Rotation

### Automated Rotation (Recommended)

cert-manager handles rotation automatically:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
spec:
  duration: 2160h      # 90 days
  renewBefore: 720h    # Renew 30 days before expiry
```

### Manual Rotation Process

1. Generate new certificate
2. Deploy new certificate alongside old
3. Update services to use new certificate
4. Remove old certificate
5. Document rotation in audit log

### Rotation Schedule

| Certificate Type     | Rotation Frequency | Lead Time   |
| -------------------- | ------------------ | ----------- |
| External TLS         | 90 days            | 30 days     |
| Internal mTLS        | 30 days            | 7 days      |
| Root CA              | 10 years           | 1 year      |
| Intermediate CA      | 2 years            | 6 months    |

## Verification

### Pre-Deployment Checklist

- [ ] TLS 1.2 minimum enforced
- [ ] Strong cipher suites configured
- [ ] Certificate validity < 90 days
- [ ] Automatic renewal configured
- [ ] Certificate monitoring enabled

### Runtime Verification

```bash
# Check TLS version
openssl s_client -connect service:443 -tls1_2

# Check certificate details
openssl s_client -connect service:443 < /dev/null 2>/dev/null | \
  openssl x509 -noout -subject -dates -issuer

# Check cipher in use
openssl s_client -connect service:443 < /dev/null 2>/dev/null | \
  grep "Cipher is"
```

### Istio mTLS Verification

```bash
# Check mTLS status
istioctl x authz check <pod-name>

# Verify strict mode
kubectl get peerauthentication -A -o yaml | grep -A2 "mtls:"
```

## Monitoring and Alerting

### Certificate Expiry Alerts

```yaml
# Prometheus alert rule
- alert: CertificateExpiringSoon
  expr: |
    certmanager_certificate_expiration_timestamp_seconds - time() < 1209600
  for: 1h
  labels:
    severity: warning
  annotations:
    summary: Certificate expiring in less than 14 days
```

### mTLS Failure Alerts

```yaml
- alert: mTLSConnectionFailure
  expr: |
    increase(istio_tcp_connections_closed_total{reporter="source",connection_security_policy!="mutual_tls"}[5m]) > 0
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: Non-mTLS connections detected
```

## Exceptions and Waivers

### Acceptable Exceptions

1. **Health check endpoints**: May use HTTP internally
2. **Metrics endpoints**: Prometheus scraping within mesh
3. **Legacy systems**: Documented migration plan required

### Exception Process

1. Document business justification
2. Implement compensating controls
3. Set expiration date (max 90 days)
4. Review and renew or remediate

## Audit Evidence

Collect and retain:

- Certificate issuance logs
- Rotation records
- TLS configuration snapshots
- Compliance scan results
- Exception documentation

### Evidence Collection Script

```bash
#!/bin/bash
# Collect TLS audit evidence

# Certificate inventory
kubectl get certificates -A -o yaml > certificates.yaml

# Certificate status
kubectl get certificaterequests -A -o yaml > cert-requests.yaml

# Istio mTLS configuration
kubectl get peerauthentication -A -o yaml > mtls-config.yaml

# Create evidence bundle
tar -czf tls-evidence-$(date +%Y%m%d).tar.gz *.yaml
```

## Troubleshooting

### Certificate Not Issued

```bash
# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check challenge status
kubectl describe challenge -A
```

### mTLS Connection Refused

```bash
# Verify sidecar injection
kubectl get pod -o jsonpath='{.spec.containers[*].name}'

# Check proxy configuration
istioctl proxy-config listener <pod-name>
```

### TLS Handshake Failure

```bash
# Debug TLS connection
openssl s_client -connect service:443 -debug -state

# Check supported protocols
nmap --script ssl-enum-ciphers -p 443 service
```

## Related Documentation

- [TLS Examples](../../examples/kubernetes/tls/)
- [Encryption at Rest](encryption-at-rest.md)
- [Production Checklist](production-checklist.md)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Istio Security](https://istio.io/latest/docs/concepts/security/)
