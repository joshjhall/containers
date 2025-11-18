# TLS/mTLS Configuration Examples

This directory contains examples for enforcing encryption in transit for
container deployments.

## Compliance Coverage

| Framework    | Requirement                  | Implementation           |
| ------------ | ---------------------------- | ------------------------ |
| GDPR Art. 32 | Encryption of personal data  | TLS/mTLS for all traffic |
| HIPAA        | Transmission security        | Encrypted service mesh   |
| PCI DSS 4.1  | Strong cryptography          | TLS 1.2+, strong ciphers |
| SOC 2 CC6.7  | Encryption in transit        | cert-manager + Istio     |
| FedRAMP SC-8 | Transmission confidentiality | mTLS between services    |

## Files

| File              | Description                      |
| ----------------- | -------------------------------- |
| cert-manager.yaml | Automated certificate management |
| istio-mtls.yaml   | Service mesh mTLS configuration  |

## Quick Start

### Option 1: cert-manager (Certificate Management)

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=300s

# Apply certificate configuration
kubectl apply -f cert-manager.yaml
```

### Option 2: Istio Service Mesh (mTLS)

```bash
# Install Istio
istioctl install --set profile=default

# Enable sidecar injection
kubectl label namespace default istio-injection=enabled

# Apply mTLS configuration
kubectl apply -f istio-mtls.yaml
```

## Certificate Rotation

### Automatic Rotation (Recommended)

cert-manager automatically rotates certificates before expiry:

```yaml
spec:
  duration: 2160h # 90 days
  renewBefore: 360h # Renew 15 days before expiry
```

### Manual Rotation

```bash
# Force certificate renewal
kubectl delete secret app-tls-secret -n default

# cert-manager will automatically recreate the certificate
kubectl get certificate app-tls -n default -w
```

### Monitoring Expiry

```bash
# Check certificate expiry
kubectl get certificates -A

# Detailed certificate status
kubectl describe certificate app-tls -n default
```

## Verification

### Verify TLS Configuration

```bash
# Check Ingress TLS
kubectl get ingress app-ingress -o jsonpath='{.spec.tls}'

# Verify certificate is valid
openssl s_client -connect app.example.com:443 -servername app.example.com < /dev/null 2>/dev/null | openssl x509 -noout -dates
```

### Verify mTLS (Istio)

```bash
# Check PeerAuthentication
kubectl get peerauthentication -A

# Verify mTLS is enabled
istioctl x authz check <pod-name>

# Check traffic encryption
istioctl proxy-config cluster <pod-name> | grep STRICT
```

### Test Encryption

```bash
# From inside the mesh, this should work
kubectl exec -it <pod-name> -c istio-proxy -- curl https://app:443

# From outside the mesh (without sidecar), this should fail
kubectl run test --image=curlimages/curl --rm -it --restart=Never -- curl http://app:8080
```

## Minimum TLS Version

Enforce TLS 1.2 minimum:

### Ingress Controller (nginx)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-configuration
  namespace: ingress-nginx
data:
  ssl-protocols: TLSv1.2 TLSv1.3
  ssl-ciphers: ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
```

### Istio

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: tls-version
  namespace: istio-system
spec:
  configPatches:
    - applyTo: CLUSTER
      patch:
        operation: MERGE
        value:
          transport_socket:
            typed_config:
              '@type': type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
              common_tls_context:
                tls_params:
                  tls_minimum_protocol_version: TLSv1_2
```

## Troubleshooting

### Certificate Not Issued

```bash
# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

# Check certificate status
kubectl describe certificate <name> -n <namespace>

# Check certificate request
kubectl get certificaterequest -A
```

### mTLS Connection Refused

```bash
# Check sidecar injection
kubectl get pods -o jsonpath='{.items[*].spec.containers[*].name}' | tr ' ' '\n' | grep istio

# Check peer authentication
kubectl get peerauthentication -A

# Debug proxy configuration
istioctl proxy-status
istioctl analyze
```

## Integration with Production Checklist

Add to your deployment process:

1. **Pre-deployment**: Verify cert-manager is installed
2. **Deployment**: Apply TLS configuration
3. **Post-deployment**: Verify certificates are valid
4. **Monitoring**: Alert on certificate expiry < 14 days

```bash
# Add to CI/CD pipeline
kubectl get certificate -A -o json | jq '.items[] | select(.status.notAfter | fromdateiso8601 < (now + 1209600)) | .metadata.name'
```

## Related Documentation

- [Production Checklist](../PRODUCTION-CHECKLIST.md)
- [Encryption at Rest](../../../docs/compliance/encryption-at-rest.md)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Istio Security](https://istio.io/latest/docs/concepts/security/)
