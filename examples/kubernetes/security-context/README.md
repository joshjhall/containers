# Security Context Policies

This directory contains examples for implementing Pod Security Standards,
AppArmor profiles, and SELinux configurations for Kubernetes workloads.

## Compliance Coverage

| Framework    | Requirement             | Implementation             |
| ------------ | ----------------------- | -------------------------- |
| OWASP D05    | Security configs        | Pod Security Standards     |
| ISO 27001    | Access management       | MAC (AppArmor/SELinux)     |
| SOC 2 CC6.1  | Logical access controls | Security contexts          |
| PCI DSS 7.1  | Need-to-know access     | Least privilege containers |
| FedRAMP AC-6 | Least privilege         | Capability restrictions    |
| CMMC AC.L2   | Control CUI flow        | Mandatory access controls  |

## Files

| File                        | Description                    |
| --------------------------- | ------------------------------ |
| pod-security-standards.yaml | PSS namespace and pod examples |
| apparmor-profiles.yaml      | AppArmor profile templates     |
| selinux-config.yaml         | SELinux context configuration  |

## Quick Start

### Pod Security Standards

```bash
# Apply namespace with PSS enforcement
kubectl apply -f pod-security-standards.yaml

# Verify PSS labels
kubectl get namespace production --show-labels
```

### AppArmor Profiles

```bash
# Deploy AppArmor profiles to nodes
kubectl apply -f apparmor-profiles.yaml

# Verify profiles are loaded
kubectl get pods -n kube-system -l app=apparmor-loader

# Check profile status on a node
ssh node1 "aa-status | grep k8s-"
```

### SELinux Configuration

```bash
# Apply SELinux-enabled pods
kubectl apply -f selinux-config.yaml

# Verify SELinux context
kubectl exec selinux-pod -- cat /proc/1/attr/current
```

## Pod Security Standards Levels

### Privileged

No restrictions. Use only for system-level workloads.

### Baseline

Prevents known privilege escalations. Minimum for production.

Required restrictions:

- No hostNetwork, hostPID, hostIPC
- No privileged containers
- No hostPath volumes (except specific paths)
- Limited host ports

### Restricted

Maximum security. Required for compliance workloads.

Additional restrictions:

- Must run as non-root
- Must drop ALL capabilities
- Read-only root filesystem recommended
- Seccomp profile required
- No privilege escalation

## Migration from PSP to PSS

Pod Security Policies (PSP) are deprecated. Migrate to Pod Security Standards:

1. **Audit current policies**

   ```bash
   kubectl get psp
   kubectl get rolebinding,clusterrolebinding -A | grep psp
   ```

2. **Map PSP to PSS levels**

   | PSP Setting            | PSS Level  |
   | ---------------------- | ---------- |
   | privileged: false      | baseline   |
   | runAsNonRoot: true     | restricted |
   | readOnlyRootFilesystem | restricted |
   | allowPrivilegeEsc      | restricted |

3. **Apply PSS labels to namespaces**

   ```bash
   kubectl label namespace my-ns \
     pod-security.kubernetes.io/enforce=restricted \
     pod-security.kubernetes.io/warn=restricted \
     pod-security.kubernetes.io/audit=restricted
   ```

4. **Test workloads**

   ```bash
   # Dry-run deployment
   kubectl apply --dry-run=server -f deployment.yaml
   ```

5. **Remove PSP resources**

   ```bash
   kubectl delete psp --all
   kubectl delete clusterrole psp-role
   ```

## AppArmor Profile Development

### Create Custom Profile

```text
#include <tunables/global>

profile my-app flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # Allow specific paths
  /app/** r,
  owner /tmp/** rw,

  # Network access
  network inet stream,

  # Deny dangerous operations
  deny capability sys_admin,
  deny mount,
}
```

### Test Profile

```bash
# Load in complain mode first
apparmor_parser -C my-app.profile

# Check for denials
dmesg | grep apparmor

# Switch to enforce mode
apparmor_parser -r my-app.profile
```

### Debug AppArmor Issues

```bash
# Check if AppArmor is enabled
aa-status

# View loaded profiles
aa-status --verbose

# Generate profile from application run
aa-genprof /usr/bin/myapp
```

## SELinux Context Development

### View Current Context

```bash
# On host
getenforce
sestatus

# In container
cat /proc/1/attr/current
```

### Multi-Category Security (MCS)

MCS labels provide tenant isolation:

```yaml
seLinuxOptions:
  level: 's0:c100,c200' # Categories c100 and c200
```

Pods with different MCS labels cannot access each other's resources.

### Debug SELinux Issues

```bash
# View SELinux denials
ausearch -m AVC -ts recent

# Generate policy from denials
audit2allow -a

# Check file contexts
ls -Z /path/to/file

# Restore default contexts
restorecon -R /path/to/dir
```

## Verification

### Check Pod Security Context

```bash
# View pod security context
kubectl get pod my-pod -o jsonpath='{.spec.securityContext}'

# Check container security context
kubectl get pod my-pod -o jsonpath='{.spec.containers[0].securityContext}'
```

### Verify AppArmor Profile

```bash
# Check which profile is applied
kubectl describe pod my-pod | grep apparmor

# Verify on node
ssh node1 "aa-status | grep my-app"
```

### Verify SELinux Context

```bash
# Check pod SELinux options
kubectl get pod my-pod -o jsonpath='{.spec.securityContext.seLinuxOptions}'

# Inside container
kubectl exec my-pod -- id -Z
```

## Troubleshooting

### Pod Fails to Schedule

```bash
# Check events
kubectl describe pod my-pod

# Common issues:
# - PSS violation: Check namespace labels
# - AppArmor profile not found: Verify profile is loaded on node
# - SELinux context denied: Check audit log
```

### AppArmor Denials

```bash
# View kernel log for denials
dmesg | grep "apparmor.*DENIED"

# Generate allowed rules
aa-logprof
```

### SELinux Denials

```bash
# Search audit log
ausearch -m AVC -ts today

# Analyze and create policy
sealert -a /var/log/audit/audit.log
```

## Best Practices

1. **Start with Restricted PSS** - Apply restricted level to all production
   namespaces

2. **Use runtime/default profiles** - AppArmor and Seccomp defaults provide good
   baseline

3. **Drop ALL capabilities** - Add only specific capabilities needed

4. **Read-only root filesystem** - Use emptyDir for writable paths

5. **Run as non-root** - Use runAsNonRoot: true and specific UID

6. **Audit before enforce** - Test with warn/audit modes before enforcing

7. **Document exceptions** - If elevated permissions needed, document why

## Related Documentation

- [TLS Configuration](../tls/)
- [Network Policies](../network-policies/)
- [Production Checklist](../../../docs/compliance/production-checklist.md)
- [Kubernetes Pod Security](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [AppArmor Documentation](https://kubernetes.io/docs/tutorials/security/apparmor/)
