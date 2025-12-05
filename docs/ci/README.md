# CI/CD Documentation

This directory contains documentation for continuous integration and deployment
workflows.

## Available Guides

- [**GitHub CI Authentication**](authentication.md) - Setting up authentication
  for GitHub Actions workflows
- [**Build Metrics**](build-metrics.md) - Tracking image sizes, build times, and
  detecting regressions

## Overview

The CI/CD system provides:

- **Automated Testing**: Unit and integration tests on every commit
- **Multi-Platform Builds**: Test on multiple Debian versions (11, 12, 13)
- **Regression Detection**: Monitor build metrics and catch unexpected changes
- **Automated Releases**: Weekly auto-patch system for version updates

## Quick Links

### Build Metrics

```bash
# Measure image size and build time
./bin/measure-build-metrics.sh python-dev

# Compare against baseline
./bin/measure-build-metrics.sh --compare python-dev

# Save as new baseline
./bin/measure-build-metrics.sh --save-baseline python-dev
```

### CI Workflows

The main GitHub Actions workflows:

- `.github/workflows/ci.yml` - Test suite (unit + integration tests)
- `.github/workflows/build-matrix.yml` - Multi-platform builds
- `.github/workflows/auto-patch.yml` - Weekly version updates

## For Contributors

When working with CI/CD:

1. Test locally before pushing (run `./tests/run_all.sh`)
1. Check build metrics for size regressions
1. Update baselines after intentional size changes
1. Document authentication setup in team docs

## Related Documentation

- [Development](../development/) - Release process and testing
- [Operations](../operations/) - Automated releases and rollback
- [Reference](../reference/) - Environment variables and configuration
