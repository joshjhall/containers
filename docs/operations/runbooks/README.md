# Operational Runbooks

This directory contains operational runbooks for common container
troubleshooting scenarios. Each runbook provides step-by-step debugging
procedures.

## Quick Reference

| Issue                 | Runbook                                                        | Severity |
| --------------------- | -------------------------------------------------------------- | -------- |
| Container won't start | [container-startup-failures.md](container-startup-failures.md) | High     |
| Build failures        | [build-failures.md](build-failures.md)                         | High     |
| Slow builds           | [slow-builds.md](slow-builds.md)                               | Medium   |
| Cache problems        | [cache-issues.md](cache-issues.md)                             | Medium   |
| Network connectivity  | [network-issues.md](network-issues.md)                         | Medium   |
| Permission errors     | [permission-issues.md](permission-issues.md)                   | Low      |

## Using These Runbooks

1. **Identify the symptom** - Match your issue to a runbook above
2. **Follow the diagnostic steps** - Each runbook has ordered steps
3. **Check common causes** - Most issues fall into known patterns
4. **Escalate if needed** - Document findings for further investigation

## Runbook Structure

Each runbook follows this format:

- **Symptoms**: How to recognize the issue
- **Quick Checks**: Fast initial diagnostics
- **Common Causes**: Most frequent root causes
- **Diagnostic Steps**: Systematic investigation
- **Resolution**: How to fix once cause is identified
- **Prevention**: How to avoid future occurrences

## Related Documentation

- [Troubleshooting Guide](../../troubleshooting.md) - General troubleshooting
- [Healthcheck Documentation](../../healthcheck.md) - Container health
  monitoring
- [Observability Runbooks](../../observability/runbooks/) - Metrics and logging
