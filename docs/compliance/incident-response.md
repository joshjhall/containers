# Incident Response Playbooks

This document provides incident response procedures for container security
events. Use these playbooks to ensure consistent and compliant incident
handling.

## Compliance Coverage

| Framework         | Requirement                    | Status   |
| ----------------- | ------------------------------ | -------- |
| SOC 2 CC7.4       | Incident response              | Guidance |
| HIPAA §164.308(a) | Incident procedures            | Guidance |
| ISO 27001 A.5.24  | Information security incidents | Guidance |
| PCI DSS 12.10     | Incident response plan         | Guidance |
| NIST CSF RS       | Response planning              | Guidance |

---

## Incident Classification

### Severity Levels

| Level    | Definition                           | Response Time | Examples                                     |
| -------- | ------------------------------------ | ------------- | -------------------------------------------- |
| Critical | Active breach, data exfiltration     | 15 minutes    | Compromised credentials, active attack       |
| High     | Potential breach, service impact     | 1 hour        | Vulnerability exploited, suspicious activity |
| Medium   | Security policy violation            | 4 hours       | Unauthorized access attempt, misconfig       |
| Low      | Informational, potential improvement | 24 hours      | Failed login, policy suggestion              |

### Incident Categories

1. **Container Compromise** - Unauthorized access or code execution
2. **Data Exposure** - Sensitive data leaked or accessed
3. **Supply Chain** - Compromised dependency or image
4. **Misconfiguration** - Security settings incorrect
5. **Availability** - Denial of service or resource exhaustion

---

## Playbook: Container Compromise

### Detection

**Indicators**:

- Unexpected processes in container
- Unusual network connections
- File system modifications
- Falco/runtime security alerts

**Initial Assessment**:

```bash
# Check running processes
kubectl exec <pod> -- ps aux

# Check network connections
kubectl exec <pod> -- netstat -tulpn

# Check recent file modifications
kubectl exec <pod> -- find / -mmin -60 -type f 2>/dev/null
```

### Containment

**Immediate Actions** (within 15 minutes):

1. **Isolate the container**

   ```bash
   # Apply network policy to block all traffic
   kubectl apply -f - <<EOF
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: isolate-compromised
     namespace: <namespace>
   spec:
     podSelector:
       matchLabels:
         app: <compromised-app>
     policyTypes:
       - Ingress
       - Egress
   EOF
   ```

2. **Capture forensic evidence**

   ```bash
   # Export container logs
   kubectl logs <pod> --all-containers > incident-logs.txt

   # Export pod details
   kubectl describe pod <pod> > incident-pod-describe.txt

   # Create snapshot if possible
   kubectl exec <pod> -- tar czf - / > container-snapshot.tar.gz
   ```

3. **Notify stakeholders**
   - Security team
   - Infrastructure team
   - Management (if Critical/High)

### Eradication

1. **Identify root cause**
   - Review logs and forensic evidence
   - Check for vulnerability exploitation
   - Verify image integrity

2. **Remove threat**

   ```bash
   # Delete compromised pod
   kubectl delete pod <pod>

   # Verify no persistence mechanisms
   kubectl get pods,deployments,daemonsets -l app=<app>
   ```

3. **Patch vulnerability**
   - Update container image
   - Apply security patches
   - Update dependencies

### Recovery

1. **Verify clean state**

   ```bash
   # Rebuild with fresh image
   docker build --no-cache -t myapp:recovery .

   # Verify signature
   cosign verify --certificate-identity-regexp=... myapp:recovery

   # Scan for vulnerabilities
   trivy image --severity CRITICAL,HIGH myapp:recovery
   ```

2. **Restore service**

   ```bash
   # Deploy clean version
   kubectl rollout restart deployment/<deployment>

   # Verify health
   kubectl rollout status deployment/<deployment>
   ```

3. **Monitor for recurrence**
   - Enable enhanced logging
   - Watch for similar indicators
   - Set up alerts

### Post-Incident

- Complete incident report within 24 hours
- Conduct root cause analysis
- Update security controls
- Schedule lessons learned meeting

---

## Playbook: Data Exposure

### Detection

**Indicators**:

- Secrets in logs or error messages
- Unauthorized API access
- Data in unencrypted storage
- Gitleaks/Trivy alerts

### Containment

1. **Rotate exposed credentials immediately**

   ```bash
   # Rotate Kubernetes secrets
   kubectl create secret generic <secret> \
     --from-literal=key=<new-value> \
     --dry-run=client -o yaml | kubectl apply -f -

   # Restart pods to pick up new secrets
   kubectl rollout restart deployment/<deployment>
   ```

2. **Revoke access tokens**
   - API keys
   - OAuth tokens
   - Service account credentials

3. **Block unauthorized access**
   - Update firewall rules
   - Revoke user access
   - Invalidate sessions

### Investigation

1. **Determine scope**
   - What data was exposed?
   - Who had access?
   - How long was it exposed?

2. **Audit access logs**

   ```bash
   # Check Kubernetes audit logs
   kubectl logs -n kube-system -l component=kube-apiserver | grep <resource>
   ```

3. **Document exposure timeline**

### Notification

Based on data type and regulations:

- **PCI DSS**: Notify payment brands within 24 hours
- **HIPAA**: Notify HHS within 60 days
- **GDPR**: Notify authority within 72 hours
- **Internal**: Follow company notification policy

---

## Playbook: Supply Chain Attack

### Detection

**Indicators**:

- Unexpected image changes
- Signature verification failure
- New vulnerabilities in dependencies
- SBOM changes

### Verification

```bash
# Verify image signature
cosign verify \
  --certificate-identity-regexp='^https://github.com/joshjhall/containers' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  <image>

# Compare SBOM
diff previous-sbom.json current-sbom.json

# Scan for vulnerabilities
trivy image --severity CRITICAL <image>
```

### Response

1. **Stop using affected image**

   ```bash
   # Scale down deployment
   kubectl scale deployment/<deployment> --replicas=0
   ```

2. **Identify affected systems**

   ```bash
   # Find pods using the image
   kubectl get pods --all-namespaces -o json | \
     jq '.items[] | select(.spec.containers[].image == "<affected-image>")'
   ```

3. **Roll back to known good version**

   ```bash
   kubectl rollout undo deployment/<deployment>
   ```

4. **Notify upstream maintainers**

---

## Playbook: Security Misconfiguration

### Detection

**Indicators**:

- OPA/Gatekeeper policy violations
- Security scan findings
- Configuration drift
- Compliance audit failures

### Assessment

```bash
# Check current configuration
kubectl get deployment <deployment> -o yaml

# Compare with expected
diff expected-config.yaml <(kubectl get deployment <deployment> -o yaml)

# Run policy validation
conftest test deployment.yaml -p policy/
```

### Remediation

1. **Document the misconfiguration**
2. **Apply correct configuration**
   ```bash
   kubectl patch deployment <deployment> \
     -p '{"spec":{"template":{"spec":{"securityContext":{"runAsNonRoot":true}}}}}'
   ```
3. **Verify fix**
   ```bash
   kubectl get deployment <deployment> -o yaml | grep -A5 securityContext
   ```
4. **Update configuration management**

---

## Communication Templates

### Initial Notification (Internal)

```
Subject: [SECURITY INCIDENT] <Severity> - <Brief Description>

Incident ID: INC-<YYYY-MM-DD>-<number>
Severity: <Critical/High/Medium/Low>
Status: Investigating / Contained / Resolved

Summary:
<Brief description of what happened>

Impact:
<What systems/data are affected>

Current Actions:
<What is being done>

Next Update: <Time>

Contact: <Incident Commander>
```

### Status Update

```
Subject: [UPDATE] INC-<ID> - <Brief Description>

Status: <Current status>

Progress since last update:
- <Action taken>
- <Finding>

Next steps:
- <Planned action>

ETA for resolution: <Time if known>
```

### Post-Incident Report

```
Incident Report: INC-<ID>

1. Executive Summary
2. Timeline of Events
3. Root Cause Analysis
4. Impact Assessment
5. Response Actions
6. Lessons Learned
7. Recommendations
```

---

## Escalation Matrix

| Severity | Initial Responder | Escalation Path            | Executive Notify |
| -------- | ----------------- | -------------------------- | ---------------- |
| Critical | On-call engineer  | Security Lead → CISO → CEO | Immediate        |
| High     | On-call engineer  | Security Lead → CISO       | 1 hour           |
| Medium   | Team lead         | Security Lead              | Daily summary    |
| Low      | Assigned engineer | Team lead                  | Weekly summary   |

---

## Integration Points

### Alerting

Configure alerts to trigger incident response:

```yaml
# Example PagerDuty integration
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: security-alerts
spec:
  groups:
    - name: security
      rules:
        - alert: ContainerCompromise
          expr: falco_events{priority="Critical"} > 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: 'Critical security event detected'
            runbook: 'https://docs/compliance/incident-response.md#container-compromise'
```

### Automation

Automated response actions:

```yaml
# Example automated isolation
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: isolate-compromised-pod
spec:
  entrypoint: isolate
  templates:
    - name: isolate
      steps:
        - - name: apply-network-policy
            template: network-policy
        - - name: notify
            template: slack-notify
```

---

## Tabletop Exercises

### Schedule

Conduct quarterly tabletop exercises to test incident response:

- **Q1**: Container compromise scenario
- **Q2**: Data exposure scenario
- **Q3**: Supply chain attack scenario
- **Q4**: Combined/complex scenario

### Exercise Template

1. **Scenario presentation** (10 min)
2. **Team response discussion** (30 min)
3. **Walkthrough of playbook** (15 min)
4. **Gap identification** (15 min)
5. **Action items** (10 min)

### Post-Exercise

- Document lessons learned
- Update playbooks
- Assign improvement tasks
- Schedule follow-up

---

## Related Documentation

- [Production Checklist](production-checklist.md)
- [Operational Runbooks](../operations/runbooks/)
- [Compliance Framework Analysis](../reference/compliance.md)
