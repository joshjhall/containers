# Encryption at Rest Documentation

This document provides guidance on implementing encryption at rest for data
stored in containers and persistent volumes. It addresses requirements from
multiple compliance frameworks.

## Compliance Coverage

| Framework                | Requirement                       | Status   |
| ------------------------ | --------------------------------- | -------- |
| PCI DSS 3.4              | Render PAN unreadable             | Guidance |
| HIPAA §164.312(a)(2)(iv) | Encryption and decryption         | Guidance |
| FedRAMP SC-28            | Protection of information at rest | Guidance |
| CMMC SC.L2-3.13.16       | Protect confidentiality of CUI    | Guidance |
| GDPR Art. 32             | Appropriate technical measures    | Guidance |
| SOC 2 C1.1               | Protection of confidential info   | Guidance |

## Overview

Encryption at rest is an **environment-specific implementation** that depends on
your infrastructure. This container system provides guidance and best practices,
but the actual encryption must be configured in your deployment environment.

### Key Principles

1. **Never store sensitive data unencrypted** in container images or volumes
2. **Use platform-native encryption** when available (cloud provider, storage
   class)
3. **Implement proper key management** with rotation policies
4. **Verify encryption is enabled** before storing sensitive data
5. **Document your encryption implementation** for audit purposes

---

## Kubernetes Encrypted Storage

### StorageClass with Encryption

#### AWS EBS Encryption

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-gp3
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: 'true'
  # Optional: Use custom KMS key
  # kmsKeyId: arn:aws:kms:us-east-1:123456789012:key/abcd1234-...
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

#### GCP Persistent Disk Encryption

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-ssd
provisioner: pd.csi.storage.gke.io
parameters:
  type: pd-ssd
  # GCP encrypts by default; use CMEK for customer-managed keys
  disk-encryption-kms-key: projects/PROJECT/locations/REGION/keyRings/RING/cryptoKeys/KEY
volumeBindingMode: WaitForFirstConsumer
```

#### Azure Disk Encryption

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: encrypted-premium
provisioner: disk.csi.azure.com
parameters:
  skuName: Premium_LRS
  # Server-side encryption with customer-managed key
  diskEncryptionSetID: /subscriptions/SUB/resourceGroups/RG/providers/Microsoft.Compute/diskEncryptionSets/SET
volumeBindingMode: WaitForFirstConsumer
```

### Using Encrypted PersistentVolumeClaims

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: encrypted-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: encrypted-gp3 # Reference encrypted StorageClass
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
spec:
  template:
    spec:
      containers:
        - name: app
          image: ghcr.io/joshjhall/containers:python-dev
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: encrypted-data
```

---

## Docker Volume Encryption

### Using dm-crypt/LUKS (Linux)

For self-managed Docker environments, use LUKS encryption:

```bash
# Create encrypted volume (one-time setup)
sudo cryptsetup luksFormat /dev/sdb1
sudo cryptsetup luksOpen /dev/sdb1 encrypted_volume
sudo mkfs.ext4 /dev/mapper/encrypted_volume

# Mount for Docker use
sudo mkdir -p /mnt/encrypted
sudo mount /dev/mapper/encrypted_volume /mnt/encrypted

# Create Docker volume pointing to encrypted mount
docker volume create --driver local \
  --opt type=none \
  --opt device=/mnt/encrypted \
  --opt o=bind \
  encrypted_data

# Use in container
docker run -v encrypted_data:/data myimage
```

### Encrypted Docker Named Volumes

For cloud environments, use the volume driver's encryption:

```yaml
# docker-compose.yml
services:
  app:
    image: ghcr.io/joshjhall/containers:python-dev
    volumes:
      - encrypted_data:/data

volumes:
  encrypted_data:
    driver: local
    driver_opts:
      # Options depend on your storage backend
      type: nfs
      o: 'addr=nas.example.com,rw,sec=krb5p'
      device: ':/encrypted/share'
```

---

## Cloud Provider Integration

### AWS

#### EBS Default Encryption

Enable encryption by default for all new EBS volumes:

```bash
# Enable default encryption for the region
aws ec2 enable-ebs-encryption-by-default --region us-east-1

# Verify
aws ec2 get-ebs-encryption-by-default --region us-east-1
```

#### S3 Bucket Encryption

```bash
# Enable default encryption
aws s3api put-bucket-encryption \
  --bucket my-bucket \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "alias/my-key"
      }
    }]
  }'
```

#### RDS Encryption

```bash
# Create encrypted RDS instance
aws rds create-db-instance \
  --db-instance-identifier mydb \
  --storage-encrypted \
  --kms-key-id alias/my-key \
  ...
```

### GCP

#### Default Encryption

GCP encrypts all data at rest by default. For customer-managed encryption keys
(CMEK):

```bash
# Create KMS keyring and key
gcloud kms keyrings create my-keyring --location=global
gcloud kms keys create my-key --keyring=my-keyring --location=global --purpose=encryption

# Create disk with CMEK
gcloud compute disks create my-disk \
  --kms-key=projects/PROJECT/locations/global/keyRings/my-keyring/cryptoKeys/my-key
```

### Azure

#### Storage Account Encryption

```bash
# Create storage account with customer-managed key
az storage account create \
  --name mystorageaccount \
  --resource-group mygroup \
  --encryption-key-source Microsoft.Keyvault \
  --encryption-key-vault https://myvault.vault.azure.net \
  --encryption-key-name mykey
```

---

## Key Management Best Practices

### Key Rotation

Implement regular key rotation:

```yaml
# AWS KMS automatic rotation
aws kms enable-key-rotation --key-id alias/my-key

# Verify rotation
aws kms get-key-rotation-status --key-id alias/my-key
```

### HashiCorp Vault Integration

For centralized secrets and encryption key management:

```yaml
# Kubernetes Vault integration
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  annotations:
    vault.hashicorp.com/agent-inject: 'true'
    vault.hashicorp.com/agent-inject-secret-db: 'secret/data/db'
    vault.hashicorp.com/role: 'myapp'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: 'true'
        vault.hashicorp.com/agent-inject-secret-config: 'secret/data/myapp/config'
    spec:
      serviceAccountName: vault-auth
      containers:
        - name: app
          image: ghcr.io/joshjhall/containers:python-dev
```

### Key Management Checklist

- [ ] Keys stored in dedicated key management service (KMS, Vault, etc.)
- [ ] Automatic key rotation enabled
- [ ] Key access audit logging enabled
- [ ] Separation of duties for key management
- [ ] Key backup and recovery procedures documented
- [ ] Key deletion policies defined

---

## Database Encryption

### PostgreSQL with TDE

```yaml
# Kubernetes secret for encryption key
apiVersion: v1
kind: Secret
metadata:
  name: postgres-encryption-key
type: Opaque
stringData:
  encryption-key: 'your-encryption-key'
---
# PostgreSQL with encryption
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  template:
    spec:
      containers:
        - name: postgres
          image: postgres:17
          env:
            - name: POSTGRES_INITDB_ARGS
              value: '--data-checksums'
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-encrypted-pvc
```

### Application-Level Encryption

For sensitive fields, implement application-level encryption:

```python
# Python example with cryptography library
from cryptography.fernet import Fernet

class EncryptedField:
    def __init__(self, key):
        self.cipher = Fernet(key)

    def encrypt(self, plaintext):
        return self.cipher.encrypt(plaintext.encode())

    def decrypt(self, ciphertext):
        return self.cipher.decrypt(ciphertext).decode()

# Usage
key = os.environ['ENCRYPTION_KEY']  # From secret management
field = EncryptedField(key)

encrypted_ssn = field.encrypt("123-45-6789")
# Store encrypted_ssn in database
```

---

## Verification Procedures

### Verify Volume Encryption

#### AWS

```bash
# Check EBS volume encryption
aws ec2 describe-volumes --volume-ids vol-xxx \
  --query 'Volumes[0].Encrypted'

# Check all volumes
aws ec2 describe-volumes \
  --query 'Volumes[?Encrypted==`false`].VolumeId'
```

#### GCP

```bash
# Check disk encryption
gcloud compute disks describe DISK_NAME \
  --format='get(diskEncryptionKey)'
```

#### Kubernetes

```bash
# Check StorageClass encryption settings
kubectl get storageclass encrypted-gp3 -o yaml

# Verify PV uses encrypted StorageClass
kubectl get pv -o custom-columns='NAME:.metadata.name,STORAGECLASS:.spec.storageClassName'
```

### Encryption Verification Checklist

- [ ] All persistent volumes use encrypted StorageClass
- [ ] Database connections use TLS
- [ ] Backup storage is encrypted
- [ ] Log storage is encrypted (if containing sensitive data)
- [ ] Encryption key management audit logs reviewed
- [ ] Key rotation verified

---

## Compliance Documentation

For audit purposes, document the following:

### Required Evidence

1. **Encryption Configuration**
   - StorageClass definitions showing encryption enabled
   - Cloud provider encryption settings
   - Key management service configuration

2. **Key Management**
   - KMS key policies
   - Key rotation schedules
   - Access control policies

3. **Verification Records**
   - Regular encryption verification results
   - Audit log samples
   - Compliance scan reports

4. **Procedures**
   - Key rotation procedures
   - Key recovery procedures
   - Incident response for key compromise

### Example Audit Evidence

```bash
# Generate encryption status report
cat << 'EOF' > encryption-audit.sh
#!/bin/bash
echo "=== Encryption Audit Report ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "=== Kubernetes StorageClasses ==="
kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}: {.parameters.encrypted}{"\n"}{end}'

echo ""
echo "=== PersistentVolumes ==="
kubectl get pv -o custom-columns='NAME:.metadata.name,STORAGE_CLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage'

echo ""
echo "=== Cloud Provider Encryption ==="
# AWS
aws ec2 get-ebs-encryption-by-default --query 'EbsEncryptionByDefault' 2>/dev/null || echo "AWS: N/A"

# GCP
gcloud compute project-info describe --format='get(defaultServiceAccount)' 2>/dev/null || echo "GCP: N/A"
EOF
chmod +x encryption-audit.sh
```

---

## Implementation Checklist

### Initial Setup

- [ ] Choose encryption method (platform-native recommended)
- [ ] Set up key management service
- [ ] Create encrypted StorageClasses
- [ ] Configure default encryption for new resources
- [ ] Document encryption architecture

### Deployment

- [ ] Migrate existing volumes to encrypted storage (if needed)
- [ ] Update PersistentVolumeClaims to use encrypted StorageClass
- [ ] Configure database encryption
- [ ] Enable audit logging for key access

### Ongoing

- [ ] Regular encryption verification (monthly)
- [ ] Key rotation (annual or per policy)
- [ ] Audit log review (quarterly)
- [ ] Update documentation for changes

---

## Related Documentation

- [Production Checklist](production-checklist.md) - Pre-deployment security
  checklist
- [SOC 2 Compliance](soc2.md) - C1.1 Confidentiality controls
- [OWASP Docker Top 10](owasp.md) - D06 Protect Secrets
- [Framework Analysis](../reference/compliance.md) - Comprehensive compliance
  mapping
