# ContainerBuildWarnings

## Alert Details

- **Severity:** info
- **Component:** build
- **Threshold:** `container_build_warnings_total > 10` for 5 minutes

## Symptoms

- Build completes but with elevated warning count
- Deprecation notices in build output
- Non-fatal issues logged during feature installation

## Diagnosis

1. **Review build log warnings:**

   ```bash
   check-build-logs.sh
   check-build-logs.sh <feature-name>
   ```

1. **Check for deprecation patterns:**

   ```bash
   # Look for common warning patterns in logs
   grep -i "deprecat\|warning\|obsolete" /var/log/container-build/*.log
   ```

1. **Check if warnings are new or existing:**

   ```bash
   # Compare warning count trend
   curl -s 'http://localhost:9090/api/v1/query?query=container_build_warnings_total' | jq .
   ```

## Resolution

### Immediate

- Review warnings to confirm none indicate upcoming breakage
- No immediate action needed for informational warnings

### Short-term

- Address deprecation warnings before they become errors
- Update packages that emit deprecation notices
- Review and update feature scripts for deprecated API usage

### Long-term

- Set up CI checks that fail on new deprecation warnings
- Keep feature scripts updated with latest best practices
- Track warning trends over time to catch gradual degradation

## Escalation

- **First responder:** Platform engineering team
- **Escalation:** Generally not required for info-level alerts
