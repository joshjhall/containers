# ContainerBuildErrorTrend

## Alert Details

- **Severity:** warning
- **Component:** build
- **Threshold:** Build error count increased over the last hour, sustained for 10 minutes

## Symptoms

- Build errors are increasing across the fleet
- Multiple features or containers starting to fail
- Possible regression in base images or shared dependencies

## Diagnosis

1. **Check the scope of the increase:**

   ```bash
   # Which features are newly failing?
   curl -s 'http://localhost:9090/api/v1/query?query=container_build_errors_total_all-container_build_errors_total_all offset 1h' | jq .
   ```

1. **Correlate with recent changes:**

   ```bash
   # Check recent git history for changes to build scripts
   git log --oneline --since="1 hour ago" -- lib/ Dockerfile
   ```

1. **Check external dependencies:**

   - Has a base image been updated? (`docker pull` the base image and compare digests)
   - Is a package registry experiencing issues?
   - Were new version constraints applied?

1. **Check auto-update branches:**

   ```bash
   # Check if auto-patch ran recently
   git branch -a | grep auto-patch
   ```

## Resolution

### Immediate

- If correlated with a recent commit, consider reverting
- If external dependency issue, pin to the previous known-good version
- Check `bin/check-versions.sh --json` for version resolution problems

### Short-term

- Add version pinning for the affected dependency
- Update the feature script to handle the new behavior
- Run `./tests/run_integration_tests.sh` to validate fixes

### Long-term

- Add automated rollback for detected regressions
- Improve version pinning and checksum verification
- Set up dependency update notifications

## Escalation

- **First responder:** Platform engineering team
- **Escalation:** Release engineering if related to auto-patch
