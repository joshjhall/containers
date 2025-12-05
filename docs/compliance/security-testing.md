# Security Testing Automation

This document describes the security testing automation for the container build
system, including DAST integration, penetration testing schedules, and security
regression testing.

## Compliance Coverage

| Framework       | Requirement             | Status    |
| --------------- | ----------------------- | --------- |
| SOC 2 CC7.1     | System security testing | Compliant |
| ISO 27001 A.8.8 | Technical vulnerability | Compliant |
| PCI DSS 11.3    | Penetration testing     | Guidance  |
| NIST CSF DE.CM  | Security monitoring     | Compliant |

______________________________________________________________________

## Security Test Suite

### Automated Security Tests

Run the security regression test suite against any container image:

```bash
# Run against a specific image
./tests/security/run_security_tests.sh ghcr.io/joshjhall/containers:python-dev

# Build and test (no image specified)
./tests/security/run_security_tests.sh
```

### Test Categories

The test suite validates:

1. **Non-root User Configuration**

   - Container runs as non-root
   - Passwordless sudo is disabled
   - Home directory ownership

1. **File Permissions**

   - No world-writable files in /usr
   - Sensitive files have correct permissions
   - Shadow file is protected

1. **Linux Capabilities**

   - No dangerous capabilities (SYS_ADMIN, SYS_PTRACE, NET_ADMIN)
   - Capability restrictions enforced

1. **Network Security**

   - No listening services by default
   - CA certificates installed

1. **Secret Protection**

   - No secrets in environment variables
   - No .env files in image
   - SSH directory permissions

1. **Image Security**

   - Metadata labels present
   - No unnecessary ports exposed
   - Healthcheck configured

1. **Build Security**

   - Package manager cache cleaned
   - Temporary files removed
   - Build scripts cleaned up

______________________________________________________________________

## CI/CD Integration

### Security Testing in CI

Security tests run automatically in CI:

```yaml
# .github/workflows/ci.yml
security-tests:
  name: Security Regression Tests
  runs-on: ubuntu-latest
  needs: build
  steps:
    - uses: actions/checkout@v4

    - name: Run security tests
      run:
        ./tests/security/run_security_tests.sh ${{ needs.build.outputs.image }}
```

### Trivy Vulnerability Scanning

Already integrated in CI workflow:

```yaml
- name: Run Trivy vulnerability scanner
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ env.IMAGE_NAME }}
    format: 'sarif'
    output: 'trivy-results.sarif'
    severity: 'CRITICAL,HIGH'
```

### Gitleaks Secret Detection

Already integrated in CI workflow:

```yaml
- name: Run Gitleaks
  uses: gitleaks/gitleaks-action@v2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

______________________________________________________________________

## DAST (Dynamic Application Security Testing)

### OWASP ZAP Integration

For containers that expose web services, use OWASP ZAP for DAST:

```yaml
# Example: DAST scanning workflow
dast-scan:
  name: DAST Security Scan
  runs-on: ubuntu-latest
  needs: deploy-staging
  steps:
    - name: OWASP ZAP Scan
      uses: zaproxy/action-full-scan@v0.7.0
      with:
        target: 'https://staging.example.com'
        rules_file_name: '.zap/rules.tsv'
        cmd_options: '-a'
```

### ZAP Configuration

Create `.zap/rules.tsv` to customize scan rules:

```tsv
10016  IGNORE  (Web Browser XSS Protection Not Enabled)
10017  IGNORE  (Cross-Domain JavaScript Source File Inclusion)
10096  WARN  (Timestamp Disclosure - Unix)
```

______________________________________________________________________

## Penetration Testing Schedule

### Quarterly Penetration Tests

| Quarter | Focus Area           | Scope                           |
| ------- | -------------------- | ------------------------------- |
| Q1      | Container Breakout   | Privilege escalation, escapes   |
| Q2      | Network Segmentation | Lateral movement, policy bypass |
| Q3      | Supply Chain         | Dependency vulnerabilities      |
| Q4      | Full Assessment      | Comprehensive security review   |

### Pre-Engagement Checklist

- [ ] Define scope and rules of engagement
- [ ] Establish communication channels
- [ ] Set up isolated test environment
- [ ] Back up systems and data
- [ ] Notify relevant stakeholders

### Post-Engagement Actions

1. Review findings with security team
1. Prioritize vulnerabilities by severity
1. Create remediation plan with timelines
1. Implement fixes and validate
1. Update security documentation

### Penetration Test Report Template

```markdown
# Penetration Test Report

## Executive Summary

- Test dates: [Start] - [End]
- Tester(s): [Names]
- Scope: [Systems/containers tested]

## Findings Summary

| ID  | Severity | Finding | Status |
| --- | -------- | ------- | ------ |
| 1   | Critical | ...     | Open   |

## Detailed Findings

### Finding 1: [Title]

- **Severity**: Critical/High/Medium/Low
- **CVSS**: [Score]
- **Description**: [Details]
- **Impact**: [Business impact]
- **Recommendation**: [Remediation steps]
- **Evidence**: [Screenshots/logs]

## Recommendations

[Prioritized list of improvements]
```

______________________________________________________________________

## Chaos Engineering

### Container Resilience Testing

Use chaos engineering to test container resilience:

```yaml
# Example: Chaos Mesh experiment
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: container-kill
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - production
    labelSelectors:
      app: devcontainer
  scheduler:
    cron: '@every 1h'
```

### Litmus Chaos Experiments

```yaml
# Example: CPU stress test
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: container-cpu-stress
spec:
  appinfo:
    appns: production
    applabel: 'app=devcontainer'
  chaosServiceAccount: litmus-admin
  experiments:
    - name: container-cpu-hog
      spec:
        components:
          env:
            - name: TARGET_CONTAINER
              value: 'devcontainer'
            - name: CPU_CORES
              value: '1'
            - name: TOTAL_CHAOS_DURATION
              value: '60'
```

### Chaos Testing Schedule

| Frequency | Test Type           | Purpose                 |
| --------- | ------------------- | ----------------------- |
| Daily     | Pod kill            | Verify restart behavior |
| Weekly    | Network partition   | Test isolation          |
| Monthly   | Resource exhaustion | Validate limits         |

______________________________________________________________________

## Security Regression Tests

### Adding New Tests

Add tests to `tests/security/run_security_tests.sh`:

```bash
test_custom_security() {
    echo ""
    log_info "Testing custom security requirement..."

    # Your test logic
    if [[ condition ]]; then
        log_test "Test passed"
    else
        log_test_fail "Test failed"
    fi
}

# Add to main() function
test_custom_security
```

### Test Best Practices

1. **Idempotent**: Tests should produce same results on repeated runs
1. **Independent**: Tests should not depend on other tests
1. **Fast**: Keep tests quick to enable frequent execution
1. **Clear**: Use descriptive names and messages
1. **Comprehensive**: Cover all security requirements

______________________________________________________________________

## Compliance Reporting

### Generate Security Report

```bash
#!/bin/bash
# generate-security-report.sh

echo "=== Security Testing Report ==="
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "=== Vulnerability Scan Results ==="
trivy image --severity HIGH,CRITICAL "$IMAGE"

echo ""
echo "=== Security Regression Tests ==="
./tests/security/run_security_tests.sh "$IMAGE"

echo ""
echo "=== Secret Scan Results ==="
gitleaks detect --source . --report-format json
```

### Continuous Compliance Monitoring

Set up alerts for:

- New critical vulnerabilities
- Failed security tests
- Secret detection alerts
- Unusual container behavior

______________________________________________________________________

## Related Documentation

- [Incident Response](incident-response.md)
- [Production Checklist](production-checklist.md)
- [Compliance Framework Analysis](../reference/compliance.md)
