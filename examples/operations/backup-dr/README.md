# Automated Backup and Disaster Recovery

This directory contains Velero deployment configurations for automated backups
and disaster recovery procedures, supporting compliance requirements for HIPAA,
SOC 2, PCI DSS, GDPR, and FedRAMP.

## Compliance Coverage

| Framework         | Requirement                     | Implementation                  |
| ----------------- | ------------------------------- | ------------------------------- |
| HIPAA 164.308(a)7 | Contingency plan                | Automated backups, DR runbooks  |
| HIPAA 164.310(d)2 | Data backup and storage         | Encrypted backups, 6-year TTL   |
| HIPAA 164.530(j)  | Record retention                | 6-year retention for PHI        |
| SOC 2 A1.2        | System availability             | Recovery procedures, RTO/RPO    |
| SOC 2 A1.3        | Recovery testing                | Automated validation scripts    |
| ISO 27001 A.17.1  | Information security continuity | DR runbooks, testing procedures |
| PCI DSS 9.5       | Protect backup media            | Encrypted storage, access logs  |
| GDPR Art. 32      | Security of processing          | Encryption, integrity checks    |
| FedRAMP CP-9      | Information system backup       | Automated schedules, encryption |
| FedRAMP CP-4      | Contingency plan testing        | Quarterly validation            |

## Files

| File                   | Description                              |
| ---------------------- | ---------------------------------------- |
| velero-deployment.yaml | Velero installation with encryption      |
| backup-schedules.yaml  | Backup schedules with retention policies |
| validate-backup.sh     | Backup validation and testing script     |

## RTO/RPO Targets

| Tier   | Workloads                  | RTO      | RPO     | Backup Frequency |
| ------ | -------------------------- | -------- | ------- | ---------------- |
| Tier 1 | Critical production, HIPAA | 1 hour   | 1 hour  | Hourly           |
| Tier 2 | Standard production        | 4 hours  | 4 hours | Daily            |
| Tier 3 | Staging, non-critical      | 24 hours | 24 hour | Weekly           |
| Tier 4 | Development                | 72 hours | 7 days  | Monthly          |

**Definitions**:

- **RTO (Recovery Time Objective)**: Maximum acceptable time to restore service
- **RPO (Recovery Point Objective)**: Maximum acceptable data loss period

## Quick Start

### 1. Install Velero CLI

```bash
# macOS
brew install velero

# Linux
curl -L https://github.com/vmware-tanzu/velero/releases/download/v1.13.0/velero-v1.13.0-linux-amd64.tar.gz | tar xz
mv velero-v1.13.0-linux-amd64/velero /usr/local/bin/
```

### 2. Configure Cloud Credentials

```bash
# AWS S3
cat > /tmp/credentials-velero << EOF
[default]
aws_access_key_id = YOUR_ACCESS_KEY
aws_secret_access_key = YOUR_SECRET_KEY
EOF

kubectl create secret generic velero-credentials \
  --from-file=cloud=/tmp/credentials-velero \
  -n velero

rm /tmp/credentials-velero
```

### 3. Deploy Velero

```bash
# Create namespace and deploy
kubectl apply -f velero-deployment.yaml

# Verify deployment
kubectl get pods -n velero
velero version
```

### 4. Apply Backup Schedules

```bash
# Review and customize retention policies first
kubectl apply -f backup-schedules.yaml

# Verify schedules
velero schedule get
```

### 5. Test Backup Validation

```bash
# Make script executable
chmod +x validate-backup.sh

# Validate latest HIPAA backup
./validate-backup.sh --schedule hipaa-phi-backup

# Validate specific backup
./validate-backup.sh daily-all-namespaces-20231215120000
```

## Disaster Recovery Runbooks

### DR-001: Complete Cluster Failure

**Scenario**: Total loss of Kubernetes cluster **RTO**: 4 hours | **RPO**: 1
hour **Compliance**: HIPAA 164.308(a)(7), SOC 2 A1.2

#### Prerequisites

- New Kubernetes cluster provisioned
- Access to backup storage location
- Velero CLI installed
- Cloud credentials available

#### Recovery Steps

1. **Install Velero on new cluster**

   ```bash
   # Apply Velero deployment
   kubectl apply -f velero-deployment.yaml

   # Wait for Velero to be ready
   kubectl wait --for=condition=available deployment/velero -n velero --timeout=300s
   ```

2. **Verify backup storage access**

   ```bash
   # Check backup storage location
   velero backup-location get

   # Ensure it's available
   velero backup-location get default -o json | jq '.status.phase'
   ```

3. **List available backups**

   ```bash
   # List all backups
   velero backup get

   # Find latest complete backup
   velero backup get --selector velero.io/schedule-name=daily-all-namespaces
   ```

4. **Restore cluster state first**

   ```bash
   # Restore CRDs, RBAC, and cluster resources
   velero restore create cluster-state-restore \
     --from-backup cluster-state-backup-YYYYMMDD \
     --include-resources customresourcedefinitions,clusterroles,clusterrolebindings \
     --wait
   ```

5. **Restore namespaces in order**

   ```bash
   # 1. Infrastructure namespaces
   velero restore create infra-restore \
     --from-backup daily-all-namespaces-YYYYMMDD \
     --include-namespaces cert-manager,ingress-nginx,monitoring \
     --wait

   # 2. HIPAA/PHI workloads (highest priority)
   velero restore create hipaa-restore \
     --from-backup hipaa-phi-backup-YYYYMMDD \
     --wait

   # 3. Production workloads
   velero restore create production-restore \
     --from-backup daily-all-namespaces-YYYYMMDD \
     --include-namespaces production \
     --wait
   ```

6. **Verify restoration**

   ```bash
   # Check restore status
   velero restore get

   # Verify workloads
   kubectl get pods --all-namespaces

   # Check for pending PVCs
   kubectl get pvc --all-namespaces | grep Pending
   ```

7. **Update DNS and load balancers**

   ```bash
   # Get new ingress IPs
   kubectl get svc -n ingress-nginx

   # Update DNS records in your DNS provider
   ```

8. **Validate application functionality**
   - Run smoke tests
   - Verify database connectivity
   - Check external integrations
   - Validate monitoring and alerting

#### Post-Recovery

- [ ] Document recovery timeline
- [ ] Update incident report
- [ ] Review and update RTO/RPO targets
- [ ] Conduct lessons learned meeting
- [ ] Update runbook if needed

---

### DR-002: Namespace Data Loss

**Scenario**: Accidental deletion or corruption of namespace **RTO**: 1 hour |
**RPO**: Based on backup frequency **Compliance**: SOC 2 A1.2, PCI DSS 9.5

#### Recovery Steps

1. **Identify the affected namespace and last good backup**

   ```bash
   # List backups containing the namespace
   velero backup get -o json | jq -r \
     '.items[] | select(.spec.includedNamespaces[]? == "NAMESPACE") | .metadata.name'

   # Or check daily backups
   velero backup describe daily-all-namespaces-YYYYMMDD --details
   ```

2. **Restore the namespace**

   ```bash
   # Full namespace restore
   velero restore create namespace-restore-$(date +%s) \
     --from-backup daily-all-namespaces-YYYYMMDD \
     --include-namespaces NAMESPACE \
     --wait

   # Or selective restore (specific resources)
   velero restore create selective-restore-$(date +%s) \
     --from-backup daily-all-namespaces-YYYYMMDD \
     --include-namespaces NAMESPACE \
     --include-resources deployments,services,configmaps,secrets \
     --wait
   ```

3. **Verify restoration**

   ```bash
   # Check all resources restored
   kubectl get all -n NAMESPACE

   # Verify PVCs are bound
   kubectl get pvc -n NAMESPACE

   # Check pod logs for errors
   kubectl logs -n NAMESPACE -l app=YOUR_APP --tail=100
   ```

---

### DR-003: Database Corruption

**Scenario**: Database data corruption requiring point-in-time recovery **RTO**:
2 hours | **RPO**: 1 hour **Compliance**: HIPAA 164.310(d)(2)(iv), PCI DSS 9.5.1

#### Recovery Steps

1. **Stop application traffic**

   ```bash
   # Scale down application deployments
   kubectl scale deployment APP_NAME -n NAMESPACE --replicas=0

   # Or apply network policy to block traffic
   kubectl apply -f - <<EOF
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: block-db-traffic
     namespace: NAMESPACE
   spec:
     podSelector:
       matchLabels:
         app: database
     policyTypes:
     - Ingress
   EOF
   ```

2. **Identify backup with good database state**

   ```bash
   # List database backups
   velero backup get -l backup-type=database

   # Check backup details
   velero backup describe hipaa-phi-backup-YYYYMMDD --details
   ```

3. **Restore database PVC**

   ```bash
   # Delete corrupted PVC (data will be lost)
   kubectl delete pvc database-pvc -n NAMESPACE

   # Restore from backup
   velero restore create db-restore-$(date +%s) \
     --from-backup hipaa-phi-backup-YYYYMMDD \
     --include-namespaces NAMESPACE \
     --include-resources persistentvolumeclaims \
     --selector app=database \
     --wait
   ```

4. **Restart database and verify**

   ```bash
   # Restart database pod
   kubectl delete pod -n NAMESPACE -l app=database

   # Wait for database to be ready
   kubectl wait --for=condition=ready pod -l app=database -n NAMESPACE --timeout=300s

   # Run integrity checks
   kubectl exec -it DATABASE_POD -n NAMESPACE -- pg_isready
   kubectl exec -it DATABASE_POD -n NAMESPACE -- psql -c "SELECT count(*) FROM critical_table;"
   ```

5. **Restore application traffic**

   ```bash
   # Remove network policy
   kubectl delete networkpolicy block-db-traffic -n NAMESPACE

   # Scale up application
   kubectl scale deployment APP_NAME -n NAMESPACE --replicas=3
   ```

---

### DR-004: HIPAA PHI Breach Recovery

**Scenario**: Potential PHI data breach requiring forensic preservation and
recovery **RTO**: 4 hours | **RPO**: 0 (preserve current state) **Compliance**:
HIPAA 164.308(a)(6), 164.404

#### Recovery Steps

1. **IMMEDIATE: Preserve forensic evidence**

   ```bash
   # Create forensic backup of current state
   velero backup create forensic-breach-$(date +%Y%m%d-%H%M%S) \
     --include-namespaces hipaa-production,healthcare \
     --include-cluster-resources=true \
     --ttl 2160h  # 90 days for investigation

   # Export logs
   kubectl logs -n hipaa-production --all-containers --timestamps > /tmp/breach-logs.txt
   ```

2. **Isolate affected workloads**

   ```bash
   # Apply strict network policy
   kubectl apply -f - <<EOF
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: isolate-breach
     namespace: hipaa-production
   spec:
     podSelector: {}
     policyTypes:
     - Ingress
     - Egress
   EOF
   ```

3. **Notify compliance officer**
   - Contact: [HIPAA Privacy Officer]
   - Document timeline of events
   - Preserve all evidence

4. **Restore from last known good state**

   ```bash
   # Identify pre-breach backup
   velero backup get -l backup-type=hipaa-compliant

   # Restore to isolated namespace first
   velero restore create hipaa-recovery-$(date +%s) \
     --from-backup hipaa-phi-backup-YYYYMMDD \
     --namespace-mappings "hipaa-production:hipaa-recovery" \
     --wait
   ```

5. **Validate restored data integrity**

   ```bash
   # Compare record counts
   kubectl exec -it DB_POD -n hipaa-recovery -- psql -c "SELECT count(*) FROM patients;"

   # Verify encryption labels
   kubectl get pods -n hipaa-recovery -o json | \
     jq '.items[].metadata.labels.encryption'
   ```

6. **Document for compliance reporting**
   - Timeline of incident
   - Affected records estimate
   - Recovery actions taken
   - Preventive measures implemented

---

## Backup Validation Schedule

| Validation Type | Frequency | Compliance Requirement           |
| --------------- | --------- | -------------------------------- |
| Automated test  | Daily     | SOC 2 A1.3                       |
| Full restore    | Weekly    | HIPAA 164.308(a)(7)(ii)(D)       |
| DR drill        | Quarterly | FedRAMP CP-4, ISO 27001 A.17.1.3 |
| Full DR test    | Annually  | All frameworks                   |

### Automated Validation (Daily)

```bash
# Add to cron or Kubernetes CronJob
./validate-backup.sh --schedule daily-all-namespaces
./validate-backup.sh --schedule hipaa-phi-backup
```

### Weekly Full Restore Test

```bash
# Restore to isolated namespace
velero restore create weekly-test-$(date +%s) \
  --from-backup weekly-all-namespaces-YYYYMMDD \
  --namespace-mappings "*:restore-test" \
  --wait

# Validate and cleanup
./validate-backup.sh --latest weekly-all-namespaces --no-cleanup
# Manual validation of application functionality
kubectl delete namespace restore-test
```

## Monitoring and Alerting

### Prometheus Queries

```promql
# Backup success rate (24h)
sum(increase(velero_backup_success_total[24h])) /
(sum(increase(velero_backup_success_total[24h])) +
 sum(increase(velero_backup_failure_total[24h])))

# Time since last successful backup
time() - velero_backup_last_successful_timestamp{schedule="hipaa-phi-backup"}

# Backup duration trend
histogram_quantile(0.99, sum(rate(velero_backup_duration_seconds_bucket[24h])) by (le, schedule))
```

### Alert Rules

See `velero-deployment.yaml` for Prometheus alert rules including:

- `VeleroBackupFailed`: Critical - immediate attention
- `VeleroBackupPartiallyFailed`: Warning - investigate
- `VeleroBackupNotRunRecently`: Warning - check schedule
- `VeleroRestoreFailed`: Critical - DR capability impacted
- `VeleroBackupStorageLocationUnavailable`: Critical - backups cannot be stored

## Retention Policies

| Data Type       | Retention | Schedule         | Compliance          |
| --------------- | --------- | ---------------- | ------------------- |
| HIPAA PHI       | 6 years   | hipaa-phi-backup | HIPAA 164.530(j)    |
| PCI cardholder  | 1 year    | pci-cardholder   | PCI DSS 3.1         |
| Audit logs      | 1 year    | cluster-state    | SOC 2, PCI DSS 10.7 |
| Production data | 30 days   | weekly-all       | SOC 2 A1.2          |
| Cluster state   | 7 days    | cluster-state    | Operations          |

## Encryption

All backups are encrypted using:

- **At rest**: AWS KMS (AES-256) or equivalent cloud KMS
- **In transit**: TLS 1.3
- **File-level**: Restic with AES-256-CTR

Configure encryption in `velero-deployment.yaml`:

```yaml
config:
  kmsKeyId: 'arn:aws:kms:us-east-1:123456789012:key/your-kms-key-id'
```

## Related Documentation

- [Runtime Security Monitoring](../../observability/runtime-security/README.md)
- [OPA Gatekeeper Policies](../../security/opa-gatekeeper/README.md)
- [Velero Documentation](https://velero.io/docs/)
- [HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/)
