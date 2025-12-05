# Version Compatibility Testing

This document describes the version compatibility testing system for tracking
and validating language version combinations.

## Overview

The version compatibility system helps you:

- Track which language versions have been tested together
- Test new version combinations before deploying
- Document known compatible and incompatible combinations
- Prevent version regressions during updates
- Maintain a compatibility matrix for reference

## Quick Start

### Test a Specific Variant with Custom Version

```bash
# Test python-dev with Python 3.13.0
./bin/test-version-compatibility.sh \
    --variant python-dev \
    --python-version 3.13.0

# Output:
# ==========================================
# Version Compatibility Testing
# ==========================================
# Variants: python-dev
# Update matrix: false
# Dry run: false
# ==========================================
#
# ==================================================
# Testing variant: python-dev
# ==================================================
# [INFO] Building variant: python-dev
# [INFO] Build args: --build-arg INCLUDE_PYTHON=true --build-arg INCLUDE_PYTHON_DEV=true --build-arg PYTHON_VERSION=3.13.0
# [SUCCESS] Build succeeded for python-dev
# [SUCCESS] Tests passed for python-dev
```

### Test Multiple Versions in Polyglot

```bash
# Test polyglot with custom versions
./bin/test-version-compatibility.sh \
    --variant polyglot \
    --python-version 3.13.0 \
    --node-version 20 \
    --rust-version 1.82.0 \
    --go-version 1.23.0

# Update the compatibility matrix with results
./bin/test-version-compatibility.sh \
    --variant polyglot \
    --python-version 3.13.0 \
    --node-version 20 \
    --rust-version 1.82.0 \
    --go-version 1.23.0 \
    --update-matrix
```

### Dry Run to See What Would Be Tested

```bash
# See what would be tested without building
./bin/test-version-compatibility.sh \
    --variant python-dev \
    --python-version 3.13.0 \
    --dry-run
```

## Command-Line Options

### Variant Selection

- `--variant <name>` - Test specific variant (minimal, python-dev, node-dev,
  etc.)
  - If not specified, tests all default variants

### Version Overrides

- `--python-version <ver>` - Override Python version (e.g., 3.13.0)
- `--node-version <ver>` - Override Node version (e.g., 20)
- `--rust-version <ver>` - Override Rust version (e.g., 1.82.0)
- `--go-version <ver>` - Override Go version (e.g., 1.23.0)
- `--ruby-version <ver>` - Override Ruby version (e.g., 3.3.0)
- `--java-version <ver>` - Override Java version (e.g., 21)
- `--r-version <ver>` - Override R version (e.g., 4.4.0)
- `--base-image <image>` - Override Debian base image (e.g., debian:12-slim)

### Actions

- `--update-matrix` - Update compatibility matrix with test results
- `--dry-run` - Show what would be tested without actually building
- `--help` - Show help message

## Compatibility Matrix

### Matrix File Structure

The compatibility matrix is stored in `version-compatibility-matrix.json`:

```json
{
  "last_updated": "2025-11-12T01:20:00Z",
  "base_images": [
    {
      "name": "debian:13-slim",
      "status": "supported",
      "tested": true
    }
  ],
  "language_versions": {
    "python": {
      "current": "3.14.0",
      "supported": ["3.12.0", "3.13.0", "3.14.0"],
      "tested": ["3.14.0"],
      "deprecated": []
    },
    "node": {
      "current": "22",
      "supported": ["20", "22"],
      "tested": ["22"],
      "deprecated": []
    }
  },
  "tested_combinations": [
    {
      "variant": "python-dev",
      "base_image": "debian:13-slim",
      "versions": {
        "python": "3.14.0"
      },
      "status": "passing",
      "tested_at": "2025-11-12T01:00:00Z"
    }
  ]
}
```

### Matrix Fields

#### Base Images

- `name`: Debian base image identifier
- `status`: `supported`, `deprecated`, or `unsupported`
- `tested`: Whether this image is regularly tested in CI

#### Language Versions

For each language (python, node, rust, go, ruby, java, r, mojo):

- `current`: Current default version in Dockerfile
- `supported`: All versions that should work
- `tested`: Versions that have been explicitly tested
- `deprecated`: Old versions that work but are not recommended

#### Tested Combinations

- `variant`: Container variant tested
- `base_image`: Debian base image used
- `versions`: Object with version numbers for each language
- `status`: `passing`, `failing`, or `untested`
- `tested_at`: ISO 8601 timestamp
- `notes`: Optional notes about compatibility issues

## Usage Examples

### Testing Before Version Update

Before updating Python from 3.13 to 3.14:

```bash
# Test the new version
./bin/test-version-compatibility.sh \
    --variant python-dev \
    --python-version 3.14.0

# If successful, update the matrix
./bin/test-version-compatibility.sh \
    --variant python-dev \
    --python-version 3.14.0 \
    --update-matrix
```

### Testing Version Combinations

Test multiple language versions together:

```bash
# Test specific combination
./bin/test-version-compatibility.sh \
    --variant polyglot \
    --python-version 3.13.0 \
    --node-version 20 \
    --rust-version 1.82.0 \
    --go-version 1.23.0 \
    --update-matrix
```

### Testing with Different Base Images

Test on multiple Debian versions:

```bash
# Test on Debian 12
./bin/test-version-compatibility.sh \
    --variant python-dev \
    --base-image debian:12-slim \
    --python-version 3.13.0

# Test on Debian 13
./bin/test-version-compatibility.sh \
    --variant python-dev \
    --base-image debian:13-slim \
    --python-version 3.13.0
```

### CI/CD Integration

Add to CI pipeline to test version combinations:

```yaml
# .github/workflows/version-compatibility.yml
name: Version Compatibility Testing

on:
  schedule:
    - cron: '0 2 * * 0' # Weekly on Sunday at 2 AM
  workflow_dispatch:

jobs:
  test-versions:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        variant: [python-dev, node-dev, rust-golang]
        python-version: ['3.12.0', '3.13.0', '3.14.0']
        node-version: ['20', '22']
        include:
          - variant: python-dev
            language: python
          - variant: node-dev
            language: node

    steps:
      - uses: actions/checkout@v4

      - name: Test version combination
        run: |
          if [ "${{ matrix.language }}" = "python" ]; then
            ./bin/test-version-compatibility.sh \
              --variant ${{ matrix.variant }} \
              --python-version ${{ matrix.python-version }} \
              --update-matrix
          elif [ "${{ matrix.language }}" = "node" ]; then
            ./bin/test-version-compatibility.sh \
              --variant ${{ matrix.variant }} \
              --node-version ${{ matrix.node-version }} \
              --update-matrix
          fi
```

## Viewing Compatibility Matrix

### Current Matrix

View the current compatibility matrix:

```bash
# Pretty print JSON
cat version-compatibility-matrix.json | jq '.'

# View specific language versions
cat version-compatibility-matrix.json | jq '.language_versions.python'

# View tested combinations
cat version-compatibility-matrix.json | jq '.tested_combinations'
```

### Filter by Status

```bash
# Show only passing combinations
cat version-compatibility-matrix.json | jq '.tested_combinations[] | select(.status == "passing")'

# Show failing combinations
cat version-compatibility-matrix.json | jq '.tested_combinations[] | select(.status == "failing")'
```

### View Test Results Log

Test results are appended to `version-compat-results.jsonl`:

```bash
# View all results
cat version-compat-results.jsonl | jq '.'

# View recent results
tail -10 version-compat-results.jsonl | jq '.'

# Filter by variant
grep '"variant": "python-dev"' version-compat-results.jsonl | jq '.'
```

## Best Practices

### 1. Test Before Updating Defaults

Always test new versions before updating Dockerfile defaults:

```bash
# Test new version
./bin/test-version-compatibility.sh --variant python-dev --python-version 3.14.0

# If passing, update Dockerfile
# ARG PYTHON_VERSION=3.14.0
```

### 2. Document Known Issues

If a combination fails, add notes to the matrix:

```json
{
  "variant": "python-dev",
  "versions": { "python": "3.14.0" },
  "status": "failing",
  "notes": "Incompatible with current version of package X"
}
```

### 3. Test Multiple Debian Versions

Ensure compatibility across Debian versions:

```bash
for base in "debian:11-slim" "debian:12-slim" "debian:13-slim"; do
    ./bin/test-version-compatibility.sh \
        --variant python-dev \
        --python-version 3.13.0 \
        --base-image "$base"
done
```

### 4. Update Matrix Regularly

Run compatibility tests weekly or monthly:

```bash
# Test all default variants with current versions
./bin/test-version-compatibility.sh --update-matrix
```

### 5. Version Combination Testing

For polyglot images, test critical combinations:

```bash
# Test known good combination
./bin/test-version-compatibility.sh \
    --variant polyglot \
    --python-version 3.13.0 \
    --node-version 20 \
    --rust-version 1.82.0 \
    --go-version 1.23.0
```

## Troubleshooting

### Build Failures

If a version combination fails to build:

1. Check build logs in `/tmp/version-compat-build.log`
1. Verify the version exists and is downloadable
1. Check for dependency conflicts
1. Review feature script for version-specific issues

### Test Failures

If integration tests fail:

1. Check test logs in `/tmp/version-compat-test.log`
1. Run tests manually for the specific variant
1. Check for breaking changes in the new version
1. Review language-specific compatibility notes

### Matrix Update Issues

If matrix updates fail:

- Ensure `version-compatibility-matrix.json` exists
- Check file permissions
- Verify JSON format is valid
- Use `jq` to validate the matrix file

## Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed
- `2` - Usage error (invalid arguments)

## Integration with Testing Framework

The version compatibility system integrates with the unit test framework:

```bash
# Run unit tests for version compatibility system
./tests/unit/bin/test-version-compatibility.sh

# All tests should pass:
# ✅ Minimal variant build args
# ✅ Python-dev variant build args
# ✅ Rust-golang variant build args
# ✅ Polyglot variant build args
# ✅ JSON generation: single language
# ✅ JSON generation: multiple languages
# ✅ Matrix entry format
# (12 tests total)
```

## Related Documentation

- [Build Metrics](../ci/build-metrics.md) - Track image sizes and build times
- [Testing Framework](../development/testing.md) - Overall testing approach
- [Version Tracking](versions.md) - Which tools are pinned vs. latest
- [Migration Guide](migration-guide.md) - Upgrading between versions
- [Contributing](../CONTRIBUTING.md) - Development guidelines
