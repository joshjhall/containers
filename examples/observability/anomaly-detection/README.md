# Runtime Anomaly Detection Baseline and Tuning

This directory contains tools and documentation for establishing behavioral
baselines and tuning runtime security monitoring for anomaly detection.

## Compliance Coverage

| Framework         | Requirement                    | Implementation                 |
| ----------------- | ------------------------------ | ------------------------------ |
| FedRAMP SI-4(5)   | Automated alerts/notifications | Baseline-adjusted thresholds   |
| CMMC SI.L2-3.14.2 | Security monitoring            | Anomaly detection rules        |
| CIS Control 8.11  | Collect detailed audit logs    | Behavioral baseline collection |
| SOC 2 CC7.2       | Security event monitoring      | Tuned Falco rules              |
| ISO 27001 A.12.4  | Logging and monitoring         | Automated baseline updates     |

## Overview

Anomaly detection requires establishing a baseline of normal behavior before
alerts can be tuned effectively. This process involves:

1. **Baseline Collection** (30 days): Collect metrics during normal operations
1. **Statistical Analysis**: Calculate mean, standard deviation, thresholds
1. **Rule Tuning**: Generate Falco exceptions and alert thresholds
1. **Continuous Monitoring**: Compare current behavior to baseline
1. **Quarterly Updates**: Re-baseline to account for application changes

## Quick Start

### 1. Start Baseline Collection

```bash
# Collect baseline for production namespace (30 days recommended)
./bin/baseline-runtime-behavior.sh --start \
  --duration 30d \
  --namespace production \
  --output /data/baseline

# Multiple namespaces
./bin/baseline-runtime-behavior.sh --start \
  --duration 30d \
  --namespace production,staging,hipaa-production
```

### 2. Analyze Baseline and Generate Rules

```bash
# Analyze collected baseline
./bin/baseline-runtime-behavior.sh --analyze \
  --baseline-file /data/baseline/baseline_report_production.json \
  --generate-rules

# This generates:
# - /data/baseline/falco_tuning_rules.yaml
# - /data/baseline/anomaly_alerts.yaml
```

### 3. Apply Tuning Rules

```bash
# Review generated rules first!
cat /data/baseline/falco_tuning_rules.yaml

# Apply Falco exceptions
kubectl apply -f /data/baseline/falco_tuning_rules.yaml -n falco-system

# Apply Prometheus alert rules
kubectl apply -f /data/baseline/anomaly_alerts.yaml
```

### 4. Monitor for Anomalies

```bash
# Compare current behavior to baseline
./bin/baseline-runtime-behavior.sh --compare \
  /data/baseline/baseline_report_production.json
```

## Expected Behaviors by Container Type

### Web Application Containers

| Behavior          | Expected Pattern         | Anomaly Indicators         |
| ----------------- | ------------------------ | -------------------------- |
| Process execution | Low (< 10/hour)          | Shell spawns, new binaries |
| Network           | HTTP/S on standard ports | Outbound to unknown IPs    |
| File access       | Log writes, static reads | /etc/passwd, /etc/shadow   |
| User context      | Non-root (UID > 1000)    | UID 0 operations           |

**Normal Processes**: nginx, gunicorn, node, python **Anomalous Processes**: sh,
bash, curl, wget, nc

### Database Containers

| Behavior          | Expected Pattern          | Anomaly Indicators        |
| ----------------- | ------------------------- | ------------------------- |
| Process execution | Very low (< 5/hour)       | Any non-DB processes      |
| Network           | DB ports (3306, 5432)     | Non-DB protocol traffic   |
| File access       | Data directory only       | Config file modifications |
| User context      | DB user (mysql, postgres) | Root or other users       |

**Normal Processes**: mysqld, postgres, mongod **Anomalous Processes**: Any
shell, package managers

### Worker/Job Containers

| Behavior          | Expected Pattern       | Anomaly Indicators          |
| ----------------- | ---------------------- | --------------------------- |
| Process execution | Medium (varies by job) | Processes outside job scope |
| Network           | Queue connections      | Direct internet access      |
| File access       | Work directory         | System file access          |
| User context      | Non-root               | Privilege escalation        |

**Normal Processes**: Job-specific binaries **Anomalous Processes**: Interactive
shells, network tools

### Sidecar Containers (Envoy, Istio)

| Behavior          | Expected Pattern    | Anomaly Indicators           |
| ----------------- | ------------------- | ---------------------------- |
| Process execution | Very low            | Any spawned processes        |
| Network           | High, proxy traffic | Direct connections bypassing |
| File access       | Config, certs only  | Data file access             |
| User context      | envoy, istio-proxy  | Root operations              |

**Normal Processes**: envoy, pilot-agent **Anomalous Processes**: Any other
processes

## Anomaly Severity Matrix

| Severity     | Examples                                     | Response Time | Action                   |
| ------------ | -------------------------------------------- | ------------- | ------------------------ |
| **Critical** | Reverse shell, container escape, cryptominer | Immediate     | Isolate, terminate       |
| **High**     | Root escalation, sensitive file access       | 15 minutes    | Investigate, may isolate |
| **Medium**   | Unusual process execution, network anomaly   | 1 hour        | Review, tune if needed   |
| **Low**      | Minor threshold breach, known maintenance    | 24 hours      | Log, consider exception  |
| **Info**     | Expected behavior during deployment/upgrade  | N/A           | Document                 |

### Severity Determination Factors

1. **Deviation from baseline**: > 3σ = Critical, > 2σ = High
1. **Compliance impact**: PHI access = automatic High
1. **Attack pattern match**: Known malware = Critical
1. **Time of occurrence**: Off-hours = increase severity

## Anomaly Response Procedures

### ANOM-001: Process Execution Anomaly

**Symptoms**: Unexpected process spawned in container **Severity**: Medium to
Critical (based on process type)

#### Process Anomaly Response Steps

1. **Identify the process**

   ```bash
   # Get process details from Falco
   kubectl logs -l app.kubernetes.io/name=falco -n falco-system | \
     grep "proc.name" | tail -20
   ```

1. **Assess severity**

   - Shell (bash, sh, zsh): High
   - Package manager (apt, yum, pip): High
   - Network tool (curl, wget, nc): Critical
   - Expected utility: Low

1. **Check if legitimate**

   - Deployment in progress?
   - Scheduled maintenance?
   - Debug session authorized?

1. **If malicious**

   ```bash
   # Terminate the process
   kubectl exec POD_NAME -n NAMESPACE -- pkill -9 PROCESS_NAME

   # Or terminate the pod
   kubectl delete pod POD_NAME -n NAMESPACE --grace-period=0
   ```

1. **Document and tune**

   - If legitimate: add exception to baseline
   - If malicious: escalate to security team

______________________________________________________________________

### ANOM-002: Network Traffic Anomaly

**Symptoms**: Unusual outbound connections or traffic patterns **Severity**:
Medium to Critical

#### Network Anomaly Response Steps

1. **Capture connection details**

   ```bash
   kubectl exec POD_NAME -n NAMESPACE -- ss -tupan
   kubectl exec POD_NAME -n NAMESPACE -- cat /proc/net/tcp
   ```

1. **Identify destination**

   ```bash
   # Resolve IP to hostname
   nslookup DEST_IP

   # Check threat intelligence
   curl "https://api.abuseipdb.com/api/v2/check?ipAddress=DEST_IP"
   ```

1. **Assess purpose**

   - Known service endpoint?
   - Cloud metadata (169.254.169.254)?
   - Mining pool or C2 server?

1. **If malicious**

   ```bash
   # Apply network policy to isolate
   kubectl label pod POD_NAME quarantine=true
   kubectl apply -f quarantine-network-policy.yaml
   ```

1. **Block at network level**

   - Add to security group blocklist
   - Update firewall rules

______________________________________________________________________

### ANOM-003: File Access Anomaly

**Symptoms**: Access to sensitive files or unusual directories **Severity**:
High to Critical for sensitive files

#### Sensitive Files

| File Pattern       | Sensitivity | Why It Matters        |
| ------------------ | ----------- | --------------------- |
| /etc/passwd        | High        | User enumeration      |
| /etc/shadow        | Critical    | Password hashes       |
| /proc/self/environ | High        | Environment variables |
| ~/.ssh/            | Critical    | SSH keys              |
| ~/.aws/            | Critical    | Cloud credentials     |
| /var/run/secrets/  | Critical    | Kubernetes secrets    |

#### File Access Anomaly Response Steps

1. **Identify what was accessed**

   ```bash
   kubectl logs -l app.kubernetes.io/name=falco -n falco-system | \
     grep "fd.name" | grep NAMESPACE
   ```

1. **Check process that accessed**

   - Is it the expected application?
   - What user context?

1. **Assess data exposure**

   - Was file content read?
   - Could data be exfiltrated?

1. **For credential files**

   - Rotate affected credentials immediately
   - Check for unauthorized access

______________________________________________________________________

### ANOM-004: Privilege Escalation Attempt

**Symptoms**: Process attempting to gain elevated privileges **Severity**:
Critical

#### Privilege Escalation Response Steps

1. **Immediate containment**

   ```bash
   kubectl delete pod POD_NAME -n NAMESPACE --grace-period=0 --force
   ```

1. **Check for success**

   ```bash
   # Were elevated operations performed?
   kubectl logs -l app.kubernetes.io/name=falco -n falco-system | \
     grep -E "user.uid=0|setuid|capability"
   ```

1. **Investigate container image**

   - Check for vulnerabilities
   - Verify image provenance
   - Compare to known-good digest

1. **Review cluster security**

   - Pod security policies
   - RBAC permissions
   - Network policies

## Baseline Update Schedule

| Update Type       | Frequency | Trigger                   |
| ----------------- | --------- | ------------------------- |
| Automatic refresh | Quarterly | Scheduled job             |
| Post-deployment   | On-demand | Major application changes |
| Post-incident     | On-demand | After security incident   |
| Compliance review | Annually  | Audit preparation         |

### Quarterly Baseline Update CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: baseline-update
  namespace: monitoring
spec:
  schedule: '0 2 1 */3 *' # First day of quarter, 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: baseline
              image: your-registry/baseline-tools:latest
              command:
                - /bin/bash
                - -c
                - |
                  ./bin/baseline-runtime-behavior.sh --start \
                    --duration 7d \
                    --namespace production,staging \
                    --output /data/baseline/quarterly

                  ./bin/baseline-runtime-behavior.sh --analyze \
                    --baseline-file /data/baseline/quarterly/baseline_report_production.json \
                    --generate-rules
          restartPolicy: OnFailure
```

## Prometheus Queries for Anomaly Detection

```promql
# Deviation from baseline (requires recording rule with baseline)
(
  sum(rate(falco_events{k8s_ns_name="production"}[5m])) -
  avg_over_time(falco_events_baseline{namespace="production"}[30d])
) / stddev_over_time(falco_events_baseline{namespace="production"}[30d])

# Sudden spike detection (3x normal rate)
sum(rate(falco_events[5m])) > 3 * sum(rate(falco_events[1h] offset 5m))

# New rule triggered (not seen in baseline period)
count by (rule) (falco_events) unless count by (rule) (falco_events offset 30d)

# Per-pod deviation
(
  sum by (k8s_pod_name) (rate(falco_events[5m])) -
  avg by (k8s_pod_name) (rate(falco_events[30d]))
) / stddev by (k8s_pod_name) (rate(falco_events[30d])) > 2
```

## Integration with SIEM

### Splunk

```spl
index=falco sourcetype=falco:events
| eval severity=case(
    priority=="Critical", 4,
    priority=="Error", 3,
    priority=="Warning", 2,
    true(), 1
  )
| stats count by rule, k8s_ns_name, severity
| where count > baseline_threshold
```

### Elastic SIEM

```json
{
  "query": {
    "bool": {
      "must": [
        { "match": { "event.module": "falco" } },
        {
          "range": {
            "@timestamp": { "gte": "now-5m" }
          }
        }
      ],
      "filter": {
        "script": {
          "script": "doc['event.count'].value > doc['baseline.threshold'].value"
        }
      }
    }
  }
}
```

## Related Documentation

- [Runtime Security Monitoring](../runtime-security/README.md)
- [Falco Rules](../runtime-security/falco-rules-compliance.yaml)
- [Backup and DR](../../operations/backup-dr/README.md)
- [Falco Documentation](https://falco.org/docs/)
