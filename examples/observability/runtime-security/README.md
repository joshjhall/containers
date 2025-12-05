# Container Runtime Security Monitoring

This directory contains Falco deployment configurations for runtime security
monitoring, supporting compliance requirements for SOC 2, HIPAA, PCI DSS, GDPR,
and FedRAMP.

## Compliance Coverage

| Framework    | Requirement                   | Implementation                 |
| ------------ | ----------------------------- | ------------------------------ |
| SOC 2 CC6.8  | Malicious software detection  | Cryptominer/malware detection  |
| SOC 2 CC7.2  | Security event monitoring     | Real-time syscall monitoring   |
| ISO 27001    | A.12.4 Logging and monitoring | Centralized security events    |
| HIPAA        | 164.312(b) Audit controls     | PHI access monitoring          |
| PCI DSS 10.6 | Security event review         | Automated alert analysis       |
| GDPR Art. 32 | Security of processing        | Data access monitoring         |
| FedRAMP SI-4 | Information system monitoring | Continuous behavior monitoring |

## Files

| File                        | Description                               |
| --------------------------- | ----------------------------------------- |
| falco-daemonset.yaml        | Kubernetes DaemonSet deployment for Falco |
| falco-rules-compliance.yaml | Custom rules for compliance monitoring    |
| falcosidekick.yaml          | Alert routing to Slack, PagerDuty, etc.   |

## Quick Start

### 1. Deploy Falco

```bash
# Create namespace
kubectl create namespace falco-system

# Deploy Falco DaemonSet
kubectl apply -f falco-daemonset.yaml

# Deploy custom compliance rules
kubectl apply -f falco-rules-compliance.yaml

# Deploy alert routing (configure secrets first)
kubectl apply -f falcosidekick.yaml
```

### 2. Configure Alerts

Edit the secrets in `falcosidekick.yaml`:

```bash
# Create secrets with your actual values
kubectl create secret generic falcosidekick-secrets \
  --from-literal=SLACK_WEBHOOK_URL="https://hooks.slack.com/..." \
  --from-literal=PAGERDUTY_ROUTING_KEY="your-key" \
  -n falco-system
```

### 3. Verify Deployment

```bash
# Check Falco pods are running
kubectl get pods -n falco-system

# View Falco logs
kubectl logs -l app.kubernetes.io/name=falco -n falco-system

# Test an alert (in a test pod)
kubectl exec -it test-pod -- cat /etc/shadow
```

## Alternative: Helm Installation

```bash
# Add Falco Helm repo
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

# Install with custom values
helm install falco falcosecurity/falco \
  --namespace falco-system \
  --create-namespace \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  -f values-production.yaml
```

## Rule Categories

### HIPAA Rules

- **PHI Data Access**: Monitors access to files containing patient/medical data
- **PHI Data Export**: Detects potential data exfiltration
- **Database Access**: Unauthorized database connections

### SOC 2 Rules

- **Privileged Containers**: Detects CC6.1 violations
- **Root User Activity**: Monitors privileged access
- **Cryptominer Detection**: CC6.8 malware detection
- **Reverse Shell**: CC6.8/CC7.2 intrusion detection
- **File Integrity**: CC7.1 configuration changes

### PCI DSS Rules

- **Card Data Access**: 10.2.1 cardholder data monitoring
- **Failed Auth**: 10.2.4 authentication failures
- **Audit Tampering**: 10.5.2 log protection
- **Network Services**: 1.3.2 unauthorized services

### GDPR Rules

- **Personal Data Access**: Art. 32 data protection
- **Data Export**: Art. 44 international transfers
- **Encryption Keys**: Art. 32 cryptographic controls

### FedRAMP Rules

- **Account Management**: AC-2 user account changes
- **Package Installation**: CM-7 least functionality
- **Binary Modification**: SI-7 software integrity
- **Network Monitoring**: SC-7 boundary protection

## Incident Response Runbooks

### Critical: Container Escape Attempt

**Alert**: `Container Escape Attempt` **Priority**: CRITICAL **Compliance**: All
frameworks

**Immediate Actions**:

1. Isolate the affected node

   ```bash
   kubectl cordon <node-name>
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```

1. Identify the source container

   ```bash
   kubectl logs -l app.kubernetes.io/name=falco -n falco-system | \
     grep "container_escape" | jq
   ```

1. Terminate suspicious pods

   ```bash
   kubectl delete pod <pod-name> -n <namespace> --grace-period=0 --force
   ```

1. Capture forensic evidence

   ```bash
   kubectl logs <pod-name> -n <namespace> --previous > /tmp/pod-logs.txt
   kubectl describe pod <pod-name> -n <namespace> > /tmp/pod-describe.txt
   ```

1. Review recent changes to the cluster

1. Escalate to security team

**Post-Incident**:

- Perform root cause analysis
- Update security policies
- Document in incident tracker
- Notify compliance officer if breach confirmed

______________________________________________________________________

### Critical: Cryptominer Detected

**Alert**: `SOC2 CC6.8 violation - Cryptominer detected` **Priority**: CRITICAL
**Compliance**: SOC 2, PCI DSS

**Immediate Actions**:

1. Kill the mining process

   ```bash
   kubectl exec <pod-name> -n <namespace> -- pkill -9 xmrig
   ```

1. Delete compromised pod

   ```bash
   kubectl delete pod <pod-name> -n <namespace>
   ```

1. Check container image for tampering

   ```bash
   # Compare with known-good digest
   kubectl get pod <pod-name> -o jsonpath='{.status.containerStatuses[*].imageID}'
   ```

1. Scan cluster for lateral movement

   ```bash
   # Check for similar processes across nodes
   kubectl get pods --all-namespaces -o wide | grep <image-name>
   ```

1. Block network egress to mining pools

   ```bash
   kubectl apply -f - <<EOF
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: block-mining-pools
   spec:
     podSelector: {}
     policyTypes:
     - Egress
     egress:
     - to:
       - ipBlock:
           cidr: 0.0.0.0/0
           except:
           - <mining-pool-ips>
   EOF
   ```

**Post-Incident**:

- Review supply chain security
- Scan all images with vulnerability scanner
- Enable image signing verification
- Update SOC 2 incident log

______________________________________________________________________

### Warning: PHI Data Access

**Alert**: `HIPAA PHI data access detected` **Priority**: WARNING
**Compliance**: HIPAA

**Immediate Actions**:

1. Identify accessing user/process

   ```bash
   kubectl logs -l app.kubernetes.io/name=falco -n falco-system | \
     grep "HIPAA PHI" | jq '.output_fields'
   ```

1. Verify authorized access

   - Check if user has PHI access approval
   - Verify business need for access
   - Check access time vs. working hours

1. If unauthorized, revoke access

   ```bash
   kubectl delete rolebinding <user-binding> -n <namespace>
   ```

1. Preserve audit trail

   ```bash
   kubectl logs -l app.kubernetes.io/name=falco -n falco-system \
     --since=1h > /tmp/phi-access-audit.log
   ```

**Post-Incident**:

- Document in HIPAA access log
- Review with privacy officer
- Update BAA if third-party involved
- Train user on PHI access policies

______________________________________________________________________

### Warning: Reverse Shell Detected

**Alert**: `SOC2 CC6.8/CC7.2 - Reverse shell detected` **Priority**: CRITICAL
**Compliance**: SOC 2, PCI DSS

**Immediate Actions**:

1. Immediately terminate the connection

   ```bash
   kubectl exec <pod-name> -n <namespace> -- \
     bash -c "ss -tp | grep ESTAB | awk '{print \$6}' | cut -d'=' -f2 | xargs kill -9"
   ```

1. Isolate the pod

   ```bash
   kubectl label pod <pod-name> quarantine=true
   kubectl apply -f - <<EOF
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: quarantine
   spec:
     podSelector:
       matchLabels:
         quarantine: "true"
     policyTypes:
     - Ingress
     - Egress
   EOF
   ```

1. Capture network connections

   ```bash
   kubectl exec <pod-name> -- ss -tupan > /tmp/network-connections.txt
   kubectl exec <pod-name> -- cat /proc/net/tcp > /tmp/tcp-connections.txt
   ```

1. Identify command & control server

1. Block C2 IP at firewall/security group

**Post-Incident**:

- Full incident response investigation
- Check for data exfiltration
- Review container image provenance
- Implement network segmentation
- File security incident report

______________________________________________________________________

### Notice: Interactive Shell in Container

**Alert**: `Interactive shell spawned in container` **Priority**: NOTICE
**Compliance**: SOC 2

**Actions**:

1. Verify legitimate troubleshooting

   ```bash
   # Check who initiated kubectl exec
   kubectl get events --field-selector reason=Exec -n <namespace>
   ```

1. Document the session

   - User identity
   - Business justification
   - Duration of access
   - Actions performed

1. If unauthorized

   ```bash
   # Find and terminate the shell
   kubectl exec <pod-name> -- pkill -u <user> bash
   ```

1. Review access controls

   ```bash
   kubectl auth can-i --list --as=<user>
   ```

**Best Practices**:

- Use `kubectl debug` instead of `exec`
- Implement break-glass procedures
- Enable session recording

______________________________________________________________________

## Prometheus Queries

### Security Event Dashboard

```promql
# Total events by priority (24h)
sum by (priority) (increase(falco_events[24h]))

# Critical events rate
rate(falco_events{priority="Critical"}[5m])

# Top 10 rules triggered
topk(10, sum by (rule) (increase(falco_events[1h])))

# Events by namespace
sum by (k8s_ns_name) (increase(falco_events[1h]))

# Dropped events (performance issue)
rate(falco_kernel_event_drops_total[5m])
```

### Compliance Metrics

```promql
# HIPAA events
sum(increase(falco_events{tags=~".*hipaa.*"}[24h]))

# SOC 2 violations
sum(increase(falco_events{tags=~".*soc2.*", priority="Critical"}[24h]))

# PCI DSS events
sum(increase(falco_events{tags=~".*pci-dss.*"}[24h]))
```

## Integration with Logging Pipeline

### Fluentd Configuration

```yaml
<source> @type tail path /var/log/falco/events.json pos_file
/var/log/falco/events.json.pos tag falco.events format json time_key time
time_format %Y-%m-%dT%H:%M:%S.%NZ </source>

<filter falco.events> @type record_transformer <record> cluster
"#{ENV['CLUSTER_NAME']}" environment "#{ENV['ENVIRONMENT']}" </record> </filter>

<match falco.events> @type elasticsearch host
elasticsearch.monitoring.svc.cluster.local port 9200 index_name falco-events
type_name _doc </match>
```

### Promtail Configuration

```yaml
scrape_configs:
  - job_name: falco
    static_configs:
      - targets:
          - localhost
        labels:
          job: falco
          __path__: /var/log/falco/events.json
    pipeline_stages:
      - json:
          expressions:
            priority: priority
            rule: rule
            output: output
      - labels:
          priority:
          rule:
```

## Tuning and Performance

### Reducing False Positives

```yaml
# Add to falco.yaml
rules_file:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/rules.d/compliance_rules.yaml
  - /etc/falco/rules.d/exceptions.yaml # Local exceptions
```

### Exception Example

```yaml
# exceptions.yaml
- rule: Shell Spawned in Container
  exceptions:
    - name: known_debug_pods
      fields: [k8s.pod.name]
      comps: [startswith]
      values:
        - [[debug-]]
```

### Performance Tuning

```yaml
# For high-traffic clusters
syscall_event_drops:
  threshold: 0.5 # Higher threshold
  actions:
    - log
  rate: 0.1
  max_burst: 10

# Increase buffer sizes
syscall_buf_size_preset: 4 # 0-4, higher = more memory
```

## Related Documentation

- [Audit Logging](../audit-logging/README.md)
- [Falco Official Docs](https://falco.org/docs/)
- [Falcosidekick Outputs](https://github.com/falcosecurity/falcosidekick)
- [SOC 2 Compliance](https://www.aicpa.org/soc2)
- [HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/)
